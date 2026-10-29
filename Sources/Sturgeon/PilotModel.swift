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
    @Published var trace = false

    // diagnostics
    @Published var diagnosticsOpen = false
    @Published var lastResize: ResizeReport?
    @Published var fullCounters: CountersReport?
    @Published var lastError: String?
    @Published var ambiguousDrops = 0
    @Published var inputStatus = "off (disarmed)"
    @Published var inputRearms = 0
    @Published var stripGutter: CGRect?

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
    private var resizing = false
    private var lastStatusAt = Date.distantPast
    private var lastStagesAt = Date.distantPast
    /// Keeps the strip rect fresh while armed, even with the popover closed.  The gesture needs
    /// it to decide whether the pointer is in the gutter, and the strip rect moves with the
    /// display and the reveal state.
    private var stageTimer: Timer?

    // direct (non-sweeping) scale writes used by the gesture
    private var gestureConfig: PayloadConfig?
    private var loadingGestureConfig = false
    private var pendingGestureScale: Double?
    private var writingGestureScale = false

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
    /// command needs root, so it runs through the same asroot passthrough as status; the tick is
    /// also where a tap that macOS disabled is noticed and re-armed.
    func refreshDiagnostics() {
        guard armed else {
            fullCounters = nil
            inputRearms = inputTap.rearmCount
            inputStatus = inputTap.statusText
            return
        }
        inputTap.ensureEnabled()
        Backend.queue.async {
            let counters = Backend.counters()
            let config = Backend.config()
            DispatchQueue.main.async {
                if let counters { self.fullCounters = counters }
                if let config { self.trace = config.trace }
                self.inputRearms = self.inputTap.rearmCount
                self.inputStatus = self.inputTap.statusText
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
            if !isEditingScale, let s = caps.scale { scale = s }
        } else if !armed {
            births = false
            onTop = false
            level3 = false
        }
        inputTap.setBaseScale(scale)
        updateInputs()
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

    func setTrace(_ v: Bool) {
        trace = v
        writeConfig(.trace(v))
    }

    private func writeConfig(_ change: ConfigChange) {
        guard armed else {
            footer = "not armed — the payload config is not writable"
            return
        }
        busy = true
        footer = "writing cfg \(change.label)…"
        Backend.queue.async {
            var config = Backend.config() ?? PayloadConfig()
            config.apply(change)
            let written = Backend.writeConfig(config)
            let after = Backend.config() ?? PayloadConfig()
            DispatchQueue.main.async {
                self.busy = false
                // Any other write invalidates the gesture's cached config; otherwise a gesture
                // could re-apply a stale `births`/`levels` value it read before this change.
                self.gestureConfig = nil
                if written.code == 0 {
                    self.footer = "cfg \(change.label) → written; read-back \(after.brief)"
                    self.trace = after.trace
                } else {
                    self.footer = "cfg \(change.label) → error: \(Self.lastLine(written.combined))"
                    self.lastError = Self.lastLine(written.combined)
                }
                self.refresh()
            }
        }
    }

    // MARK: - resize (slider, sweep-based)

    /// The slider applies on release; a short debounce also covers an accessibility-driven value
    /// change that never sends `onEditingChanged(false)`.
    func sliderChanged(_ v: Double) {
        scale = v
        scaleWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.applyScale(v) }
        scaleWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: w)
    }

    func resetScale() {
        scale = 1.0
        applyScale(1.0)
    }

    func applyScale(_ s: Double) {
        guard armed else {
            footer = "not armed — resize needs the payload"
            return
        }
        guard !resizing else { return }
        resizing = true
        busy = true
        footer = "resize \(Int((s * 100).rounded()))% → sweeping…"
        Backend.queue.async {
            let r = Backend.run(.resize(scale: s))
            DispatchQueue.main.async {
                self.resizing = false
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
    private func gestureScale(_ value: Double) {
        scale = value
        hud.show("Strip \(Int((value * 100).rounded()))%")
        enqueueDirectScale(value)
    }

    private func gestureEnded(_ value: Double) {
        scale = value
        hud.show("Strip \(Int((value * 100).rounded()))%")
        enqueueDirectScale(value)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            self.gestureConfig = nil
            self.refresh()
        }
    }

    private func enqueueDirectScale(_ value: Double) {
        guard armed else { return }
        pendingGestureScale = value
        if gestureConfig == nil { loadGestureConfig() }
        pumpGestureScale()
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
                }
            }
        }
    }

    private func pumpGestureScale() {
        guard let base = gestureConfig, !writingGestureScale,
              let target = pendingGestureScale else { return }
        pendingGestureScale = nil
        writingGestureScale = true
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
                    self.gestureConfig = nil
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
            resize: lastResize,
            lastError: lastError,
            trace: trace,
            gesture: inputStatus,
            ambiguousDrops: ambiguousDrops,
            inputRearms: inputRearms,
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
