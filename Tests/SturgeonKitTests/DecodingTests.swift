import Foundation
import XCTest
@testable import SturgeonKit

final class DecodingTests: XCTestCase {
    // A fixture shaped exactly like `install.py status --json` while armed. Kept as text so the
    // test pins the document the tool actually writes, not a hand-built Swift value.
    private let armedStatus = """
    {
     "build": "991",
     "caps": {
      "births": true,
      "dilate": false,
      "level_manual": 3,
      "levels": true,
      "move": "ready",
      "replay": true,
      "s": 1.3
     },
     "daemon": {
      "loaded": true,
      "pids": ["4123"],
      "state": "armed",
      "wm_pid": 812
     },
     "debugger": null,
     "helper": ["4188"],
     "pid": 812,
     "reason": null,
     "sites_bad": [],
     "sites_patched": 6,
     "sites_total": 6,
     "state": "ARMED"
    }
    """

    private let disarmedStatus = """
    {
     "build": null,
     "caps": {},
     "daemon": {"loaded": false, "pids": []},
     "debugger": null,
     "helper": [],
     "pid": null,
     "reason": "not installed",
     "sites_patched": 0,
     "sites_total": 6,
     "state": "DISARMED"
    }
    """

    // MARK: - status

    func testArmedStatusDecodes() throws {
        let report = try XCTUnwrap(RunResult(out: armedStatus).decode(StatusReport.self))
        XCTAssertTrue(report.isArmed)
        XCTAssertEqual(report.build, "991")
        XCTAssertEqual(report.pid, 812)
        XCTAssertEqual(report.sitesPatched, 6)
        XCTAssertEqual(report.sitesTotal, 6)
        XCTAssertNil(report.debugger)
        XCTAssertEqual(report.helper, ["4188"])
        XCTAssertTrue(report.daemon.loaded)
        XCTAssertEqual(report.daemon.pids, ["4123"])

        let caps = try XCTUnwrap(report.caps)
        XCTAssertTrue(caps.births)
        XCTAssertTrue(caps.replay)
        XCTAssertTrue(caps.levels)
        XCTAssertEqual(caps.levelManual, 3)
        XCTAssertEqual(caps.scale, 1.3)
        XCTAssertEqual(caps.move, "ready")
    }

    func testDisarmedStatusKeepsItsDefaults() throws {
        let report = try XCTUnwrap(RunResult(out: disarmedStatus).decode(StatusReport.self))
        XCTAssertFalse(report.isArmed)
        XCTAssertNil(report.build)
        XCTAssertNil(report.pid)
        XCTAssertEqual(report.reason, "not installed")
        XCTAssertEqual(report.sitesPatched, 0)
        XCTAssertEqual(report.sitesTotal, 6)
        XCTAssertEqual(report.helper, [])
        XCTAssertFalse(report.daemon.loaded)

        // `caps: {}` is present, so the model zeroes the toggles but must leave the slider alone.
        let caps = try XCTUnwrap(report.caps)
        XCTAssertFalse(caps.births)
        XCTAssertFalse(caps.replay)
        XCTAssertFalse(caps.levels)
        XCTAssertEqual(caps.levelManual, 0)
        XCTAssertNil(caps.scale)
    }

    func testAbsentCapsDecodeToNil() throws {
        let report = try XCTUnwrap(RunResult(out: #"{"state":"DISARMED"}"#).decode(StatusReport.self))
        XCTAssertNil(report.caps)
        XCTAssertEqual(report.sitesTotal, 6)
        XCTAssertEqual(report.debugger, nil)
    }

    // MARK: - config

    private let configFixture = #"{"births":false,"replay":false,"levels":false,"level_manual":0,"s":1.0,"qx":16.0,"qy":490.0,"gen":1,"dilate":false}"#

    func testConfigReadsAndEncodesAsTheCliDoes() throws {
        let config = try XCTUnwrap(PayloadConfig(json: configFixture))
        XCTAssertFalse(config.births)
        XCTAssertFalse(config.onTop)
        XCTAssertFalse(config.level3)
        XCTAssertEqual(config.levelManual, 0)
        XCTAssertEqual(config.scale, 1.0)

        // A write is a read, a merge and a sorted-key encode; unknown keys survive verbatim.
        XCTAssertEqual(config.applying(.births(true)).encoded(),
                       #"{"births":true,"dilate":false,"gen":1,"level_manual":0,"levels":false,"qx":16,"qy":490,"replay":false,"s":1}"#)
        XCTAssertEqual(config.applying(.onTop(true)).encoded(),
                       #"{"births":false,"dilate":false,"gen":1,"level_manual":0,"levels":true,"qx":16,"qy":490,"replay":true,"s":1}"#)
        XCTAssertEqual(config.applying(.level(true)).encoded(),
                       #"{"births":false,"dilate":false,"gen":1,"level_manual":3,"levels":false,"qx":16,"qy":490,"replay":false,"s":1}"#)
    }

    func testConfigToggleSemantics() throws {
        var config = try XCTUnwrap(PayloadConfig(json: configFixture))
        config.apply(.onTop(true))
        XCTAssertTrue(config.replay)
        XCTAssertTrue(config.levels)
        XCTAssertTrue(config.onTop)

        config.apply(.level(true))
        XCTAssertEqual(config.levelManual, 3)
        XCTAssertTrue(config.level3)
        config.apply(.level(false))
        XCTAssertEqual(config.levelManual, 0)
        XCTAssertFalse(config.level3)
    }

    func testConfigBriefIsStable() throws {
        let config = try XCTUnwrap(PayloadConfig(json: configFixture))
        XCTAssertEqual(config.brief, "births=false replay=false levels=false level_manual=0 s=1.00")
        XCTAssertEqual(PayloadConfig().brief, "births=? replay=? levels=? level_manual=? s=?")
    }

    func testConfigRejectsNonObjects() {
        XCTAssertNil(PayloadConfig(json: "[1,2,3]"))
        XCTAssertNil(PayloadConfig(json: "not json"))
    }

    // MARK: - doctor

    func testDoctorRefusalDecodes() throws {
        let text = """
        {"ok": false, "build": "991", "text_sha256": "abc",
         "checks": [{"check": "site.births", "ok": false, "detail": "bl not found"},
                    {"check": "site.move", "ok": true, "detail": null}],
         "refusals": ["site births unresolved"]}
        """
        let report = try XCTUnwrap(RunResult(out: text).decode(DoctorReport.self))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.build, "991")
        XCTAssertEqual(report.checks.count, 2)
        XCTAssertEqual(report.failedChecks.map(\.check), ["site.births"])
        XCTAssertEqual(report.failedChecks.first?.detail, "bl not found")
        XCTAssertEqual(report.refusals, ["site births unresolved"])
    }

    func testDoctorArmedPassRecognisesItsOwnPatchChecks() throws {
        let text = """
        {"ok": false, "build": "991",
         "checks": [{"check": "site.births.file-eq-live", "ok": false, "detail": ""},
                    {"check": "site.move.keeper-prologue", "ok": false, "detail": ""}],
         "refusals": []}
        """
        let report = try XCTUnwrap(RunResult(out: text).decode(DoctorReport.self))
        XCTAssertFalse(report.ok)
        XCTAssertTrue(report.failedChecks.allSatisfy {
            $0.check.hasSuffix(".file-eq-live") || $0.check.hasSuffix(".keeper-prologue")
        })
    }

    // MARK: - resize / move

    func testResizeReportDecodes() throws {
        let text = """
        {"s": 1.3, "gen": 7, "tries": 1, "ok": true,
         "tiles": [{"ratio": 1.30, "wid": 59}, {"ratio": 1.31, "wid": 57}]}
        """
        let report = try XCTUnwrap(RunResult(out: text).decode(ResizeReport.self))
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.tiles.count, 2)
        XCTAssertEqual(report.ratios, [1.30, 1.31])
    }

    func testMoveReportDecodes() throws {
        let text = #"{"ok": true, "target": "Granola", "cgid": 4021}"#
        let report = try XCTUnwrap(RunResult(out: text).decode(MoveReport.self))
        XCTAssertTrue(report.ok)
        XCTAssertEqual(report.cgid, 4021)
        XCTAssertNil(report.err)
    }

    // MARK: - the last-object heuristic

    func testDecodingFindsTheLastJSONObjectAfterAPreambleLine() throws {
        let result = RunResult(out: "resolving sites…\n{\"ok\": false, \"err\": \"no such stage\"}")
        let report = try XCTUnwrap(result.decode(MoveReport.self))
        XCTAssertFalse(report.ok)
        XCTAssertEqual(report.err, "no such stage")
    }

    func testNonJSONOutputDecodesToNil() {
        XCTAssertNil(RunResult(out: "usage: wmship.sh").decode(StatusReport.self))
        XCTAssertNil(RunResult(out: "").decode(StatusReport.self))
    }

    // MARK: - stages

    func testStagepilotOutputParses() {
        let text = """
        [0] 'Granola' frame=(0, 0, 1512, 945) windows=[59, 57, 434]
        [1] '' frame=(1512, 0, 1512, 945) windows=[]
        stale line without a bracket
        """
        let stages = StageItem.parse(text)
        XCTAssertEqual(stages.map(\.id), [0, 1])
        XCTAssertEqual(stages[0].title, "Granola")
        XCTAssertEqual(stages[0].windows, [59, 57, 434])
        XCTAssertEqual(stages[0].label, "Granola")
        XCTAssertTrue(stages[0].addressable)
        XCTAssertEqual(stages[1].label, "Untitled stage 2")
        XCTAssertFalse(stages[1].addressable)
        XCTAssertEqual(stages[1].windows, [])
    }
}
