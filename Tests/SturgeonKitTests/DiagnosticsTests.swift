import Foundation
import XCTest
@testable import SturgeonKit

/// The diagnostics block is what a bug reporter pastes.  These tests decode the documents the
/// tools actually write, run them through the formatter, and pin the two properties that matter:
/// the rows are complete, and no line names the user's home directory.
final class DiagnosticsTests: XCTestCase {
    // `install.py status --json`, armed.
    private let statusJSON = """
    {
     "build": "991",
     "caps": {"births": true, "levels": true, "level_manual": 3, "replay": true, "s": 1.3},
     "counters": {"cmp": 0, "inject": 12, "miss": 2, "rej": 0, "ret": 4},
     "daemon": {"armed": true, "loaded": true, "pids": ["4123"], "state": "armed", "wm_pid": 812},
     "debugger": null,
     "helper": ["4188"],
     "pid": 812,
     "reason": null,
     "sites_patched": 6,
     "sites_total": 6,
     "state": "ARMED"
    }
    """

    // `wmship.sh doctor --json`, refused on a personal-looking path on purpose.
    private let doctorJSON = """
    {
     "ok": false,
     "build": "991",
     "checks": [
      {"check": "site.births", "ok": true, "detail": ""},
      {"check": "profile.layout", "ok": false, "detail": "no profile for 991"}
     ],
     "refusals": ["site births unresolved; see /Users/someone/Developer/sturgeon/wmship/install.py"]
    }
    """

    // `ctl.py resize` — one tile measured against a taught natural width.
    private let resizeJSON = """
    {
     "s": 1.3, "gen": 7, "tries": 1, "ok": true,
     "tiles": [
      {"id": 59, "owner": "Finder", "w": 156, "natural": 120, "ratio": 1.3},
      {"id": 57, "owner": "Safari", "w": null, "natural": null, "ratio": null}
     ]
    }
    """

    // `install.py counters` — the keeper's full heartbeat.
    private let countersJSON = """
    {
     "hb": {"bases": 6, "raised": 0, "keep": 88, "learn": 7, "dil": 3, "replay": 24,
            "level": 0, "apply": 19, "inject": 12, "drv": 0, "cmp": 0, "miss": 2,
            "gen": 42, "gen_applied": 42, "s_milli": 1300},
     "inj_n": 12,
     "injected": [{"wid": "0x3b", "cgid": 4021}]
    }
    """

    private func snapshot(status: Bool = true, doctor: Bool = true,
                          resize: Bool = true, counters: Bool = true) throws -> DiagnosticsSnapshot {
        DiagnosticsSnapshot(
            generated: Date(timeIntervalSince1970: 1_790_000_000),
            appVersion: "1.0.0 (35)",
            bundleLayout: "bundle",
            status: status ? try XCTUnwrap(RunResult(out: statusJSON).decode(StatusReport.self)) : nil,
            doctor: doctor ? try XCTUnwrap(RunResult(out: doctorJSON).decode(DoctorReport.self)) : nil,
            counters: counters ? try XCTUnwrap(RunResult(out: countersJSON).decode(CountersReport.self)) : nil,
            resize: resize ? try XCTUnwrap(RunResult(out: resizeJSON).decode(ResizeReport.self)) : nil,
            lastError: "resize → no strip tiles",
            trace: true,
            gesture: "listening (Control + Option)",
            ambiguousDrops: 2,
            inputRearms: 1)
    }

    // MARK: - decoding

    func testCapturedDocumentsDecode() throws {
        let report = try XCTUnwrap(RunResult(out: statusJSON).decode(StatusReport.self))
        XCTAssertEqual(report.counters?["inject"], 12)
        XCTAssertEqual(report.counters?["miss"], 2)
        XCTAssertEqual(report.daemon.state, "armed")

        let doctor = try XCTUnwrap(RunResult(out: doctorJSON).decode(DoctorReport.self))
        XCTAssertEqual(doctor.failedChecks.map(\.check), ["profile.layout"])
        XCTAssertEqual(doctor.refusalLine(),
                       "site births unresolved; see /Users/someone/Developer/sturgeon/wmship/install.py")

        let resize = try XCTUnwrap(RunResult(out: resizeJSON).decode(ResizeReport.self))
        XCTAssertEqual(resize.scale, 1.3)
        XCTAssertEqual(resize.tries, 1)
        XCTAssertEqual(resize.tiles.count, 2)
        XCTAssertEqual(resize.tiles[0].id, 59)
        XCTAssertEqual(resize.tiles[0].owner, "Finder")
        XCTAssertEqual(resize.tiles[0].width, 156)
        XCTAssertEqual(resize.tiles[0].natural, 120)
        XCTAssertEqual(resize.tiles[0].ratio, 1.3)
        XCTAssertNil(resize.tiles[1].natural)
        XCTAssertNil(resize.tiles[1].ratio)

        let counters = try XCTUnwrap(RunResult(out: countersJSON).decode(CountersReport.self))
        XCTAssertEqual(counters.heartbeat["keep"], 88)
        XCTAssertEqual(counters.heartbeat["learn"], 7)
        XCTAssertEqual(counters.heartbeat["replay"], 24)
        XCTAssertEqual(counters.heartbeat["dil"], 3)
        XCTAssertEqual(counters.injectionCount, 12)
        XCTAssertEqual(counters.injections.first?.cgid, 4021)
    }

    // MARK: - the block

    func testDiagnosticsBlockRendersEverySectionAndNoPersonalPath() throws {
        let block = try snapshot().block()
        let lines = block.split(separator: "\n").map(String.init)

        XCTAssertEqual(lines.first, "Sturgeon diagnostics")
        XCTAssertTrue(lines.contains("state ARMED"))
        XCTAssertTrue(lines.contains("windowmanager build=991 pid=812 sites=6/6"))
        XCTAssertTrue(lines.contains("counters inject=12 miss=2 keep=88 learn=7 replay=24 dil=3"))
        XCTAssertTrue(lines.contains("last-resize s=1.300 ok=true tries=1 tiles=2"))
        XCTAssertTrue(lines.contains("  tile 59 owner=Finder natural=120.0 measured=156.0 ratio=1.300"))
        XCTAssertTrue(lines.contains("  tile 57 owner=Safari natural=— measured=— ratio=—"))
        XCTAssertTrue(lines.contains("ambiguous-drops 2"))
        XCTAssertTrue(lines.contains("input-rearms 1"))
        XCTAssertTrue(lines.contains("gesture listening (Control + Option)"))
        XCTAssertTrue(lines.contains("trace on (advanced)"))
        XCTAssertTrue(lines.contains(where: { $0.hasPrefix("doctor FAIL") }))

        // The doctor's refusal named a home directory; the block must not carry it.
        XCTAssertFalse(block.contains("/Users/"))
        XCTAssertFalse(block.contains("someone"))
        XCTAssertTrue(block.contains("<path>"))
    }

    func testDiagnosticsBlockRedactsTempPathsToo() {
        let text = "cache at /private/var/folders/q6/abc/T/wmship and /var/folders/zz/T/x"
        let redacted = DiagnosticsSnapshot.redact(text)
        XCTAssertEqual(redacted, "cache at <temp> and <temp>")
        XCTAssertFalse(redacted.contains("/var/folders/"))
    }

    func testDisarmedDiagnosticsRendersDashesInsteadOfInventingCounters() throws {
        let status = try XCTUnwrap(RunResult(out: """
        {"state":"DISARMED","reason":"not installed","counters":null,"build":null,"pid":null,
         "sites_patched":0,"sites_total":6,"debugger":null,"helper":[],"daemon":{"loaded":false,"pids":[]}}
        """).decode(StatusReport.self))
        let block = DiagnosticsSnapshot(status: status).block()
        XCTAssertTrue(block.contains("state DISARMED"))
        XCTAssertTrue(block.contains("state-reason not installed"))
        XCTAssertTrue(block.contains("counters inject=— miss=— keep=— learn=— replay=— dil=—"))
        XCTAssertTrue(block.contains("doctor unavailable"))
        XCTAssertTrue(block.contains("last-resize none"))
        XCTAssertFalse(block.contains("/Users/"))
    }

    func testCounterFallsBackToTheStatusDocumentWhenCountersCannotRun() throws {
        let status = try XCTUnwrap(RunResult(out: statusJSON).decode(StatusReport.self))
        let snap = DiagnosticsSnapshot(status: status, counters: nil)
        XCTAssertEqual(snap.counter("inject"), 12)
        XCTAssertEqual(snap.counter("miss"), 2)
        XCTAssertNil(snap.counter("keep"))
    }

    func testArmedStateRendersEvenWhenTheStatusDocumentCannotDecode() {
        let block = DiagnosticsSnapshot(status: nil, armed: true).block()
        XCTAssertTrue(block.contains("state ARMED (status document unavailable)"))
        XCTAssertTrue(block.contains("counters inject=— miss=— keep=— learn=— replay=— dil=—"))
    }

    // MARK: - doctor verdict

    func testArmedDoctorFailuresFromOurOwnPatchAreAPass() throws {
        let text = """
        {"ok": false, "build": "991",
         "checks": [{"check": "site.births.file-eq-live", "ok": false, "detail": ""},
                    {"check": "site.move.keeper-prologue", "ok": false, "detail": ""}],
         "refusals": []}
        """
        let report = try XCTUnwrap(RunResult(out: text).decode(DoctorReport.self))
        XCTAssertEqual(report.verdict(armed: true), .passArmed)
        XCTAssertEqual(report.verdict(armed: false), .fail)
        XCTAssertTrue(DiagnosticsSnapshot(status: nil, doctor: report).doctorVerdict == .fail)
    }

    func testDoctorRefusalLinePrefersRefusalThenFailingCheck() {
        var report = DoctorReport(ok: false)
        report.checks = [.init(check: "site.births", ok: false, detail: "bl not found")]
        XCTAssertEqual(report.refusalLine(), "site.births: bl not found")
        report.refusals = ["site births unresolved"]
        XCTAssertEqual(report.refusalLine(), "site births unresolved")
    }

    // MARK: - config

    func testTraceIsOneConfigKey() throws {
        let config = try XCTUnwrap(PayloadConfig(json: #"{"s":1.0,"trace":false}"#))
        XCTAssertFalse(config.trace)
        XCTAssertEqual(config.applying(.trace(true)).encoded(), #"{"s":1,"trace":true}"#)
        XCTAssertEqual(ConfigChange.trace(true).label, "trace=true")
    }
}
