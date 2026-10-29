import AppKit
import Combine
import CoreGraphics
import Foundation
import SturgeonKit

/// Everything the popover renders.  All mutation of @Published state happens on the main thread;
/// the Backend queue only ever produces values.  Nothing here runs a process synchronously: the
/// view body reads state, the model starts the work.
final class PilotModel: ObservableObject {
    // status
    @Published var armed = false
    @Published var build = "—"
    @Published var pid: Int?
    @Published var sitesPatched = 0
    @Published var sitesTotal = 6
    @Published var debugger = "—"
    @Published var helper = "none"
    @Published var daemonLoaded = false
    @Published var reason: String?
    @Published var lastStatus: StatusReport?

    // doctor
    @Published var doctorOK: Bool?
    @Published var doctorLine = "checking…"
    @Published var doctorRefusal: String?
    @Published var doctorReport: DoctorReport?

    // payload config
    @Published var births = false
    @Published var onTop = false
    @Published var level3 = false
    @Published var scale: Double = 1.0
    /// The diagnostic `trace` key (issue #31).  Only meaningful while armed.
    @Published var trace = false

    // diagnostics
    @Published var diagnosticsOpen = false
    @Published var lastResize: ResizeReport?
    @Published var fullCounters: CountersReport?
    @Published var countersNote: String?
    /// The last `wmship.sh trace` read, or `nil` before the first read / after trace is turned
    /// off.  Its three states keep a refusal and an empty ring from looking like "no decisions".
    @Published var traceRead: TraceRead?
    @Published var traceShowing = false
    @Published var lastError: String?
    @Published var ambiguousDrops = 0
    @Published var inputStatus = "off (disarmed)"
    @Published var inputRearms = 0
    @Published var stripGutter: CGRect?

    /// The resize preflight (issue #5).  The slider is offered only when this says ready, and a
    /// check and a resize never overlap.  Every mutation happens on the main thread.
    @Published var preflight = PreflightGate()

    // gesture settings
    @Published var gestureEnabled = true {
        didSet {
            UserDefaults.standard.set(gestureEnabled, forKey: Self.gestureEnabledKey)
            inputTap.gestureEnabled = gestureEnabled
            inputStatus = inputTap.statusText
            scheduleStageTimer()
        }
    }
    @Published var gestureModifier: GestureModifier = .standard {
        didSet {
            UserDefaults.standard.set(gestureModifier.rawValue, forKey: Self.gestureModifierKey)
            inputTap.modifier = gestureModifier
            inputStatus = inputTap.statusText
        }
    }

    // stages
    @Published var stages: [StageItem] = []

    // chrome
    @Published var footer = "ready"
    @Published var setupNeeded = false
    @Published var axNeeded = false
    @Published var busy = false
    @Published var isEditingScale = false
    @Published var showSetupBanner = false

    private static let gestureEnabledKey = "gestureEnabled"
    private static let gestureModifierKey = "gestureModifier"

    private let inputTap = InputTapController()
    private let hud = ScaleHUD()

    private var scaleWork: DispatchWorkItem?
    /// Set by `popoverOpened()`; consumed once the status document says the payload is armed, so
    /// the check runs against a fact rather than the last poll's guess.
    private var preflightPendingOnOpen = false
    /// Invalidates a completion whose armed state changed while it was in flight.
    private var selfcheckID = 0
    /// The WindowManager pid the current verdict belongs to; a change re-opens the gate.
    private var preflightWMPID: Int?
    /// The trace toggle's state comes from the payload config once per armed session.  The status
    /// document does not echo `trace`, so without this an app restart would show "off" while the
    /// keeper is still writing records.
    private var traceConfigLoaded = false
    private var traceConfigLoading = false
    /// Invalidates a config read whose result was overtaken by a toggle.
    private var traceConfigID = 0
    private var lastStatusAt = Date.distantPast
    private var lastStagesAt = Date.distantPast
    /// Keeps the strip rect fresh while armed, even with the popover closed.  The gesture needs
    /// it to decide whether the pointer is in the gutter, and the strip rect moves with the
    /// display and the reveal state.
    private var stageTimer: Timer?

    // direct (non-sweeping) scale writes used by the gesture
    private var gestureConfig: PayloadConfig?
    private var loadingGestureConfig = false
    /// The two halves of "the tap still has a scale write to land".  Both report into the gate,
    /// which will not start a probe or a resize while either is true.
    private var pendingGestureScale: Double? { didSet { syncGestureInFlight() } }
    private var writingGestureScale = false { didSet { syncGestureInFlight() } }

    private var dropping = false

    private let wmBuildFallback: String
    private let wmPidFallback: Int?

    init() {
        let wmApp = "/System/Library/CoreServices/WindowManager.app"
        wmBuildFallback = (Bundle(path: wmApp)?.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
        wmPidFallback = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.WindowManager")
            .first.map { Int($0.processIdentifier) }
        build = wmBuildFallback
        pid = wmPidFallback

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.gestureEnabledKey) != nil {
            gestureEnabled = defaults.bool(forKey: Self.gestureEnabledKey)
        }
        if let raw = defaults.object(forKey: Self.gestureModifierKey) as? Int {
            gestureModifier = GestureModifier(rawValue: raw)
        }
        inputTap.gestureEnabled = gestureEnabled
        inputTap.modifier = gestureModifier
        inputTap.onScale = { [weak self] value in self?.gestureScale(value) }
        inputTap.onGestureEnd = { [weak self] value in self?.gestureEnded(value) }
        inputTap.onDrop = { [weak self] point, cgid in self?.handleDrop(at: point, cgid: cgid) }
        inputTap.onStateChange = { [weak self] text in
            guard let self else { return }
            self.inputStatus = text
            self.inputRearms = self.inputTap.rearmCount
        }
        inputStatus = inputTap.statusText
    }

    // MARK: - refresh

    /// The popover is where the slider is offered, so this is where the preflight runs.  The
    /// check itself waits for a fresh status document: a stale `armed = false` after `wmship.sh
    /// start` in a terminal must not silently skip it.
    func popoverOpened() {
        preflightPendingOnOpen = true
        refresh(stages: true)
    }

    /// Called at the end of every successful status decode; runs the deferred check once.
    private func consumePendingPreflight() {
        guard preflightPendingOnOpen else { return }
        preflightPendingOnOpen = false
        guard armed else { return }
        runSelfcheck()
    }

    func refresh(doctor: Bool = false, stages: Bool = false) {
        if doctor { runDoctor() }
        if stages { refreshStages() }
        if diagnosticsOpen { refreshDiagnostics() }
        inputTap.ensureEnabled()
        if armed, Date().timeIntervalSince(lastStagesAt) > 5 { refreshStages() }
        Backend.queue.async {
            let r = Backend.status()
            let dbg = Backend.debuggerText()
            DispatchQueue.main.async {
                self.apply(status: r, debuggerFallback: dbg)
                self.lastStatusAt = Date()
            }
        }
    }

    /// Diagnostics refresh on the popover's 2 s tick while the section is open.  The counters
    /// command needs root, so it runs through the helper's `counters` verb; the tick is also
    /// where a tap that macOS disabled is noticed and re-armed.
    func refreshDiagnostics() {
        guard armed else {
            fullCounters = nil
            countersNote = nil
            // Disarmed means the key cannot be written and the ring cannot be read: drop the
            // local state rather than leaving a toggle that claims a feature it cannot reach.
            trace = false
            traceRead = nil
            traceShowing = false
            traceConfigLoaded = false
            inputRearms = inputTap.rearmCount
            inputStatus = inputTap.statusText
            return
        }
        if !traceConfigLoaded { loadTraceConfig() }
        inputTap.ensureEnabled()
        Backend.queue.async {
            let result = Backend.run(.counters)
            let counters = result.decode(CountersReport.self)
            DispatchQueue.main.async {
                if let counters {
                    self.fullCounters = counters
                    self.countersNote = nil
                } else {
                    // Do not let the four keeper-only counters silently become dashes: say why.
                    let text = result.combined
                    let refusal = text.split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .first { $0.lowercased().contains("refused") }
                    let why = refusal ?? Self.lastLine(text)
                    self.countersNote = why.isEmpty
                        ? "counters command failed (helper has no counters verb?)"
                        : "counters unavailable: \(why)"
                }
                self.inputRearms = self.inputTap.rearmCount
                self.inputStatus = self.inputTap.statusText
            }
        }
    }

    /// One config read per armed session, so the toggle reflects the payload rather than the
    /// app's default.  A toggle that lands while this is in flight wins: its write bumps
    /// `traceConfigID` and this completion is discarded.
    private func loadTraceConfig() {
        guard !traceConfigLoading else { return }
        traceConfigLoading = true
        let id = traceConfigID
        Backend.queue.async {
            let config = Backend.config()
            DispatchQueue.main.async {
                self.traceConfigLoading = false
                guard id == self.traceConfigID, let config else { return }
                self.trace = config.trace
                self.traceConfigLoaded = true
            }
        }
    }

    func refreshStages() {
        lastStagesAt = Date()
        Backend.queue.async {
            let snapshot = Backend.stageSnapshot()
            DispatchQueue.main.async {
                self.stages = snapshot.stages
                self.stripGutter = snapshot.strip
                self.inputTap.gutter = snapshot.strip
                self.axNeeded = snapshot.stages.isEmpty
            }
        }
    }

    private func apply(status r: RunResult, debuggerFallback: String = "none") {
        guard let report = r.decode(StatusReport.self) else {
            // no root, or the JSON command could not run at all
            let msg = Self.lastLine(r.combined)
            if r.err.lowercased().contains("password is required")
                || msg.lowercased().contains("password is required")
                || msg.lowercased().contains("not allowed") {
                setupNeeded = true
                armed = false
                lastStatus = nil
                build = wmBuildFallback
                pid = wmPidFallback
                doctorLine = "not set up"
                doctorOK = false
                debugger = debuggerFallback
                doctorRefusal = "no root: press Set Up (one administrator approval)"
                // No payload, no preflight: a pending check is dropped rather than run against a
                // document we could not read.
                preflightPendingOnOpen = false
                selfcheckID += 1
                preflight.setArmed(false)
                updateInputs()
            } else if !r.combined.isEmpty {
                footer = msg.isEmpty ? "status failed" : msg
            }
            return
        }
        setupNeeded = false
        lastStatus = report
        build = report.build ?? wmBuildFallback
        pid = report.pid ?? wmPidFallback
        armed = report.isArmed
        sitesTotal = report.sitesTotal
        sitesPatched = report.sitesPatched
        debugger = report.debugger ?? debuggerFallback
        reason = report.reason
        helper = report.helper.first ?? "none"
        daemonLoaded = report.daemon.loaded
        if let caps = report.caps {
            births = caps.births
            onTop = caps.replay && caps.levels
            level3 = caps.levelManual == 3
            // The probe briefly writes `s = probe_s`; the 2 s status tick must not animate the
            // slider (or the gesture's base) to a scale the tool is about to restore.
            if !isEditingScale, !preflight.isChecking, let s = caps.scale { scale = s }
        } else if !armed {
            births = false
            onTop = false
            level3 = false
        }
        if !report.isArmed {
            trace = false
            traceRead = nil
            traceShowing = false
            traceConfigLoaded = false
            traceConfigID += 1
        }
        inputTap.setBaseScale(scale)
        updateInputs()
        syncPreflight(armed: report.isArmed)
    }

    /// Keeps the gate in step with the status document.  A real arm/disarm change, or a new
    /// WindowManager pid, invalidates a check in flight: a probe launched against the previous
    /// process must not decide the new one.
    private func syncPreflight(armed value: Bool) {
        if value != preflight.armed { selfcheckID += 1 }
        preflight.setArmed(value)
        if !value {
            preflightWMPID = nil
        } else if let seen = preflightWMPID, let now = pid, seen != now {
            selfcheckID += 1
            preflight.invalidate()
            preflightWMPID = now
        } else if preflightWMPID == nil {
            preflightWMPID = pid
        }
        consumePendingPreflight()
    }

    /// The tap is installed only while armed; disarming uninstalls it, which is what keeps a
    /// disarmed app from observing (or consuming) any input at all.
    private func updateInputs() {
        inputTap.modifier = gestureModifier
        inputTap.gestureEnabled = gestureEnabled
        inputTap.gutter = stripGutter
        inputTap.armed = armed
        if armed {
            inputTap.installIfNeeded()
            inputTap.ensureEnabled()
            inputTap.setBaseScale(scale)
            if stripGutter == nil { refreshStages() }
        }
        inputStatus = inputTap.statusText
        inputRearms = inputTap.rearmCount
        scheduleStageTimer()
    }

    private func scheduleStageTimer() {
        let wanted = armed && gestureEnabled
        if !wanted {
            stageTimer?.invalidate()
            stageTimer = nil
            return
        }
        // updateInputs runs on every 2 s status tick; recreating the timer there would reset its
        // 5 s interval before it ever fired.
        guard stageTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.armed else { return }
            self.refreshStages()
            self.inputTap.ensureEnabled()
        }
        RunLoop.main.add(timer, forMode: .common)
        stageTimer = timer
    }

    // MARK: - doctor

    func runDoctor() {
        doctorLine = "checking…"
        Backend.queue.async {
            let r = Backend.doctor()
            DispatchQueue.main.async {
                guard let report = r.decode(DoctorReport.self) else {
                    self.doctorOK = false
                    self.doctorLine = "unavailable"
                    self.doctorReport = nil
                    let text = r.combined
                    if text.lowercased().contains("no root") {
                        self.doctorRefusal = "no root: press Set Up (one administrator approval)"
                        self.footer = "doctor: no root — press Set Up"
                    } else {
                        self.doctorRefusal = Self.lastLine(text)
                        self.footer = "doctor: " + Self.lastLine(text)
                    }
                    return
                }
                self.doctorReport = report
                if let b = report.build { self.build = b }
                let verdict = report.verdict(armed: self.armed)
                self.doctorOK = verdict.isOK
                self.doctorLine = verdict.label
                self.doctorRefusal = verdict == .fail ? report.refusalLine() : nil
                if verdict == .fail {
                    self.footer = "doctor: " + (self.doctorRefusal ?? "FAIL")
                    self.lastError = self.doctorRefusal
                }
            }
        }
    }

    // MARK: - config writes

    func setBirths(_ v: Bool) {
        births = v
        writeConfig(.births(v))
    }

    /// One toggle, both keys: replay (the keeper re-emits the pose set) and levels.
    func setOnTop(_ v: Bool) {
        onTop = v
        writeConfig(.onTop(v))
    }

    func setLevel3(_ v: Bool) {
        level3 = v
        writeConfig(.level(v))
    }

    /// The trace key (issue #31).  Turning it off also drops the last read: the popover must not
    /// keep showing decisions from a ring that is no longer being written.
    func setTrace(_ v: Bool) {
        guard armed else {
            trace = false
            footer = "not armed — the payload config is not writable"
            return
        }
        trace = v
        traceConfigID += 1
        traceConfigLoaded = true
        if !v {
            traceRead = nil
            traceShowing = false
        }
        writeConfig(.trace(v))
    }

    /// Reads the ring through `wmship.sh trace` → the helper's `trace` verb.  Never called while
    /// the key is off: with no ring being written, a table would be a claim, not an observation.
    func showTrace() {
        guard armed else {
            traceRead = nil
            footer = "trace → not armed"
            return
        }
        guard trace else {
            traceRead = nil
            footer = "trace → enable the toggle first"
            return
        }
        guard !traceShowing, !busy else { return }
        traceShowing = true
        // Clear the previous table: a read in flight must not leave old rows under a new request.
        traceRead = nil
        footer = "trace → reading the keeper ring…"
        Backend.queue.async {
            let read = TraceRead(result: Backend.run(.trace))
            DispatchQueue.main.async {
                self.traceShowing = false
                // An arm/disarm or a toggle-off while the read was in flight owns the state.
                guard self.armed, self.trace else { return }
                self.traceRead = read
                switch read {
                case .records(let rows, let total):
                    self.footer = "trace → last \(rows.count) of \(total) record(s)"
                case .unavailable(let why):
                    self.footer = "trace → unavailable: \(why)"
                case .failed(let why):
                    self.footer = "trace → failed: \(why)"
                    self.lastError = "trace failed: \(why)"
                }
            }
        }
    }

    private func writeConfig(_ change: ConfigChange) {
        guard armed else {
            footer = "not armed — the payload config is not writable"
            return
        }
        // The trace key is the one config value `status --json` does not echo, so take the
        // read-back (or, if the read failed, the previous value) instead of trusting the toggle.
        let previousTrace = trace
        busy = true
        footer = "writing cfg \(change.label)…"
        Backend.queue.async {
            var config = Backend.config() ?? PayloadConfig()
            config.apply(change)
            let written = Backend.writeConfig(config)
            let after = Backend.config()
            DispatchQueue.main.async {
                self.busy = false
                // Any other write invalidates the gesture's cached config; otherwise a gesture
                // could re-apply a stale `births`/`levels` value it read before this change.
                self.gestureConfig = nil
                if written.code == 0 {
                    if case .trace = change, let after { self.trace = after.trace }
                    var readBack = after?.brief ?? "unavailable"
                    if case .trace = change { readBack += " trace=\(self.trace)" }
                    self.footer = "cfg \(change.label) → written; read-back \(readBack)"
                } else {
                    if case .trace = change { self.trace = after?.trace ?? previousTrace }
                    self.footer = "cfg \(change.label) → error: \(Self.lastLine(written.combined))"
                    self.lastError = Self.lastLine(written.combined)
                }
                self.refresh()
            }
        }
    }

    // MARK: - resize preflight (issue #5)

    /// Runs `wmship.sh selfcheck`, on popover open and on demand.  The gate refuses a second
    /// check while one is in flight and refuses to start one during a resize.
    ///
    /// While it runs the strip is visibly at the probe scale; the popover says so and the slider
    /// stays disabled, so neither a second check nor a resize can race the measurement.
    func runSelfcheck() {
        guard armed else {
            preflightPendingOnOpen = false
            preflight.setArmed(false)
            footer = "preflight → not armed (nothing to measure)"
            return
        }
        // Consume the on-open request either way: this call is the answer to it.
        preflightPendingOnOpen = false
        guard preflight.beginCheck() else {
            // A check already running owns the footer; say nothing and leave it alone.
            if preflight.isResizing { footer = "preflight → wait for the resize in flight" }
            return
        }
        selfcheckID += 1
        let id = selfcheckID
        busy = true
        footer = "preflight → probing the strip at the probe scale (it scales briefly)…"
        Backend.queue.async {
            let result = Backend.selfcheck()
            DispatchQueue.main.async {
                guard id == self.selfcheckID else {
                    // An arm/disarm change superseded this run; a newer check owns `busy`.
                    if !self.preflight.isChecking { self.busy = false }
                    return
                }
                self.busy = false
                if let report = result.decode(SelfcheckReport.self) {
                    self.preflight.finishCheck(report)
                } else {
                    self.preflight.failCheck(PreflightFailure.line(for: result))
                }
                if let reason = self.preflight.reason {
                    self.footer = "preflight → " + reason
                    self.lastError = reason
                } else if self.preflight.isReady {
                    let tiles = self.preflight.lastReport?.tiles.count ?? 0
                    self.footer = "preflight → ok, \(tiles) tile(s) at the probe scale"
                }
                self.refresh()
            }
        }
    }

    // MARK: - resize (slider, sweep-based)

    /// The slider applies on release; a short debounce also covers an accessibility-driven value
    /// change that never sends `onEditingChanged(false)`.
    func sliderChanged(_ v: Double) {
        // A disabled slider must not even move its readout: the strip is at the probe scale or
        // the bases have not been verified, and a value the tool will not apply is a lie.
        guard preflight.sliderEnabled else { return }
        scale = v
        scaleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applyScale(v) }
        scaleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    func resetScale() {
        guard preflight.sliderEnabled else {
            footer = "resize → preflight " + (preflight.reason ?? "has not passed")
            return
        }
        scale = 1.0
        applyScale(1.0)
    }

    func applyScale(_ s: Double) {
        guard armed else {
            footer = "not armed — resize needs the payload"
            return
        }
        // One serialisation point for "a resize and a preflight never overlap": beginResize
        // refuses while a check is in flight and refuses before a check has passed.
        guard preflight.beginResize() else {
            if preflight.isChecking {
                footer = "resize → waiting for the preflight to finish"
            } else {
                footer = "resize → preflight " + (preflight.reason ?? "has not passed")
            }
            return
        }
        busy = true
        footer = "resize \(Int((s * 100).rounded()))% → sweeping…"
        Backend.queue.async {
            let r = Backend.run(.resize(scale: s))
            DispatchQueue.main.async {
                self.preflight.endResize()
                self.busy = false
                if let report = r.decode(ResizeReport.self) {
                    self.lastResize = report
                    if report.ok {
                        self.footer = "resize \(String(format: "%.2f", s)) → ok, \(report.tiles.count) tiles ["
                            + report.ratios.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]"
                    } else {
                        self.footer = "resize \(String(format: "%.2f", s)) → "
                            + (report.err ?? "failed")
                        self.lastError = report.err ?? "resize failed"
                    }
                } else {
                    self.footer = "resize → error: \(Self.lastLine(r.combined))"
                    self.lastError = Self.lastLine(r.combined)
                }
                self.refresh()
            }
        }
    }

    // MARK: - gesture (direct scale writes)

    /// The gesture's scale, written straight into the payload config (which bumps `cfg_gen`).
    /// It deliberately does not call `.resize`: that path sweeps the pointer over every tile and
    /// takes a minute or two.
    ///
    /// Writes are coalesced to one in flight: the tap produces up to 60 targets a second, while a
    /// config write is a short root round-trip.  The latest target is applied as soon as the
    /// previous write finishes, so the strip follows the gesture without a backlog.
    ///
    /// A probe or a resize owns the strip while it runs: a config write in the middle of either
    /// would change the geometry being measured.  The gesture is ignored — without moving the
    /// readout — until that work finishes.
    private func gestureScale(_ value: Double) {
        guard !preflight.isChecking, !preflight.isResizing else { return }
        scale = value
        hud.show("Strip \(Int((value * 100).rounded()))%")
        enqueueDirectScale(value)
    }

    private func gestureEnded(_ value: Double) {
        guard !preflight.isChecking, !preflight.isResizing else { return }
        scale = value
        hud.show("Strip \(Int((value * 100).rounded()))%")
        enqueueDirectScale(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.gestureConfig = nil
            self.refresh()
        }
    }

    private func enqueueDirectScale(_ value: Double) {
        guard armed, !preflight.isChecking, !preflight.isResizing else { return }
        pendingGestureScale = value
        if gestureConfig == nil { loadGestureConfig() }
        pumpGestureScale()
    }

    /// Runs on every change of the write pump's two flags.  The gate uses it to keep a probe or
    /// a resize from starting while the tap is still writing `s` into the payload.
    private func syncGestureInFlight() {
        preflight.setGestureInFlight(writingGestureScale || pendingGestureScale != nil)
    }

    private func loadGestureConfig() {
        guard !loadingGestureConfig else { return }
        loadingGestureConfig = true
        Backend.queue.async {
            let config = Backend.config()
            DispatchQueue.main.async {
                self.loadingGestureConfig = false
                if let config {
                    self.gestureConfig = config
                    self.pumpGestureScale()
                } else {
                    // Without a config there is no write to land.  Dropping the queued target
                    // releases the gate; the next gesture event reads the config again.
                    self.pendingGestureScale = nil
                }
            }
        }
    }

    private func pumpGestureScale() {
        guard let base = gestureConfig, !writingGestureScale,
              let target = pendingGestureScale else { return }
        // Claim the write before clearing the queue entry, so the gate never sees a false
        // "nothing in flight" between the two assignments.
        writingGestureScale = true
        pendingGestureScale = nil
        var config = base
        config.values["s"] = target
        config.values["dilate"] = abs(target - 1.0) > 1e-9
        Backend.queue.async {
            let result = Backend.writeConfig(config)
            DispatchQueue.main.async {
                self.writingGestureScale = false
                if result.code == 0 {
                    self.gestureConfig = config
                } else {
                    // A failed write has no continuation: drop the queued target so the gate
                    // does not wait for a write that will never finish.
                    self.gestureConfig = nil
                    self.pendingGestureScale = nil
                    self.lastError = "scale \(String(format: "%.2f", target)) → "
                        + Self.lastLine(result.combined)
                }
                if self.pendingGestureScale != nil { self.pumpGestureScale() }
            }
        }
    }

    // MARK: - drag a window onto a tile

    /// The drop point and the window under the mouse-down, captured by the tap.  Frames are read
    /// now, at release time, because the strip animates as it reveals during the drag.
    func handleDrop(at point: CGPoint, cgid: CGWindowID?) {
        guard armed else { return }
        Backend.queue.async {
            let snapshot = Backend.stageSnapshot()
            DispatchQueue.main.async {
                self.stages = snapshot.stages
                self.stripGutter = snapshot.strip
                self.inputTap.gutter = snapshot.strip
                let decision = DropHitTest.resolve(point: point,
                                                   strip: snapshot.strip,
                                                   tiles: snapshot.stages)
                switch decision {
                case .move(let tile):
                    self.performDropMove(tile, cgid: cgid)
                case .ambiguous(let hits):
                    self.ambiguousDrops += 1
                    self.footer = "drop → ambiguous (\(hits.count) tiles); nothing moved"
                case .emptyGutter:
                    self.footer = "drop → empty gutter; macOS keeps its behaviour"
                case .ignore:
                    break
                }
            }
        }
    }

    private func performDropMove(_ tile: StageItem, cgid: CGWindowID?) {
        guard armed, !dropping else { return }
        guard tile.addressable else {
            footer = "drop → tile has no title (the CLI addresses stages by title)"
            return
        }
        // Only the window captured under the press is moved.  Falling back to "the frontmost
        // window" would let a press on the strip itself move an unrelated window; a drop we
        // cannot attribute is a drop we do not act on.
        guard let cgid else {
            footer = "drop → could not identify the dragged window; nothing moved"
            return
        }
        dropping = true
        let command = SturgeonCommand.moveWindow(stage: tile.title, cgid: Int(cgid))
        footer = "drop → \(tile.label)…"
        Backend.queue.async {
            let r = Backend.run(command)
            DispatchQueue.main.async {
                self.dropping = false
                if let report = r.decode(MoveReport.self) {
                    if report.ok {
                        self.footer = "drop → \(tile.label): ok (cgid \(report.cgid.map(String.init) ?? "?"))"
                    } else {
                        self.footer = "drop → \(tile.label): \(report.err ?? "failed")"
                        self.lastError = report.err ?? "move failed"
                    }
                } else {
                    self.footer = "drop → error: \(Self.lastLine(r.combined))"
                    self.lastError = Self.lastLine(r.combined)
                }
                self.refresh(stages: true)
            }
        }
    }

    // MARK: - lifecycle actions

    func start() {
        guard !busy else { return }
        busy = true
        footer = "start → doctor, install, observers, daemon…"
        Backend.queue.async {
            let r = Backend.run(.start)
            let st = Backend.status()
            DispatchQueue.main.async {
                self.busy = false
                self.footer = "start → \(Self.lastLine(r.combined))"
                if r.code != 0 { self.lastError = Self.lastLine(r.combined) }
                self.apply(status: st)
                self.runDoctor()
                self.refreshStages()
                // A freshly armed payload has no verdict yet; the slider must not wait for the
                // next popover open to become usable.
                if self.armed { self.runSelfcheck() }
            }
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true
        footer = "stop → restoring the pristine WindowManager…"
        Backend.queue.async {
            let r = Backend.run(.stop)
            let st = Backend.status()
            DispatchQueue.main.async {
                self.busy = false
                let tail = r.out.split(separator: "\n").last.map(String.init) ?? Self.lastLine(r.combined)
                self.footer = "stop → \(tail)"
                if r.code != 0 { self.lastError = Self.lastLine(r.combined) }
                self.apply(status: st)
                self.runDoctor()
            }
        }
    }

    func move(to stage: StageItem) {
        guard armed else {
            footer = "not armed — move needs the payload"
            return
        }
        guard stage.addressable else {
            footer = "move → stage has no title (the CLI addresses stages by title)"
            return
        }
        busy = true
        footer = "move → \(stage.label)…"
        Backend.queue.async {
            let r = Backend.run(.move(stage: stage.title))
            DispatchQueue.main.async {
                self.busy = false
                if let report = r.decode(MoveReport.self) {
                    if report.ok {
                        self.footer = "move → \(stage.label): ok (cgid \(report.cgid.map(String.init) ?? "?"))"
                    } else {
                        self.footer = "move → \(stage.label): \(report.err ?? "failed")"
                        self.lastError = report.err ?? "move failed"
                    }
                } else {
                    self.footer = "move → error: \(Self.lastLine(r.combined))"
                    self.lastError = Self.lastLine(r.combined)
                }
                self.refresh(stages: true)
            }
        }
    }

    // MARK: - diagnostics

    var appVersion: String {
        guard let info = Bundle.main.infoDictionary,
              let short = info["CFBundleShortVersionString"] as? String else { return "dev" }
        if let build = info["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    /// Built on the main thread from already-decoded reports; no process is started here.
    func diagnosticsSnapshot() -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            appVersion: appVersion,
            bundleLayout: Paths.current?.layout.rawValue ?? "none",
            status: lastStatus,
            doctor: doctorReport,
            counters: fullCounters,
            countersNote: countersNote,
            resize: lastResize,
            preflight: preflight,
            lastError: lastError,
            gesture: inputStatus,
            ambiguousDrops: ambiguousDrops,
            inputRearms: inputRearms,
            traceOn: trace,
            traceRecordCount: trace ? traceRead?.total : nil,
            traceNote: trace ? traceRead?.note : nil,
            armed: armed)
    }

    func diagnosticsText() -> String { diagnosticsSnapshot().block() }

    func copyDiagnostics() {
        let block = diagnosticsText()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(block, forType: .string)
        footer = "diagnostics copied (\(block.count) characters)"
    }

    // MARK: - setup / permissions

    func setup() {
        guard !busy else { return }
        guard Paths.root != nil else {
            footer = "setup → bundle incomplete (Resources/wmship missing)"
            return
        }
        guard let script = Paths.setupScript,
              FileManager.default.isExecutableFile(atPath: script.path) else {
            footer = "setup → bundle incomplete (setup.sh missing)"
            return
        }
        busy = true
        footer = "setup → checking root…"
        let apple = Self.appleScriptString("\(Paths.quote(script.path)) 2>&1")
        Backend.queue.async {
            if Backend.rootWorks() {
                DispatchQueue.main.async {
                    self.busy = false
                    self.setupNeeded = false
                    self.footer = "setup → already set up (root via the bundled asroot path)"
                    self.refresh(doctor: true, stages: true)
                }
                return
            }
            DispatchQueue.main.async { self.footer = "setup → waiting for administrator approval…" }
            let r = Backend.exec("/usr/bin/osascript",
                                 ["-e", "do shell script \(apple) with administrator privileges"],
                                 timeout: 300)
            let ok = Backend.rootWorks()
            DispatchQueue.main.async {
                self.busy = false
                if r.code == 0 && ok {
                    self.setupNeeded = false
                    self.footer = "setup → complete; sudoers rule + LaunchDaemon installed"
                } else if r.code != 0 {
                    self.footer = "setup → cancelled or failed: \(Self.lastLine(r.combined))"
                } else {
                    self.footer = "setup → setup.sh ran but root still refused"
                }
                self.refresh(doctor: true, stages: true)
            }
        }
    }

    func requestInputPermissions() {
        inputTap.requestPermissions()
        inputStatus = inputTap.statusText
    }

    func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(u)
        }
    }

    func openInputMonitoringSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(u)
        }
    }

    func quit() { NSApp.terminate(nil) }

    // MARK: - helpers

    static func lastLine(_ s: String) -> String {
        s.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    static func appleScriptString(_ s: String) -> String {
        let one = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "; ")
        let esc = one.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(esc)\""
    }

    deinit {
        stageTimer?.invalidate()
    }
}
