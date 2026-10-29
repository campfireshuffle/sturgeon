import Foundation

/// The one line for a preflight run that never produced a document — no root, a missing script, a
/// timeout, or output that is not JSON.  A process failure is never a pass, and this is the text
/// the popover shows as the reason.
public enum PreflightFailure {
    public static func line(for result: RunResult) -> String {
        if result.timedOut { return "selfcheck timed out before it measured the strip" }
        if result.combined.lowercased().contains("no root") {
            return "no root: press Set Up (one administrator approval)"
        }
        let line = result.combined
            .split(separator: "\n")
            .last
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? "selfcheck returned no JSON" : line
    }
}

/// The resize preflight's gate (issue #5).
///
/// The size slider is the one control that can be silently wrong: if teaching is broken, the
/// tiles still move and the strip is simply a few percent off.  So the app runs
/// `wmship.sh selfcheck` before offering the slider, and this type is the whole decision — no
/// AppKit, no process, so every transition is testable without a WindowManager.
///
/// The rules, in one place:
///
/// * disarmed → the slider is disabled, and there is nothing to check.
/// * armed, not checked → disabled; a check may be started.
/// * checking → **both** disabled: the strip is at the probe scale, so a resize would corrupt
///   the measurement and a second check would race the first.
/// * ready → the slider is enabled.
/// * blocked → disabled with the one-line reason; only a new check (or arming again) clears it.
///
/// A resize and a check never overlap in either direction.  A pass is only ever produced by
/// `finishCheck` with a `SelfcheckReport` that itself carries the evidence (`passed`), and only
/// while a check is in flight — an unsolicited "ok" document cannot enable the slider.
public struct PreflightGate: Equatable {
    public enum State: Equatable {
        /// No payload to measure.
        case disarmed
        /// Armed, but no verdict for this armed session yet.
        case unchecked
        /// `selfcheck` is running: the strip is visibly at the probe scale.
        case checking
        /// The last check measured every tile within tolerance.
        case ready
        /// The last check refused.  The payload is why, in one line.
        case blocked(String)
    }

    public private(set) var armed: Bool
    public private(set) var state: State
    /// A resize is in flight; `checkEnabled` is false while it is.
    public private(set) var resizing: Bool
    /// The newest report, kept for the diagnostics block.  Its verdict is in `state`.
    public private(set) var lastReport: SelfcheckReport?

    public init(armed: Bool = false) {
        self.armed = armed
        self.state = armed ? .unchecked : .disarmed
        self.resizing = false
        self.lastReport = nil
    }

    // MARK: - what the UI may do

    /// The size slider (and Reset) is offered only after a check passed, and never while the
    /// probe or a resize is in flight.
    public var sliderEnabled: Bool { armed && state == .ready && !resizing }

    /// The preflight may be started, on demand or on popover open.
    public var checkEnabled: Bool { armed && state != .checking && !resizing }

    public var isChecking: Bool { state == .checking }
    public var isResizing: Bool { resizing }
    public var isReady: Bool { state == .ready }

    /// The one-line reason the slider is unavailable, when the payload gave one.
    public var reason: String? {
        if case .blocked(let why) = state { return why }
        return nil
    }

    /// A failed check is the only state that offers "Retry" and the `teach` hint.  `unchecked`
    /// offers the first check instead.
    public var retryOffered: Bool {
        if case .blocked = state { return true }
        return false
    }

    /// The line under the slider.  It never claims readiness the gate does not have.
    public var headline: String {
        switch state {
        case .disarmed:
            return "Resize preflight: needs the payload (disarmed)"
        case .unchecked:
            return "Resize preflight: not run — checking before the slider is offered"
        case .checking:
            return "Resize preflight: probing the strip — it scales briefly, then returns"
        case .ready:
            return "Resize preflight: OK — every tile measured at the probe scale"
        case .blocked(let why):
            return "Resize unavailable — \(why)"
        }
    }

    /// A compact form for the diagnostics block.
    public var summary: String {
        switch state {
        case .disarmed: return "disarmed"
        case .unchecked: return "unchecked"
        case .checking: return "checking"
        case .ready: return "ready"
        case .blocked(let why): return "blocked — \(why)"
        }
    }

    // MARK: - transitions

    /// The status document is the only source of `armed`.  A repeat tick with the same value must
    /// not clear a pass; a real arm/disarm change must, because the payload and the WindowManager
    /// were restarted and any earlier measurement describes a different process.
    public mutating func setArmed(_ value: Bool) {
        guard value != armed else {
            // A gate built before the first status document becomes unchecked once armed.
            if value && state == .disarmed { state = .unchecked }
            return
        }
        armed = value
        state = value ? .unchecked : .disarmed
        if !value { resizing = false }
    }

    /// The WindowManager process was replaced (a relaunch, or a crash and recovery).  A pass
    /// measured against the old process is not a pass for this one, so the gate goes back to
    /// unchecked — never straight to blocked, because nothing was measured.
    public mutating func invalidate() {
        guard armed else { return }
        state = .unchecked
    }

    /// Starts a check.  Returns false when one is in flight, a resize is in flight, or disarmed,
    /// so the caller cannot launch a second process.
    @discardableResult
    public mutating func beginCheck() -> Bool {
        guard checkEnabled else { return false }
        state = .checking
        return true
    }

    /// Records the tool's document.  Ignored unless a check is in flight, which is what makes a
    /// late or unsolicited report harmless, and what keeps a failure sticky.
    public mutating func finishCheck(_ report: SelfcheckReport) {
        guard state == .checking else { return }
        guard armed else { state = .disarmed; return }
        lastReport = report
        state = report.passed ? .ready : .blocked(report.refusalLine())
    }

    /// The check could not produce a document at all (no root, a missing script, a timeout).
    /// That is a failure with the process's own words, never a pass.
    public mutating func failCheck(_ reason: String) {
        guard state == .checking else { return }
        guard armed else { state = .disarmed; return }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .blocked(why.isEmpty ? "selfcheck did not return a verdict" : why)
    }

    /// Starts a resize.  Only a passed check permits one; `applyScale` uses this instead of its
    /// old private `resizing` flag so the two operations share one serialisation point.
    @discardableResult
    public mutating func beginResize() -> Bool {
        guard armed, state == .ready, !resizing else { return false }
        resizing = true
        return true
    }

    public mutating func endResize() {
        resizing = false
    }
}
