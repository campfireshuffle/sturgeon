import AppKit
import Foundation

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
        guard let j = r.json else {
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
        if let b = j["build"] as? String, !b.isEmpty { build = b } else { build = wmBuildFallback }
        pid = (j["pid"] as? Int) ?? wmPidFallback
        armed = (j["state"] as? String) == "ARMED"
        sitesTotal = (j["sites_total"] as? Int) ?? 6
        sitesPatched = (j["sites_patched"] as? Int) ?? 0
        debugger = (j["debugger"] as? String) ?? debuggerFallback
        reason = j["reason"] as? String
        helper = (j["helper"] as? [String])?.first ?? "none"
        if let d = j["daemon"] as? [String: Any] {
            daemonLoaded = (d["loaded"] as? Bool) ?? false
        }
        if let caps = j["caps"] as? [String: Any] {
            births = (caps["births"] as? Bool) ?? false
            let replay = (caps["replay"] as? Bool) ?? false
            let levels = (caps["levels"] as? Bool) ?? false
            onTop = replay && levels
            level3 = ((caps["level_manual"] as? Int) ?? 0) == 3
            if !isEditingScale, let s = caps["s"] as? Double { scale = s }
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
                if let j = r.json {
                    let ok = (j["ok"] as? Bool) ?? false
                    if let b = j["build"] as? String, !b.isEmpty { self.build = b }
                    let checks = (j["checks"] as? [[String: Any]]) ?? []
                    let failed = checks.filter { ($0["ok"] as? Bool) == false }
                    let names = failed.compactMap { $0["check"] as? String }
                    // `doctor` validates a *pristine* WindowManager by design, so while armed it
                    // must fail the six byte-equality checks that are our own patch.  Those (and
                    // only those) are expected: the arm gate itself already passed.
                    let patchedOnly = !names.isEmpty && names.allSatisfy {
                        $0.hasSuffix(".file-eq-live") || $0.hasSuffix(".keeper-prologue")
                    }
                    if ok {
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
                        let refusals = (j["refusals"] as? [String]) ?? []
                        if let first = refusals.first {
                            self.doctorRefusal = first
                        } else if let bad = failed.first {
                            self.doctorRefusal = "\(bad["check"] ?? "check"): \(bad["detail"] ?? "")"
                        } else {
                            self.doctorRefusal = "doctor refused"
                        }
                        self.footer = "doctor: " + (self.doctorRefusal ?? "FAIL")
                    }
                } else {
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
                }
            }
        }
    }

    // MARK: - config writes

    func setBirths(_ v: Bool) {
        births = v
        writeCfg(["births": v], label: "births=\(v)")
    }

    /// One toggle, both keys: replay (the keeper re-emits the pose set) and levels.
    func setOnTop(_ v: Bool) {
        onTop = v
        writeCfg(["replay": v, "levels": v], label: "replay=\(v) levels=\(v)")
    }

    func setLevel3(_ v: Bool) {
        level3 = v
        writeCfg(["level_manual": v ? 3 : 0], label: "level_manual=\(v ? 3 : 0)")
    }

    private func writeCfg(_ changes: [String: Any], label: String) {
        guard armed else {
            footer = "not armed — the payload config is not writable"
            return
        }
        busy = true
        footer = "writing cfg \(label)…"
        Backend.queue.async {
            var cfg = Backend.cfg() ?? [:]
            for (k, v) in changes { cfg[k] = v }
            let w = Backend.writeCfg(cfg)
            let after = Backend.cfg() ?? [:]
            DispatchQueue.main.async {
                self.busy = false
                if w.code == 0 {
                    self.footer = "cfg \(label) → written; read-back \(Self.brief(after))"
                } else {
                    self.footer = "cfg \(label) → error: \(Self.lastLine(w.combined))"
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
            let r = Backend.wmship(["resize", String(format: "%.2f", s)], timeout: 180)
            DispatchQueue.main.async {
                self.resizing = false
                self.busy = false
                if let j = r.json {
                    let ok = (j["ok"] as? Bool) ?? false
                    let tiles = (j["tiles"] as? [[String: Any]]) ?? []
                    let ratios = tiles.compactMap { $0["ratio"] as? Double }
                    if ok {
                        self.footer = "resize \(String(format: "%.2f", s)) → ok, \(tiles.count) tiles ["
                            + ratios.map { String(format: "%.2f", $0) }.joined(separator: " ") + "]"
                    } else {
                        self.footer = "resize \(String(format: "%.2f", s)) → "
                            + ((j["err"] as? String) ?? "failed")
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
            let r = Backend.wmship(["start"], timeout: 300)
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
            let r = Backend.wmship(["stop"], timeout: 240)
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
            let r = Backend.wmship(["move", stage.title], timeout: 180)
            DispatchQueue.main.async {
                self.busy = false
                if let j = r.json {
                    if (j["ok"] as? Bool) == true {
                        self.footer = "move → \(stage.label): ok (cgid \(j["cgid"] ?? "?"))"
                    } else {
                        self.footer = "move → \(stage.label): \((j["err"] as? String) ?? "failed")"
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

    static func brief(_ c: [String: Any]) -> String {
        let keys = ["births", "replay", "levels", "level_manual", "s"]
        return keys.map { k in
            if let v = c[k] as? Bool { return "\(k)=\(v)" }
            if let v = c[k] as? Int { return "\(k)=\(v)" }
            if let v = c[k] as? Double { return String(format: "%@=%.2f", k, v) }
            if let v = c[k] { return "\(k)=\(v)" }
            return "\(k)=?"
        }.joined(separator: " ")
    }

    static func appleScriptString(_ s: String) -> String {
        let one = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: "; ")
        let esc = one.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(esc)\""
    }
}
