import AppKit
import Combine
import Foundation
import SturgeonKit

/// Everything the popover renders.  All mutation of @Published state happens on the main thread;
/// the Backend queue only ever produces values.
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

    // doctor
    @Published var doctorOK: Bool?
    @Published var doctorLine = "checking…"
    @Published var doctorRefusal: String?

    // payload config
    @Published var births = false
    @Published var onTop = false
    @Published var level3 = false
    @Published var scale: Double = 1.0

    // stages
    @Published var stages: [StageItem] = []

    // chrome
    @Published var footer = "ready"
    @Published var setupNeeded = false
    @Published var axNeeded = false
    @Published var busy = false
    @Published var isEditingScale = false
    @Published var showSetupBanner = false

    private var scaleWork: DispatchWorkItem?
    private var resizing = false
    private var lastStatusAt = Date.distantPast

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
    }

    // MARK: - refresh

    func refresh(doctor: Bool = false, stages: Bool = false) {
        if doctor { runDoctor() }
        if stages { refreshStages() }
        Backend.queue.async {
            let r = Backend.status()
            let dbg = Backend.debuggerText()
            DispatchQueue.main.async {
                self.apply(status: r, debuggerFallback: dbg)
                self.lastStatusAt = Date()
            }
        }
    }

    func refreshStages() {
        Backend.queue.async {
            let s = Backend.stages()
            DispatchQueue.main.async {
                self.stages = s
                self.axNeeded = s.isEmpty
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
                build = wmBuildFallback
                pid = wmPidFallback
                doctorLine = "not set up"
                doctorOK = false
                debugger = debuggerFallback
                doctorRefusal = "no root: press Set Up (one administrator approval)"
            } else if !r.combined.isEmpty {
                footer = msg.isEmpty ? "status failed" : msg
            }
            return
        }
        setupNeeded = false
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
                if let b = report.build { self.build = b }
                let failed = report.failedChecks
                // `doctor` validates a *pristine* WindowManager by design, so while armed it
                // must fail the six byte-equality checks that are our own patch.  Those (and
                // only those) are expected: the arm gate itself already passed.
                let patchedOnly = !failed.isEmpty && failed.allSatisfy {
                    $0.check.hasSuffix(".file-eq-live") || $0.check.hasSuffix(".keeper-prologue")
                }
                if report.ok {
                    self.doctorOK = true
                    self.doctorLine = "PASS"
                    self.doctorRefusal = nil
                } else if self.armed && patchedOnly {
                    self.doctorOK = true
                    self.doctorLine = "PASS (armed — live bytes carry the patch)"
                    self.doctorRefusal = nil
                } else {
                    self.doctorOK = false
                    self.doctorLine = "FAIL"
                    if let first = report.refusals.first {
                        self.doctorRefusal = first
                    } else if let bad = failed.first {
                        self.doctorRefusal = "\(bad.check): \(bad.detail)"
                    } else {
                        self.doctorRefusal = "doctor refused"
                    }
                    self.footer = "doctor: " + (self.doctorRefusal ?? "FAIL")
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
                if written.code == 0 {
                    self.footer = "cfg \(change.label) → written; read-back \(after.brief)"
                } else {
                    self.footer = "cfg \(change.label) → error: \(Self.lastLine(written.combined))"
                }
                self.refresh()
            }
        }
    }

    // MARK: - resize

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
                    if report.ok {
                        self.footer = "resize \(String(format: "%.2f", s)) → ok, \(report.tiles.count) tiles ["
                            + report.ratios.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]"
                    } else {
                        self.footer = "resize \(String(format: "%.2f", s)) → "
                            + (report.err ?? "failed")
                    }
                } else {
                    self.footer = "resize → error: \(Self.lastLine(r.combined))"
                }
                self.refresh()
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
                    }
                } else {
                    self.footer = "move → error: \(Self.lastLine(r.combined))"
                }
                self.refresh(stages: true)
            }
        }
    }

    // MARK: - setup

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

    func openAccessibilitySettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
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
}
