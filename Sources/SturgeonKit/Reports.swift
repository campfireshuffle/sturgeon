import Foundation

/// `install.py status --json` — the document the popover's status rows render.
///
/// Every field is decoded leniently: the tool is allowed to add keys, drop keys, or write `null`
/// for "unknown", and a status row must still render. Only `state` has a default of consequence.
public struct StatusReport: Equatable {
    public var build: String?
    public var pid: Int?
    public var state: String
    public var reason: String?
    public var sitesPatched: Int
    public var sitesTotal: Int
    public var debugger: String?
    public var helper: [String]
    public var daemon: Daemon
    public var caps: Capabilities?
    /// The aggregate heartbeat counters `status --json` carries (`inject`, `cmp`, `ret`,
    /// `miss`, `rej`).  The keeper's fuller set comes from `install.py counters`.
    public var counters: [String: Int]?

    public var isArmed: Bool { state == "ARMED" }

    public init(build: String? = nil,
                pid: Int? = nil,
                state: String = "DISARMED",
                reason: String? = nil,
                sitesPatched: Int = 0,
                sitesTotal: Int = 6,
                debugger: String? = nil,
                helper: [String] = [],
                daemon: Daemon = Daemon(),
                caps: Capabilities? = nil,
                counters: [String: Int]? = nil) {
        self.build = build
        self.pid = pid
        self.state = state
        self.reason = reason
        self.sitesPatched = sitesPatched
        self.sitesTotal = sitesTotal
        self.debugger = debugger
        self.helper = helper
        self.daemon = daemon
        self.caps = caps
        self.counters = counters
    }

    public struct Daemon: Equatable {
        public var loaded = false
        public var pids: [String] = []
        public var state: String?
        public var armed: Bool?
        public var reason: String?

        public init() {}
    }

    public struct Capabilities: Equatable {
        public var births = false
        public var replay = false
        public var levels = false
        public var levelManual = 0
        /// Absent in an empty `caps` document, which must not overwrite the slider.
        public var scale: Double?
        public var move: String?

        public init() {}
    }
}

extension StatusReport: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        build = v(.build, String.self).flatMap { $0.isEmpty ? nil : $0 }
        pid = v(.pid, Int.self)
        state = v(.state, String.self) ?? "DISARMED"
        reason = v(.reason, String.self)
        sitesPatched = v(.sitesPatched, Int.self) ?? 0
        sitesTotal = v(.sitesTotal, Int.self) ?? 6
        debugger = v(.debugger, String.self)
        helper = v(.helper, [String].self) ?? []
        daemon = v(.daemon, Daemon.self) ?? Daemon()
        caps = v(.caps, Capabilities.self)
        counters = v(.counters, [String: Int].self)
    }

    private enum Key: String, CodingKey {
        case build, pid, state, reason, debugger, helper, daemon, caps, counters
        case sitesPatched = "sites_patched"
        case sitesTotal = "sites_total"
    }
}

extension StatusReport.Daemon: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        loaded = v(.loaded, Bool.self) ?? false
        pids = v(.pids, [String].self) ?? []
        state = v(.state, String.self)
        armed = v(.armed, Bool.self)
        reason = v(.reason, String.self)
    }

    private enum Key: String, CodingKey {
        case loaded, pids, state, armed, reason
    }
}

extension StatusReport.Capabilities: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        births = v(.births, Bool.self) ?? false
        replay = v(.replay, Bool.self) ?? false
        levels = v(.levels, Bool.self) ?? false
        levelManual = v(.levelManual, Int.self) ?? 0
        scale = v(.scale, Double.self)
        move = v(.move, String.self)
    }

    private enum Key: String, CodingKey {
        case births, replay, levels, move
        case levelManual = "level_manual"
        case scale = "s"
    }
}

/// `wmship.sh doctor --json` (install.py's doctor). The app only needs the verdict, the failing
/// checks and the first refusal, but keeping the check list typed is what lets the armed case
/// recognise exactly its own patch bytes.
public struct DoctorReport: Equatable {
    public var ok: Bool
    public var build: String?
    public var checks: [Check]
    public var refusals: [String]

    public var failedChecks: [Check] { checks.filter { !$0.ok } }

    public init(ok: Bool = false, build: String? = nil, checks: [Check] = [], refusals: [String] = []) {
        self.ok = ok
        self.build = build
        self.checks = checks
        self.refusals = refusals
    }

    public struct Check: Equatable {
        public var check: String
        public var ok: Bool
        public var detail: String

        public init(check: String, ok: Bool, detail: String = "") {
            self.check = check
            self.ok = ok
            self.detail = detail
        }
    }
}

extension DoctorReport: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        ok = v(.ok, Bool.self) ?? false
        build = v(.build, String.self).flatMap { $0.isEmpty ? nil : $0 }
        checks = v(.checks, [Check].self) ?? []
        refusals = v(.refusals, [String].self) ?? []
    }

    private enum Key: String, CodingKey {
        case ok, build, checks, refusals
    }
}

extension DoctorReport.Check: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        check = v(.check, String.self) ?? "check"
        ok = v(.ok, Bool.self) ?? false
        // `detail` is usually a string, but an older doctor writes a JSON blob for one check.
        detail = v(.detail, String.self) ?? ""
    }

    private enum Key: String, CodingKey {
        case check, ok, detail
    }
}

/// What the popover says about a doctor run. `doctor` validates a *pristine* WindowManager by
/// design, so while armed the six byte-equality checks fail on our own patch and only those
/// failures are expected.
public enum DoctorVerdict: Equatable {
    case pass
    case passArmed
    case fail
    case unavailable

    public var label: String {
        switch self {
        case .pass: return "PASS"
        case .passArmed: return "PASS (armed — live bytes carry the patch)"
        case .fail: return "FAIL"
        case .unavailable: return "unavailable"
        }
    }

    public var isOK: Bool { self == .pass || self == .passArmed }
}

extension DoctorReport {
    public func verdict(armed: Bool) -> DoctorVerdict {
        if ok { return .pass }
        let failed = failedChecks
        let patchedOnly = !failed.isEmpty && failed.allSatisfy {
            $0.check.hasSuffix(".file-eq-live") || $0.check.hasSuffix(".keeper-prologue")
        }
        if armed && patchedOnly { return .passArmed }
        return .fail
    }

    /// The one line a bug report needs: the doctor's own first refusal, then its first failing
    /// check, then a generic refusal.
    public func refusalLine() -> String {
        if let first = refusals.first, !first.isEmpty { return first }
        if let bad = failedChecks.first {
            return bad.detail.isEmpty ? bad.check : "\(bad.check): \(bad.detail)"
        }
        return "doctor refused"
    }
}

/// `install.py counters` — the payload's heartbeat plus the injection log.  The six counters the
/// diagnostics panel shows (`inject`, `miss`, `keep`, `learn`, `replay`, `dil`) all live in `hb`.
public struct CountersReport: Equatable {
    public var heartbeat: [String: Int]
    public var injections: [Injection]
    public var injectionCount: Int?

    public init(heartbeat: [String: Int] = [:],
                injections: [Injection] = [],
                injectionCount: Int? = nil) {
        self.heartbeat = heartbeat
        self.injections = injections
        self.injectionCount = injectionCount
    }

    public var isEmpty: Bool { heartbeat.isEmpty && injections.isEmpty }

    public struct Injection: Equatable, Decodable {
        public var wid: String
        public var cgid: Int

        public init(wid: String, cgid: Int) {
            self.wid = wid
            self.cgid = cgid
        }
    }
}

extension CountersReport: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        heartbeat = (try? c.decodeIfPresent([String: Int].self, forKey: .hb)) ?? [:]
        injections = (try? c.decodeIfPresent([Injection].self, forKey: .injected)) ?? []
        injectionCount = try? c.decodeIfPresent(Int.self, forKey: .injectionCount)
    }

    private enum Key: String, CodingKey {
        case hb, injected
        case injectionCount = "inj_n"
    }
}

/// `ctl.py resize` — `{ok, s, tries, tiles:[{id, owner, w, natural, ratio}], err}`.
public struct ResizeReport: Equatable {
    public var ok: Bool
    public var err: String?
    public var scale: Double?
    public var tries: Int?
    public var tiles: [Tile]

    public init(ok: Bool = false, err: String? = nil, scale: Double? = nil,
                tries: Int? = nil, tiles: [Tile] = []) {
        self.ok = ok
        self.err = err
        self.scale = scale
        self.tries = tries
        self.tiles = tiles
    }

    public var ratios: [Double] { tiles.compactMap(\.ratio) }

    /// One row of the per-tile table: natural → measured → ratio.  `natural` and `ratio` are
    /// absent when the tile had no taught base, which is a finding, not a zero.
    public struct Tile: Equatable, Decodable {
        public var id: Int?
        public var owner: String?
        public var width: Double?
        public var natural: Double?
        public var ratio: Double?

        public init(id: Int? = nil, owner: String? = nil, width: Double? = nil,
                    natural: Double? = nil, ratio: Double? = nil) {
            self.id = id
            self.owner = owner
            self.width = width
            self.natural = natural
            self.ratio = ratio
        }

        private enum CodingKeys: String, CodingKey {
            case id, owner, natural, ratio
            case width = "w"
        }
    }
}

extension ResizeReport: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        ok = v(.ok, Bool.self) ?? false
        err = v(.err, String.self)
        scale = v(.scale, Double.self)
        tries = v(.tries, Int.self)
        tiles = v(.tiles, [Tile].self) ?? []
    }

    private enum Key: String, CodingKey {
        case ok, err, tries, tiles
        case scale = "s"
    }
}

/// `ctl.py move` — `{ok, err, target, cgid, ...}`.
public struct MoveReport: Equatable {
    public var ok: Bool
    public var err: String?
    public var cgid: Int?

    public init(ok: Bool = false, err: String? = nil, cgid: Int? = nil) {
        self.ok = ok
        self.err = err
        self.cgid = cgid
    }
}

extension MoveReport: Decodable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        func v<T: Decodable>(_ key: Key, _ type: T.Type) -> T? {
            guard let value = try? c.decodeIfPresent(type, forKey: key) else { return nil }
            return value
        }
        ok = v(.ok, Bool.self) ?? false
        err = v(.err, String.self)
        cgid = v(.cgid, Int.self)
    }

    private enum Key: String, CodingKey {
        case ok, err, cgid
    }
}
