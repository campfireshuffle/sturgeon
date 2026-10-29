import Foundation
import XCTest
@testable import SturgeonKit

/// Issue #5's app half: decode the `selfcheck` document and gate the size slider on it.
///
/// The fixtures are the document `ctl.py selfcheck` writes (indented, plus a few keys the app
/// does not read), so the tolerance and the `want` field are pinned against the real shape.
/// Nothing here runs a process or needs a WindowManager.
final class PreflightTests: XCTestCase {
    // A pass: the probe applied 1.2 with teaching off, every tile read 1.2, and the strip was
    // restored to 1.0.  `secs` and `gen` are fields the app deliberately ignores.
    private let passJSON = """
    {
     "ok": true,
     "s": 1.0,
     "probe_s": 1.2,
     "tol": 0.02,
     "tiles": [
      {"id": 59, "owner": "Finder", "w": 144, "natural": 120, "ratio": 1.2, "want": 1.2},
      {"id": 57, "owner": "Safari", "w": 156, "natural": 130, "ratio": 1.201, "want": 1.2}
     ],
     "restored": [
      {"id": 59, "owner": "Finder", "w": 120, "natural": 120, "ratio": 1.0, "want": 1.0},
      {"id": 57, "owner": "Safari", "w": 130, "natural": 130, "ratio": 1.0, "want": 1.0}
     ],
     "err": null,
     "secs": 4.21,
     "gen": 12
    }
    """

    // A doctored base: the tool's own refusal, one row out at 1.258.
    private let failJSON = """
    {
     "ok": false,
     "s": 1.0,
     "probe_s": 1.2,
     "tol": 0.02,
     "tiles": [
      {"id": 59, "owner": "Finder", "w": 151, "natural": 120, "ratio": 1.258, "want": 1.2}
     ],
     "restored": [
      {"id": 59, "owner": "Finder", "w": 120, "natural": 120, "ratio": 1.0, "want": 1.0}
     ],
     "err": "tile 59 measures 1.258 x natural at probe 1.20, want 1.20 ± 0.02 (1 of 1 off)",
     "secs": 4.0
    }
    """

    private func report(_ json: String) throws -> SelfcheckReport {
        try XCTUnwrap(RunResult(out: json).decode(SelfcheckReport.self))
    }

    // MARK: - decoding

    func testPassDecodesEveryProbeField() throws {
        let report = try report(passJSON)
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.scale, 1.0)
        XCTAssertEqual(report.probeScale, 1.2)
        XCTAssertEqual(report.tolerance, 0.02)
        XCTAssertEqual(report.seconds, 4.21)
        XCTAssertNil(report.err)
        XCTAssertEqual(report.tiles.map(\.id), [59, 57])
        XCTAssertEqual(report.tiles.first?.owner, "Finder")
        XCTAssertEqual(report.tiles.first?.width, 144)
        XCTAssertEqual(report.tiles.first?.natural, 120)
        XCTAssertEqual(report.tiles.first?.want, 1.2)
        XCTAssertEqual(report.restored.map(\.ratio), [1.0, 1.0])
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.offendingTiles.count, 0)
    }

    func testFailureDecodesAndKeepsTheToolReason() throws {
        let report = try report(failJSON)
        XCTAssertFalse(report.ok)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.tiles.count, 1)
        XCTAssertEqual(report.offendingTiles.map(\.id), [59])
        XCTAssertEqual(report.refusalLine(), report.err)
        XCTAssertTrue(report.refusalLine().contains("tile 59"))
    }

    /// An older or trimmed document can fail without an `err`; the first out-of-tolerance row is
    /// then the line the popover shows.
    func testOffendingTileIsTheReasonWhenTheToolWroteNoErr() throws {
        let text = """
        {"ok": false, "probe_s": 1.2, "tol": 0.02, "err": null,
         "tiles": [{"id": 59, "natural": 120, "w": 151, "ratio": 1.258, "want": 1.2},
                   {"id": 57, "natural": 130, "w": 156, "ratio": 1.2, "want": 1.2}]}
        """
        let report = try report(text)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.offendingTiles.map(\.id), [59])
        XCTAssertEqual(report.refusalLine(),
                       "tile 59 measures 1.258 × natural at probe 1.20, want 1.20 ± 0.02")
    }

    func testMissingNaturalWidthFailureIsTheNoTileCase() throws {
        let text = """
        {"ok": false, "s": 1.0, "probe_s": 1.2, "tol": 0.02, "tiles": [], "restored": [],
         "err": "no natural width on record for tile(s) 59 — run: wmship.sh teach", "secs": 0.1}
        """
        let report = try report(text)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.refusalLine(), report.err)
        XCTAssertTrue(report.refusalLine().contains("wmship.sh teach"))
    }

    // MARK: - never invent a pass

    func testPassWithNoMeasuredTilesIsNotAPass() throws {
        let text = #"{"ok": true, "s": 1.0, "probe_s": 1.2, "tol": 0.02, "tiles": [], "err": null}"#
        let report = try report(text)
        XCTAssertTrue(report.ok, "the document says ok…")
        XCTAssertFalse(report.passed, "…but a pass with no rows is not evidence")
        XCTAssertEqual(report.refusalLine(), "selfcheck measured no strip tiles")
    }

    func testPassWithADoctoredRowIsNotAPass() throws {
        // The tool would not write this, but a stale or hand-edited document must not enable the
        // one control that can be silently wrong.  The evidence wins over the verdict.
        let text = """
        {"ok": true, "probe_s": 1.2, "tol": 0.02, "err": null,
         "tiles": [{"id": 59, "natural": 120, "w": 151, "ratio": 1.258, "want": 1.2}]}
        """
        let report = try report(text)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.offendingTiles.count, 1)
    }

    func testPassWithAMissingRatioIsNotAPass() throws {
        let text = """
        {"ok": true, "probe_s": 1.2, "tol": 0.02, "err": null,
         "tiles": [{"id": 59, "natural": 120, "w": null, "ratio": null, "want": 1.2}]}
        """
        let report = try report(text)
        XCTAssertFalse(report.passed)
        XCTAssertFalse(report.isWithinTolerance(report.tiles[0]))
    }

    func testContradictoryOkAndErrIsNotAPass() throws {
        let text = """
        {"ok": true, "probe_s": 1.2, "tol": 0.02, "err": "strip did not return to 1.000: tile 59",
         "tiles": [{"id": 59, "natural": 120, "w": 144, "ratio": 1.2, "want": 1.2}]}
        """
        let report = try report(text)
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.refusalLine().contains("did not return"))
    }

    func testToleranceDefaultsToTwoPercentWhenTheToolOmitsIt() throws {
        let text = """
        {"ok": true, "err": null,
         "tiles": [{"id": 59, "ratio": 1.23}]}
        """
        let report = try report(text)
        XCTAssertEqual(report.effectiveTolerance, 0.02)
        // No `want` and no `probe_s`: with no target published a ratio is all the evidence there
        // is, so the row is accepted rather than invented against a guessed scale.
        XCTAssertTrue(report.passed)
    }

    func testUnknownKeysAndNullsAreTolerated() throws {
        let text = """
        {"ok": false, "s": null, "probe_s": null, "tol": null, "tiles": null, "restored": null,
         "err": "no strip tiles on screen (reveal the strip first)", "future": {"x": 1}}
        """
        let report = try report(text)
        XCTAssertNil(report.scale)
        XCTAssertNil(report.probeScale)
        XCTAssertEqual(report.tiles, [])
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.refusalLine().contains("reveal the strip"))
    }

    // MARK: - a run that never produced a document

    func testProcessFailureLinesAreHonest() {
        XCTAssertEqual(
            PreflightFailure.line(for: RunResult(code: 1, out: "",
                                                 err: "wmship: no root — '/x/bin/asroot' is not NOPASSWD")),
            "no root: press Set Up (one administrator approval)")
        XCTAssertEqual(PreflightFailure.line(for: RunResult(code: -1, timedOut: true)),
                       "selfcheck timed out before it measured the strip")
        XCTAssertEqual(PreflightFailure.line(for: RunResult(code: 0, out: "   ")),
                       "selfcheck returned no JSON")
        XCTAssertEqual(
            PreflightFailure.line(for: RunResult(code: 2, out: "resolving…\nasroot: refused: unknown verb selfcheck")),
            "asroot: refused: unknown verb selfcheck")
    }

    func testAProcessFailureBlocksTheGateWithItsLine() {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.failCheck(PreflightFailure.line(for: RunResult(code: 1, out: "no root")))
        XCTAssertEqual(gate.reason, "no root: press Set Up (one administrator approval)")
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertTrue(gate.retryOffered)
    }

    // MARK: - the gate

    func testDisarmedGateDisablesBothControls() {
        let gate = PreflightGate()
        XCTAssertEqual(gate.state, .disarmed)
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertFalse(gate.checkEnabled)
        XCTAssertNil(gate.reason)
        XCTAssertFalse(gate.retryOffered)
    }

    func testArmedGateWaitsForAVerdict() {
        let gate = PreflightGate(armed: true)
        XCTAssertEqual(gate.state, .unchecked)
        XCTAssertFalse(gate.sliderEnabled, "arming alone never enables the slider")
        XCTAssertTrue(gate.checkEnabled)
    }

    func testArmedAndSelfcheckOKEnablesTheSlider() throws {
        var gate = PreflightGate(armed: true)
        XCTAssertTrue(gate.beginCheck())
        gate.finishCheck(try report(passJSON))
        XCTAssertEqual(gate.state, .ready)
        XCTAssertTrue(gate.sliderEnabled)
        XCTAssertTrue(gate.checkEnabled)
        XCTAssertNil(gate.reason)
        XCTAssertTrue(gate.headline.hasPrefix("Resize preflight: OK"))
    }

    func testArmedAndSelfcheckFailKeepsTheSliderDisabledWithTheReason() throws {
        var gate = PreflightGate(armed: true)
        XCTAssertTrue(gate.beginCheck())
        gate.finishCheck(try report(failJSON))
        XCTAssertEqual(gate.state, .blocked(gate.reason ?? ""))
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertTrue(gate.checkEnabled, "Retry must be offered without reopening the popover")
        XCTAssertTrue(gate.retryOffered)
        XCTAssertEqual(gate.reason, try report(failJSON).refusalLine())
        XCTAssertTrue(gate.headline.contains("Resize unavailable — tile 59"))
        XCTAssertTrue(gate.lastReport?.passed == false)
    }

    func testInFlightCheckDisablesBothControls() {
        var gate = PreflightGate(armed: true)
        XCTAssertTrue(gate.beginCheck())
        XCTAssertTrue(gate.isChecking)
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertFalse(gate.checkEnabled)
        XCTAssertFalse(gate.beginCheck(), "a second selfcheck must not start")
        XCTAssertFalse(gate.beginResize(), "a resize must not start mid-probe")
    }

    func testInFlightResizeDisablesBothControls() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        XCTAssertTrue(gate.beginResize())
        XCTAssertTrue(gate.isResizing)
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertFalse(gate.checkEnabled)
        XCTAssertFalse(gate.beginCheck(), "a selfcheck must not start mid-resize")
        XCTAssertFalse(gate.beginResize(), "only one resize at a time")
        gate.endResize()
        XCTAssertTrue(gate.sliderEnabled)
        XCTAssertTrue(gate.checkEnabled)
    }

    func testAResizeIsRefusedBeforeAnyCheck() {
        var gate = PreflightGate(armed: true)
        XCTAssertFalse(gate.beginResize())
        XCTAssertFalse(gate.isResizing)
    }

    func testAFailureNeverEnablesTheSlider() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(failJSON))
        XCTAssertFalse(gate.sliderEnabled)

        // A pass arriving when no check is in flight is not a verdict for anything.
        gate.finishCheck(try report(passJSON))
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertTrue(gate.retryOffered)
        XCTAssertTrue(gate.reason?.contains("tile 59") == true)

        // Nor is a pass that arrives after a disarm.
        gate.setArmed(false)
        gate.finishCheck(try report(passJSON))
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertEqual(gate.state, .disarmed)
    }

    func testAProcessThatNeverWroteADocumentIsAFailure() {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.failCheck("sudo: a password is required")
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertEqual(gate.reason, "sudo: a password is required")

        gate.beginCheck()
        gate.failCheck("   ")
        XCTAssertEqual(gate.reason, "selfcheck did not return a verdict")
        XCTAssertFalse(gate.sliderEnabled)
    }

    func testArmingAgainInvalidatesThePreviousPass() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        XCTAssertTrue(gate.sliderEnabled)

        gate.setArmed(false)
        XCTAssertFalse(gate.sliderEnabled)
        gate.setArmed(true)
        XCTAssertEqual(gate.state, .unchecked)
        XCTAssertFalse(gate.sliderEnabled, "a new payload needs its own verdict")
    }

    func testARepeatedArmedTickDoesNotClearAPass() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        // The popover polls status every 2 s; apply(status:) re-asserts armed each time.
        for _ in 0..<5 { gate.setArmed(true) }
        XCTAssertEqual(gate.state, .ready)
        XCTAssertTrue(gate.sliderEnabled)
    }

    func testADisarmAndRearmMidProbeDropsThatProbe() {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.setArmed(false)
        XCTAssertEqual(gate.state, .disarmed)
        gate.setArmed(true)
        XCTAssertEqual(gate.state, .unchecked)
        // The process that was in flight belongs to the previous arm; its report is ignored.
        gate.finishCheck(SelfcheckReport(ok: true, tiles: [
            .init(id: 59, ratio: 1.2, want: 1.2)
        ]))
        XCTAssertEqual(gate.state, .unchecked)
        XCTAssertFalse(gate.sliderEnabled)
    }

    func testAWindowManagerChangeInvalidatesAPass() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        XCTAssertTrue(gate.sliderEnabled)

        gate.invalidate()
        XCTAssertEqual(gate.state, .unchecked)
        XCTAssertFalse(gate.sliderEnabled, "a pass for the old WindowManager is not a pass")
        XCTAssertTrue(gate.checkEnabled)
        XCTAssertFalse(gate.retryOffered, "nothing was measured, so there is no refusal to retry")

        // A probe that was running against the replaced process is dropped the same way.
        gate.beginCheck()
        gate.invalidate()
        XCTAssertEqual(gate.state, .unchecked)
        XCTAssertTrue(gate.beginCheck(), "the gate is usable again")
    }

    func testInvalidateDoesNothingWhileDisarmed() {
        var gate = PreflightGate()
        gate.invalidate()
        XCTAssertEqual(gate.state, .disarmed)
    }

    // MARK: - a gesture write in flight

    func testGestureWriteInFlightRefusesACheck() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        XCTAssertTrue(gate.checkEnabled)

        gate.setGestureInFlight(true)
        XCTAssertTrue(gate.gestureInFlight)
        XCTAssertFalse(gate.checkEnabled, "a probe must not start while the tap is writing")
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertFalse(gate.beginCheck())
        XCTAssertEqual(gate.state, .ready, "the gesture is not a verdict; it only withholds the probe")
        XCTAssertTrue(gate.headline.contains("waiting for the gesture"))
        XCTAssertEqual(gate.summary, "ready (gesture write in flight)")

        gate.setGestureInFlight(false)
        XCTAssertTrue(gate.checkEnabled)
        XCTAssertTrue(gate.sliderEnabled)
        XCTAssertTrue(gate.beginCheck())
    }

    func testGestureWriteInFlightRefusesAResize() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(passJSON))
        XCTAssertTrue(gate.sliderEnabled)

        gate.setGestureInFlight(true)
        XCTAssertFalse(gate.sliderEnabled)
        XCTAssertFalse(gate.beginResize(), "a resize must not start while the tap is writing")
        XCTAssertFalse(gate.isResizing)

        gate.setGestureInFlight(false)
        XCTAssertTrue(gate.beginResize())
        XCTAssertTrue(gate.isResizing)
        // The reverse direction still holds: a resize in flight refuses a later check.
        XCTAssertFalse(gate.checkEnabled)
        XCTAssertFalse(gate.beginCheck())
    }

    func testGestureWriteInFlightAlsoWithholdsTheFirstCheck() {
        var gate = PreflightGate(armed: true)
        XCTAssertTrue(gate.checkEnabled)
        gate.setGestureInFlight(true)
        XCTAssertFalse(gate.checkEnabled, "no probe while the tap still has a write to land")
        XCTAssertFalse(gate.beginCheck())
        XCTAssertFalse(gate.sliderEnabled)

        gate.setGestureInFlight(false)
        XCTAssertTrue(gate.beginCheck())
    }

    func testRepeatedGestureBitsDoNotInventState() throws {
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        gate.finishCheck(try report(failJSON))
        let blocked = gate.state
        gate.setGestureInFlight(true)
        gate.setGestureInFlight(true)
        XCTAssertEqual(gate.state, blocked, "the gesture bit never changes the verdict")
        XCTAssertEqual(gate.reason, try report(failJSON).refusalLine())
        gate.setGestureInFlight(false)
        XCTAssertEqual(gate.state, blocked)
        XCTAssertFalse(gate.sliderEnabled, "a failure is still a failure after the write lands")
    }

    func testDisarmClearsAStaleGestureBit() {
        var gate = PreflightGate(armed: true)
        gate.setGestureInFlight(true)
        gate.setArmed(false)
        XCTAssertFalse(gate.gestureInFlight)
        gate.setArmed(true)
        XCTAssertTrue(gate.checkEnabled, "a dropped payload cannot have a write in flight")
    }

    func testHeadlineNeverClaimsReadinessWithoutAVerdict() {        XCTAssertFalse(PreflightGate(armed: false).headline.contains("OK"))
        XCTAssertFalse(PreflightGate(armed: true).headline.contains("OK"))
        var checking = PreflightGate(armed: true)
        checking.beginCheck()
        XCTAssertFalse(checking.headline.contains("OK"))
        XCTAssertTrue(checking.headline.contains("probing"))
    }

    func testSummaryIsWhatTheDiagnosticsBlockShows() throws {
        XCTAssertEqual(PreflightGate().summary, "disarmed")
        XCTAssertEqual(PreflightGate(armed: true).summary, "unchecked")
        var gate = PreflightGate(armed: true)
        gate.beginCheck()
        XCTAssertEqual(gate.summary, "checking")
        gate.finishCheck(try report(passJSON))
        XCTAssertEqual(gate.summary, "ready")
        var failed = PreflightGate(armed: true)
        failed.beginCheck()
        failed.failCheck("no strip tiles on screen")
        XCTAssertEqual(failed.summary, "blocked — no strip tiles on screen")
    }
}
