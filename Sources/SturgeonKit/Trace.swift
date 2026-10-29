import Foundation

/// The payload's own pose trace (issue #31).  With `trace=true` in the config the keeper writes
/// one record per decision into a 16 KB ring; `wmship.sh trace` reads it back over the task port
/// and prints it sorted by sequence number.  The trace is diagnostic only: no branch in the
/// payload reads the ring back, so it cannot influence a decision.
///
/// The line is keyed, not positional beyond the leading sequence number, so a payload that adds
/// a field later is still readable.  Unknown keys are ignored; the known ones are typed.
public struct TraceRecord: Equatable {
    /// The record number the payload assigned (`io_tr_seq`).
    public var seq: Int
    /// The strip window id (`w`).
    public var wid: Int
    /// The submitted matrix's scale entry (`m0`).
    public var m0: Double
    /// The submitted matrix's row-1 column-0 entry (`m4`).
    public var m4: Double
    /// The submitted translation (`x`, `y` = matrix[12], matrix[13]).
    public var x: Double
    public var y: Double
    /// The stored base's scale entry, or `nil` when the window has no base (`b0=-1`).
    public var base0: Double?
    /// The drawn rail width, or `nil` when the window is not a rail tile (`rw=-1`).
    public var railWidth: Double?
    /// `o` — the pose is being drawn.
    public var drawn: Bool
    /// `u` — the write is the keeper's own (ours).
    public var ours: Bool
    /// `b` — the window has a base.
    public var hasBase: Bool
    /// `T` — the pose is teach-legal.
    public var teachLegal: Bool
    /// `r` — the pose is a retract (translation only).
    public var retract: Bool
    /// `a` — the window is not in `rail_now`.
    public var notInRailNow: Bool
    /// `c` — a settle candidate is being held.
    public var candidateHeld: Bool
    /// `h` — the hold window's remaining milliseconds.
    public var holdMs: Int
    /// `q` — the candidate's tick count.
    public var candidateTicks: Int
    /// `sm` — the scale applied to this write.
    public var scale: Double
    /// The line as printed, kept for the table and for a bug report.
    public var raw: String

    /// `nil` when the line is not a trace record.  That is what makes a refusal or a warning on
    /// stdout harmless: only complete, numbered records become rows.
    public init?(line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard let first = tokens.first, let seq = Int(first) else { return nil }

        var fields: [String: String] = [:]
        for token in tokens.dropFirst() {
            guard let equals = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<equals])
            let value = String(token[token.index(after: equals)...])
            fields[key] = value
        }

        guard let widText = fields["w"], let wid = Int(widText),
              let m0 = Self.number(fields, "m0"),
              let m4 = Self.number(fields, "m4"),
              let x = Self.number(fields, "x"),
              let y = Self.number(fields, "y"),
              let base0 = Self.number(fields, "b0"),
              let railWidth = Self.number(fields, "rw"),
              let drawn = Self.flag(fields, "o"),
              let ours = Self.flag(fields, "u"),
              let hasBase = Self.flag(fields, "b"),
              let teachLegal = Self.flag(fields, "T"),
              let retract = Self.flag(fields, "r"),
              let notInRailNow = Self.flag(fields, "a"),
              let candidateHeld = Self.flag(fields, "c"),
              let holdMs = Self.integer(fields, "h"),
              let candidateTicks = Self.integer(fields, "q"),
              let scale = Self.number(fields, "sm")
        else { return nil }

        self.seq = seq
        self.wid = wid
        self.m0 = m0
        self.m4 = m4
        self.x = x
        self.y = y
        // -1 is the payload's "no such thing" sentinel for both of these.
        self.base0 = base0 < 0 ? nil : base0
        self.railWidth = railWidth < 0 ? nil : railWidth
        self.drawn = drawn
        self.ours = ours
        self.hasBase = hasBase
        self.teachLegal = teachLegal
        self.retract = retract
        self.notInRailNow = notInRailNow
        self.candidateHeld = candidateHeld
        self.holdMs = holdMs
        self.candidateTicks = candidateTicks
        self.scale = scale
        self.raw = trimmed
    }

    private static func number(_ fields: [String: String], _ key: String) -> Double? {
        guard let text = fields[key] else { return nil }
        return Double(text)
    }

    private static func integer(_ fields: [String: String], _ key: String) -> Int? {
        guard let text = fields[key] else { return nil }
        return Int(text)
    }

    private static func flag(_ fields: [String: String], _ key: String) -> Bool? {
        guard let text = fields[key], let value = Int(text) else { return nil }
        return value != 0
    }
}

/// The result of one `wmship.sh trace`.  The three states are deliberately distinct: an empty
/// answer is not a read failure, and neither is an empty table that could be mistaken for "the
/// keeper made no decisions".
public enum TraceRead: Equatable {
    /// The last `rows` records, newest last, plus how many the ring held in total.
    case records(rows: [TraceRecord], total: Int)
    /// The command succeeded but the payload returned no ring.  That is what an older image
    /// (one whose `payload.c` does not parse `trace`) looks like from here; the UI must say so
    /// rather than presenting an empty table.
    case unavailable(String)
    /// The command failed: no root, an unknown verb, a dead WindowManager, a timeout.
    case failed(String)

    /// Parse the command's output.  `limit` caps what the table renders; the total is kept so the
    /// header can say "last 40 of 143" rather than implying those are all the records.
    public init(result: RunResult, limit: Int = PoseTrace.maxRows) {
        if result.timedOut {
            self = .failed("trace read timed out")
            return
        }
        let rows = result.out
            .split(whereSeparator: \.isNewline)
            .compactMap { TraceRecord(line: String($0)) }
            .sorted { $0.seq < $1.seq }
        if !rows.isEmpty {
            let cap = max(1, limit)
            self = .records(rows: Array(rows.suffix(cap)), total: rows.count)
            return
        }
        if result.code != 0 {
            self = .failed(Self.refusal(from: result))
            return
        }
        self = .unavailable(
            "the payload returned no trace ring (an older image without the trace key, "
            + "or no keeper decision yet)")
    }

    public var rows: [TraceRecord] {
        if case .records(let rows, _) = self { return rows }
        return []
    }

    public var total: Int {
        if case .records(_, let total) = self { return total }
        return 0
    }

    /// The line to show when there is no table: a refusal for `.failed`, an explanation for
    /// `.unavailable`, and nothing when records were read.
    public var note: String? {
        switch self {
        case .records: return nil
        case .unavailable(let why), .failed(let why): return why
        }
    }

    public var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    /// A tool refusal is the most useful line; the last line is the fallback for any other
    /// failure.  Both are kept verbatim so the UI cannot turn a refusal into a generic message.
    private static func refusal(from result: RunResult) -> String {
        let lines = result.combined
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        if let refused = lines.first(where: { $0.lowercased().contains("refused") }) {
            return refused
        }
        return lines.last ?? "trace command failed (exit \(result.code))"
    }
}

/// The trace's UI contract.  It is available whenever the app is armed: the payload on `main`
/// parses the key, and an older payload is detected by asking for the ring (an empty answer is
/// `.unavailable`), not by a compile-time gate that would disable the toggle for everyone.
public enum PoseTrace {
    /// How many records the table renders.  The ring holds ~143 records for one hover sweep;
    /// enough to see the decision that went wrong, few enough to stay a popover.
    public static let maxRows = 40

    public static func canEnable(armed: Bool) -> Bool { armed }

    /// The field legend from `docs/TECHNICAL.md`.  Kept here as well as in the docs because the
    /// table is unreadable without it and the popover must not depend on the user finding a file.
    public static let legend = """
    Legend: seq record number · w window id · m0 submitted scale · m4 matrix[4] · x,y translation · \
    b0 stored base scale (-1 none) · rw drawn rail width (-1 not a rail tile) · o drawn · \
    u the keeper's own write · b has base · T teach-legal · r retract · a not in rail_now · \
    c candidate held · h hold ms left · q candidate ticks · sm applied scale
    """
}
