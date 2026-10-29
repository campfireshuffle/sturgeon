import Foundation

struct RunResult {
    var code: Int32 = -1
    var out: String = ""
    var err: String = ""
    var timedOut: Bool = false

    var combined: String {
        [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var json: [String: Any]? {
        let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let d = t.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
           let m = o as? [String: Any] { return m }
        // some commands prefix a line; use the last JSON object in the output
        if let r = t.range(of: "{", options: .backwards), let d = String(t[r.lowerBound...])
            .data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d),
           let m = o as? [String: Any] { return m }
        return nil
    }
}

/// Every call is made on a background queue; nothing here touches AppKit.
enum Backend {
    static let queue = DispatchQueue(label: "run.lil.sturgeon.backend",
                                     qos: .userInitiated, attributes: .concurrent)

    static func exec(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        if let root = Paths.root {
            env["WMSHIP_WORK"] = root.path          // contract for the relocatable scripts
            env["STURGEON_WMSHIP_ROOT"] = root.path
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        p.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return RunResult(code: -1, out: "", err: "cannot run \(path): \(error)")
        }
        var outData = Data(), errData = Data()
        let g = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: g) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: g) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var timedOut = false
        if p.isRunning {
            timedOut = true
            p.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        _ = g.wait(timeout: .now() + 3)
        let result = RunResult(code: p.terminationStatus,
                               out: String(data: outData, encoding: .utf8) ?? "",
                               err: String(data: errData, encoding: .utf8) ?? "",
                               timedOut: timedOut)
        log(result, path, args)
        return result
    }

    /// Every command the app runs is appended verbatim to ~/Library/Logs/Sturgeon.log.  The
    /// proof reads this file, so "the exact commands the app runs" is an artefact, not a claim.
    static func log(_ r: RunResult, _ path: String, _ args: [String]) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Sturgeon.log")
        let ts = ISO8601DateFormatter().string(from: Date())
        let cmd = ([path] + args).map { a -> String in
            a.contains(" ") || a.contains("'") || a.contains("\n")
                ? "'" + a.replacingOccurrences(of: "'", with: "'\\''") + "'" : a
        }.joined(separator: " ")
        var s = "\(ts) $ \(cmd)\n"
        var body = r.out
        if !r.err.isEmpty { body += (body.isEmpty ? "" : "\n") + "[stderr] " + r.err }
        if body.count > 65536 { body = String(body.prefix(65536)) + "\n…(truncated)\n" }
        s += body
        if !body.hasSuffix("\n") { s += "\n" }
        s += "[exit \(r.code)\(r.timedOut ? " timeout" : "")]\n"
        if let sz = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, sz > 2_000_000 {
            try? fm.removeItem(at: url.appendingPathExtension("1"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        if let d = s.data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(d); try? h.close()
            } else {
                try? d.write(to: url)
            }
        }
    }

    /// The ONLY root path: `sudo -n <bundle>/asroot -c '<cmd>'`.
    static func root(_ command: String, timeout: TimeInterval = 120) -> RunResult {
        guard let asroot = Paths.asroot else {
            return RunResult(code: -1, out: "", err: "bundle incomplete: asroot missing")
        }
        return exec("/usr/bin/sudo", ["-n", asroot.path, "-c", command], timeout: timeout)
    }

    static func wmship(_ args: [String], timeout: TimeInterval = 120) -> RunResult {
        guard let s = Paths.wmship else {
            return RunResult(code: -1, out: "", err: "bundle incomplete: wmship.sh missing")
        }
        return exec(s.path, args, timeout: timeout)
    }

    // ---------------------------------------------------------------- concrete commands
    /// `install.py status --json` through the asroot path.  Returns the raw result so the model
    /// can distinguish "not set up" (sudo refused) from "tool not installed" (valid JSON,
    /// state=DISARMED), which is the difference between the Setup banner and the DISARMED badge.
    static func status() -> RunResult {
        guard let py = Paths.installPy else {
            return RunResult(code: -1, out: "", err: "bundle incomplete: install.py missing")
        }
        return root("/usr/bin/python3 \(Paths.quote(py.path)) status --json", timeout: 40)
    }

    static func doctor() -> RunResult {
        wmship(["doctor", "--json"], timeout: 240)
    }

    static func stages() -> [StageItem] {
        guard let exe = Paths.stagepilot else { return [] }
        let r = exec(exe.path, ["stages"], timeout: 20)
        return StageItem.parse(r.out)
    }

    static func cfg() -> [String: Any]? {
        let r = wmship(["cfg"], timeout: 40)
        guard let j = r.json, j["ok"] as? Bool != false else { return nil }
        return j
    }

    /// `install.py cfg '<json>'` through asroot: the same write `ctl.py::cfg_set` performs.
    static func writeCfg(_ cfg: [String: Any]) -> RunResult {
        guard let py = Paths.installPy else {
            return RunResult(code: -1, out: "", err: "bundle incomplete: install.py missing")
        }
        guard let d = try? JSONSerialization.data(withJSONObject: cfg, options: [.sortedKeys]),
              let json = String(data: d, encoding: .utf8) else {
            return RunResult(code: -1, out: "", err: "cannot encode cfg")
        }
        return root("/usr/bin/python3 \(Paths.quote(py.path)) cfg \(Paths.quote(json))", timeout: 40)
    }

    static func rootWorks() -> Bool {
        root("true", timeout: 20).code == 0
    }

    /// Debugger presence without root (pgrep is unprivileged).  Used when `status --json` cannot
    /// run at all, so the row still answers the one question it must never leave blank.
    static func debuggerText() -> String {
        var found: [String] = []
        let lldb = exec("/usr/bin/pgrep", ["-x", "lldb"], timeout: 5)
        if lldb.code == 0 {
            found.append("lldb " + lldb.out.split(separator: "\n").joined(separator: ","))
        }
        let ds = exec("/usr/bin/pgrep", ["-f", "Resources/debugserver"], timeout: 5)
        if ds.code == 0 {
            found.append("debugserver " + ds.out.split(separator: "\n").joined(separator: ","))
        }
        return found.isEmpty ? "none" : found.joined(separator: "; ")
    }
}

struct StageItem: Identifiable, Equatable {
    let id: Int
    let title: String
    let windows: [Int]

    var label: String { title.isEmpty ? "Untitled stage \(id + 1)" : title }
    var addressable: Bool { !title.isEmpty }

    /// `[0] 'Granola' frame=(...) windows=[59, 57, 434]`
    static func parse(_ text: String) -> [StageItem] {
        var out: [StageItem] = []
        for line in text.split(separator: "\n") {
            let s = String(line)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { continue }
            let idx = Int(s[s.index(after: s.startIndex)..<close]) ?? out.count
            var title = ""
            if let a = s.range(of: "'"), let b = s.range(of: "'", options: .backwards), a.upperBound <= b.lowerBound {
                title = String(s[a.upperBound..<b.lowerBound])
            }
            var ids: [Int] = []
            if let a = s.range(of: "windows=["), let b = s.range(of: "]", range: a.upperBound..<s.endIndex) {
                ids = s[a.upperBound..<b.lowerBound].split(separator: ",").compactMap {
                    Int($0.trimmingCharacters(in: .whitespaces))
                }
            }
            out.append(StageItem(id: idx, title: title, windows: ids))
        }
        return out.sorted { $0.id < $1.id }
    }
}
