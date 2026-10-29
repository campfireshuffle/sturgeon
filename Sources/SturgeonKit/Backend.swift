import Foundation

/// The outcome of one process run, plus the two ways the app reads its output: a JSON document
/// (some commands prefix a line before it) and the combined text for the footer.
public struct RunResult {
    public var code: Int32
    public var out: String
    public var err: String
    public var timedOut: Bool

    public init(code: Int32 = -1, out: String = "", err: String = "", timedOut: Bool = false) {
        self.code = code
        self.out = out
        self.err = err
        self.timedOut = timedOut
    }

    public var combined: String {
        [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The last JSON document in stdout: the whole output when it is one, otherwise the last
    /// object that starts with `{`.
    public var jsonData: Data? {
        let text = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = text.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        if let start = text.range(of: "{", options: .backwards),
           let data = String(text[start.lowerBound...]).data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return data
        }
        return nil
    }

    public var jsonObject: [String: Any]? {
        guard let data = jsonData else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    public func decode<T: Decodable>(_ type: T.Type) -> T? {
        guard let data = jsonData else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Every call is made on a background queue; nothing here touches AppKit.
public enum Backend {
    public static let queue = DispatchQueue(label: "run.lil.sturgeon.backend",
                                            qos: .userInitiated, attributes: .concurrent)

    /// This process's tool tree, resolved once.
    public static var paths: Paths? { Paths.current }

    // MARK: - running

    public static func run(_ command: SturgeonCommand) -> RunResult {
        guard let paths = Paths.current else {
            return RunResult(code: -1, out: "", err: "bundle incomplete: \(missingEntry(for: command))")
        }
        do {
            return exec(try Toolchain(paths: paths).invocation(for: command))
        } catch {
            return RunResult(code: -1, out: "", err: "\(error)")
        }
    }

    public static func exec(_ executable: String,
                            _ arguments: [String],
                            timeout: TimeInterval = 60) -> RunResult {
        exec(Invocation(executable: URL(fileURLWithPath: executable),
                        arguments: arguments,
                        timeout: timeout))
    }

    public static func exec(_ invocation: Invocation) -> RunResult {
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        var environment = ProcessInfo.processInfo.environment
        if let tree = Paths.current?.root {
            environment["WMSHIP_WORK"] = tree.path            // contract for the relocatable scripts
            environment["STURGEON_WMSHIP_ROOT"] = tree.path
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin"
        process.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch {
            return RunResult(code: -1, out: "", err: "cannot run \(invocation.executable.path): \(error)")
        }
        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        DispatchQueue.global(qos: .utility).async(group: group) {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        }
        DispatchQueue.global(qos: .utility).async(group: group) {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        }
        let deadline = Date().addingTimeInterval(invocation.timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            Thread.sleep(forTimeInterval: 0.3)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        _ = group.wait(timeout: .now() + 3)
        let result = RunResult(code: process.terminationStatus,
                               out: String(data: outData, encoding: .utf8) ?? "",
                               err: String(data: errData, encoding: .utf8) ?? "",
                               timedOut: timedOut)
        log(result, invocation)
        return result
    }

    private static func missingEntry(for command: SturgeonCommand) -> String {
        switch command {
        case .status, .counters, .configWrite: return "install.py missing"
        case .stages: return "stagepilot missing"
        case .rootProbe: return "asroot missing"
        case .doctor, .configRead, .start, .stop, .resize, .move, .moveWindow, .selfcheck:
            return "wmship.sh missing"
        }
    }

    // MARK: - concrete commands

    public static func status() -> RunResult { run(.status) }

    /// The keeper's full counter set, including `keep`, `learn`, `replay` and `dil` that
    /// `status --json` does not carry.  Falls back to an empty report when the payload is
    /// disarmed, which is a normal answer rather than an error.
    public static func counters() -> CountersReport? {
        run(.counters).decode(CountersReport.self)
    }

    public static func doctor() -> RunResult { run(.doctor) }

    /// The resize preflight.  Its exit code is the CLI's own verdict; the app re-derives it from
    /// the document (`SelfcheckReport.passed`) because a pass without rows is not evidence.
    public static func selfcheck() -> RunResult { run(.selfcheck) }

    public static func stages() -> [StageItem] {
        StageItem.parse(run(.stages).out)
    }

    /// The stage list and the strip rect from the same call, so a drop hit-test uses frames read
    /// at release time rather than a cache from the start of the drag.
    public static func stageSnapshot() -> StageSnapshot {
        StageSnapshot.parse(run(.stages).out)
    }

    public static func config() -> PayloadConfig? {
        let result = run(.configRead)
        guard let object = result.jsonObject, object["ok"] as? Bool != false else { return nil }
        return PayloadConfig(values: object)
    }

    /// `install.py cfg '<json>'` through asroot: the same write `ctl.py::cfg_set` performs.
    public static func writeConfig(_ config: PayloadConfig) -> RunResult {
        guard let json = config.encoded() else {
            return RunResult(code: -1, out: "", err: "cannot encode cfg")
        }
        return run(.configWrite(json: json))
    }

    public static func rootWorks() -> Bool {
        run(.rootProbe).code == 0
    }

    /// Debugger presence without root (pgrep is unprivileged). Used when `status --json` cannot
    /// run at all, so the row still answers the one question it must never leave blank.
    public static func debuggerText() -> String {
        var found: [String] = []
        let lldb = exec("/usr/bin/pgrep", ["-x", "lldb"], timeout: 5)
        if lldb.code == 0 {
            found.append("lldb " + lldb.out.split(separator: "\n").joined(separator: ","))
        }
        let debugserver = exec("/usr/bin/pgrep", ["-f", "Resources/debugserver"], timeout: 5)
        if debugserver.code == 0 {
            found.append("debugserver " + debugserver.out.split(separator: "\n").joined(separator: ","))
        }
        return found.isEmpty ? "none" : found.joined(separator: "; ")
    }

    // MARK: - log

    /// Every command the app runs is appended verbatim to ~/Library/Logs/Sturgeon.log. The proof
    /// reads this file, so "the exact commands the app runs" is an artefact, not a claim.
    static func log(_ result: RunResult, _ invocation: Invocation) {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Sturgeon.log")
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let command = ([invocation.executable.path] + invocation.arguments).map { argument -> String in
            argument.contains(" ") || argument.contains("'") || argument.contains("\n")
                ? "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'" : argument
        }.joined(separator: " ")
        var text = "\(timestamp) $ \(command)\n"
        var body = result.out
        if !result.err.isEmpty { body += (body.isEmpty ? "" : "\n") + "[stderr] " + result.err }
        if body.count > 65536 { body = String(body.prefix(65536)) + "\n…(truncated)\n" }
        text += body
        if !body.hasSuffix("\n") { text += "\n" }
        text += "[exit \(result.code)\(result.timedOut ? " timeout" : "")]\n"
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(at: url.appendingPathExtension("1"))
            try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
        }
        if let data = text.data(using: .utf8) {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(data); try? handle.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
