import Foundation

/// One paste-ready diagnostics block.  Everything the panel shows is assembled here from already
/// decoded reports, so the formatting is testable without a WindowManager, a payload or a popover.
///
/// The block is what a bug reporter pastes into an issue.  It must therefore never carry a path
/// containing the user's name: `block()` redacts `/Users/…` (and the volatile temp dirs) from
/// every line, including the ones that came verbatim from a tool refusal.
public struct DiagnosticsSnapshot: Equatable {
    /// The six keeper counters the panel shows, in a stable order.
    public static let counterKeys = ["inject", "miss", "keep", "learn", "replay", "dil"]

    public var generated: Date
    public var appVersion: String
    public var bundleLayout: String
    public var status: StatusReport?
    public var doctor: DoctorReport?
    public var counters: CountersReport?
    /// Why the full counter set could not be read (a helper without the `counters` verb, for
    /// example).  Shown instead of silently falling back to the five fields in `status`.
    public var countersNote: String?
    public var resize: ResizeReport?
    /// The resize preflight (issue #5): why the slider is — or is not — offered.
    public var preflight: PreflightGate?
    public var lastError: String?
    public var gesture: String
    public var ambiguousDrops: Int
    public var inputRearms: Int
    /// Whether the `trace` config key is on.  The block reports the switch state, never records
    /// the trace did not produce.
    public var traceOn: Bool
    /// How many records the ring held on the last read, or `nil` when trace is off or was never
    /// read.  The table renders the tail of these; the total is the honest number for a report.
    public var traceRecordCount: Int?
    /// Why the last read produced no table (a refusal, or an older payload with no ring).
    public var traceNote: String?
    /// The app's own armed flag, used when the status document could not be decoded at all.
    public var armedFlag: Bool?

    public init(generated: Date = Date(),
                appVersion: String = "?",
                bundleLayout: String = "?",
                status: StatusReport? = nil,
                doctor: DoctorReport? = nil,
                counters: CountersReport? = nil,
                countersNote: String? = nil,
                resize: ResizeReport? = nil,
                preflight: PreflightGate? = nil,
                lastError: String? = nil,
                gesture: String = "off",
                ambiguousDrops: Int = 0,
                inputRearms: Int = 0,
                traceOn: Bool = false,
                traceRecordCount: Int? = nil,
                traceNote: String? = nil,
                armed: Bool? = nil) {
        self.generated = generated
        self.appVersion = appVersion
        self.bundleLayout = bundleLayout
        self.status = status
        self.doctor = doctor
        self.counters = counters
        self.countersNote = countersNote
        self.resize = resize
        self.preflight = preflight
        self.lastError = lastError
        self.gesture = gesture
        self.ambiguousDrops = ambiguousDrops
        self.inputRearms = inputRearms
        self.traceOn = traceOn
        self.traceRecordCount = traceRecordCount
        self.traceNote = traceNote
        self.armedFlag = armed
    }

    // MARK: - derived rows

    public var armed: Bool { armedFlag ?? status?.isArmed ?? false }

    public var doctorVerdict: DoctorVerdict {
        guard let doctor else { return .unavailable }
        return doctor.verdict(armed: armed)
    }

    public var doctorRefusal: String? {
        guard doctorVerdict == .fail else { return nil }
        return doctor?.refusalLine()
    }

    /// `install.py counters` carries the keeper's full set; `status --json` carries only the
    /// aggregate five, so it is the fallback when the counters command could not run.
    public func counter(_ key: String) -> Int? {
        if let value = counters?.heartbeat[key] { return value }
        return status?.counters?[key]
    }

    // MARK: - formatting

    public func block() -> String {
        var lines: [String] = []
        lines.append("Sturgeon diagnostics")
        lines.append("generated \(Self.timestamp(generated))")
        lines.append("app \(appVersion) bundle=\(bundleLayout)")

        if let status {
            lines.append("state \(status.isArmed ? "ARMED" : "DISARMED")")
            lines.append("windowmanager build=\(status.build ?? "?") pid=\(status.pid.map(String.init) ?? "?") sites=\(status.sitesPatched)/\(status.sitesTotal)")
            if let reason = status.reason, !reason.isEmpty {
                lines.append("state-reason \(reason)")
            }
            if let daemon = Self.daemonLine(status.daemon) {
                lines.append("daemon \(daemon)")
            }
            if !status.helper.isEmpty {
                lines.append("helper \(status.helper.joined(separator: ","))")
            }
            lines.append("debugger \(status.debugger ?? "none")")
        } else {
            lines.append("state \(armed ? "ARMED" : "DISARMED") (status document unavailable)")
        }

        switch doctorVerdict {
        case .pass, .passArmed:
            lines.append("doctor \(doctorVerdict.label)")
        case .fail:
            lines.append("doctor FAIL — \(doctorRefusal ?? "doctor refused")")
        case .unavailable:
            lines.append("doctor unavailable")
        }

        let countersLine = Self.counterKeys.map { key -> String in
            "\(key)=\(counter(key).map(String.init) ?? "—")"
        }.joined(separator: " ")
        lines.append("counters \(countersLine)")
        if let countersNote, !countersNote.isEmpty {
            lines.append("counters-note \(countersNote)")
        }

        if let resize {
            let scale = resize.scale.map { String(format: "%.3f", $0) } ?? "?"
            let tries = resize.tries.map(String.init) ?? "?"
            var header = "last-resize s=\(scale) ok=\(resize.ok) tries=\(tries) tiles=\(resize.tiles.count)"
            if let err = resize.err, !err.isEmpty { header += " err=\(err)" }
            lines.append(header)
            for tile in resize.tiles {
                lines.append("  " + Self.tileLine(tile))
            }
        } else {
            lines.append("last-resize none")
        }

        // The preflight is what decides whether the slider is offered, so a bug report without
        // its verdict would omit the state the user is actually complaining about.
        if let preflight {
            lines.append("preflight \(preflight.summary)")
            if let report = preflight.lastReport, let probe = report.probeScale {
                lines.append("preflight-evidence probe=\(String(format: "%.2f", probe)) "
                             + "tiles=\(report.tiles.count) off=\(report.offendingTiles.count)")
            }
        } else {
            lines.append("preflight not run")
        }

        if let lastError, !lastError.isEmpty {
            lines.append("last-error \(lastError)")
        }
        lines.append("ambiguous-drops \(ambiguousDrops)")
        lines.append("input-rearms \(inputRearms)")
        lines.append("gesture \(gesture)")
        // While the key is off, say only that: an availability claim about a feature nobody
        // turned on is exactly the false affordance #25 removed.
        if traceOn {
            lines.append("trace on (advanced)")
            if let traceRecordCount {
                lines.append("trace-records \(traceRecordCount)")
            }
        } else {
            lines.append("trace off")
        }
        if traceOn, let traceNote, !traceNote.isEmpty {
            lines.append("trace-note \(traceNote)")
        }

        return Self.redact(lines.joined(separator: "\n"))
    }

    public static func tileLine(_ tile: ResizeReport.Tile) -> String {
        let id = tile.id.map(String.init) ?? "?"
        let owner = tile.owner ?? "?"
        let natural = tile.natural.map { String(format: "%.1f", $0) } ?? "—"
        let measured = tile.width.map { String(format: "%.1f", $0) } ?? "—"
        let ratio = tile.ratio.map { String(format: "%.3f", $0) } ?? "—"
        return "tile \(id) owner=\(owner) natural=\(natural) measured=\(measured) ratio=\(ratio)"
    }

    // MARK: - redaction

    /// Strip anything that names a local account: home-directory paths and the volatile temp
    /// directories.  Applied to the finished block so a tool's refusal cannot leak a path.
    public static func redact(_ text: String) -> String {
        var out = text
        let rules: [(String, String)] = [
            // The parenthesised group keeps the literal out of the shipped binary: the bundle's
            // relocation guard refuses any `/Users/` string in the executable, and this pattern
            // is only there to redact paths that arrive at runtime.
            (#"/(Users)/[^\s"'<>|,;]+"#, "<path>"),
            (#"/private/var/folders/[^\s"'<>|,;]+"#, "<temp>"),
            (#"/var/folders/[^\s"'<>|,;]+"#, "<temp>"),
        ]
        for (pattern, replacement) in rules {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            out = expression.stringByReplacingMatches(in: out, options: [], range: range,
                                                      withTemplate: replacement)
        }
        return out
    }

    private static func daemonLine(_ daemon: StatusReport.Daemon) -> String? {
        guard daemon.loaded || !daemon.pids.isEmpty || daemon.state != nil else { return nil }
        var parts = ["loaded=\(daemon.loaded)"]
        if !daemon.pids.isEmpty { parts.append("pids=\(daemon.pids.joined(separator: ","))") }
        if let state = daemon.state { parts.append("state=\(state)") }
        return parts.joined(separator: " ")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
