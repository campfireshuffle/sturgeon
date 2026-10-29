import Foundation

/// One process to run: executable, argv and the deadline the caller wants. Building it is pure;
/// `ProcessRunner` is the only thing that starts a process.
public struct Invocation: Equatable {
    public let executable: URL
    public let arguments: [String]
    public let timeout: TimeInterval

    public init(executable: URL, arguments: [String], timeout: TimeInterval) {
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
    }
}

/// Every way the app talks to the tool tree. Each case maps to exactly one command vector, so the
/// tests can pin the vector for every control without running anything.
public enum SturgeonCommand: Equatable {
    /// `sudo -n asroot -c "python3 install.py status --json"`
    case status
    /// `sudo -n asroot -c "python3 install.py counters"` — the keeper's heartbeat counters.
    case counters
    /// `wmship.sh doctor --json`
    case doctor
    /// `a/stagepilot stages`
    case stages
    /// `wmship.sh cfg`
    case configRead
    /// `sudo -n asroot -c "python3 install.py cfg '<json>'"`
    case configWrite(json: String)
    /// `sudo -n asroot -c "true"` — the unprivileged half of setup.
    case rootProbe
    case start
    case stop
    case resize(scale: Double)
    case move(stage: String)
    /// `wmship.sh move <stage> --cgid N` — the same move, addressed at the dragged window.
    case moveWindow(stage: String, cgid: Int)

    /// The deadlines the popover has always used. A resize sweeps tiles; a start runs doctor and
    /// launchd, so both get minutes, not seconds.
    public var timeout: TimeInterval {
        switch self {
        case .rootProbe: return 20
        case .stages: return 20
        case .status, .counters, .configRead, .configWrite: return 40
        case .doctor, .stop: return 240
        case .start: return 300
        case .resize, .move, .moveWindow: return 180
        }
    }
}

/// The tool tree a command is built against.
public struct Toolchain {
    public let paths: Paths

    public init(paths: Paths) {
        self.paths = paths
    }

    public enum Failure: Error, CustomStringConvertible {
        /// A required entry is missing from the tree; the message matches the app's old wording.
        case bundleIncomplete(String)

        public var description: String {
            switch self {
            case .bundleIncomplete(let what): return "bundle incomplete: \(what)"
            }
        }
    }

    public func invocation(for command: SturgeonCommand) throws -> Invocation {
        switch command {
        case .status:
            return try root("/usr/bin/python3 \(Paths.quote(paths.installPy.path)) status --json",
                            timeout: command.timeout)
        case .counters:
            return try root("/usr/bin/python3 \(Paths.quote(paths.installPy.path)) counters",
                            timeout: command.timeout)
        case .configWrite(let json):
            return try root("/usr/bin/python3 \(Paths.quote(paths.installPy.path)) cfg \(Paths.quote(json))",
                            timeout: command.timeout)
        case .rootProbe:
            return try root("true", timeout: command.timeout)
        case .doctor:
            return wmship(["doctor", "--json"], timeout: command.timeout)
        case .configRead:
            return wmship(["cfg"], timeout: command.timeout)
        case .start:
            return wmship(["start"], timeout: command.timeout)
        case .stop:
            return wmship(["stop"], timeout: command.timeout)
        case .resize(let scale):
            return wmship(["resize", String(format: "%.2f", scale)], timeout: command.timeout)
        case .move(let stage):
            return wmship(["move", stage], timeout: command.timeout)
        case .moveWindow(let stage, let cgid):
            return wmship(["move", stage, "--cgid", String(cgid)], timeout: command.timeout)
        case .stages:
            guard let stagepilot = paths.stagepilot else {
                throw Failure.bundleIncomplete("stagepilot missing")
            }
            return Invocation(executable: stagepilot, arguments: ["stages"], timeout: command.timeout)
        }
    }

    /// The ONLY root path: `sudo -n <tree>/asroot -c '<command>'`. The sudoers rule names that
    /// exact passthrough, so no other command shape can run privileged.
    private func root(_ command: String, timeout: TimeInterval) throws -> Invocation {
        guard let asroot = paths.asroot else {
            throw Failure.bundleIncomplete("asroot missing")
        }
        return Invocation(executable: URL(fileURLWithPath: "/usr/bin/sudo"),
                          arguments: ["-n", asroot.path, "-c", command],
                          timeout: timeout)
    }

    private func wmship(_ arguments: [String], timeout: TimeInterval) -> Invocation {
        Invocation(executable: paths.wmshipScript, arguments: arguments, timeout: timeout)
    }
}
