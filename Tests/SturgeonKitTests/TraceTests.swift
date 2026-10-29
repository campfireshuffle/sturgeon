import Foundation
import XCTest
@testable import SturgeonKit

/// The trace parser is read against lines shaped exactly like `payload.c`'s `trace_one()` and
/// `ctl.py`'s documented format.  These tests need no root, no task port and no WindowManager.
final class TraceTests: XCTestCase {
    /// One complete keeper decision: 143rd record, base present, teach-illegal, a candidate held.
    private let record =
        "143 w=9812 m0=1.0300 m4=0.0000 x=-27.5 y=512.0 b0=1.0000 rw=156.0 "
        + "o=1 u=0 b=1 T=0 r=0 a=0 c=1 h=0 q=8 sm=1.030"

    private func line(seq: Int) -> String {
        record.replacingOccurrences(of: "143 w=", with: "\(seq) w=")
    }

    // MARK: - one record

    func testRecordDecodesIntoATypedRow() throws {
        let row = try XCTUnwrap(TraceRecord(line: record))
        XCTAssertEqual(row.seq, 143)
        XCTAssertEqual(row.wid, 9812)
        XCTAssertEqual(row.m0, 1.03, accuracy: 1e-9)
        XCTAssertEqual(row.m4, 0)
        XCTAssertEqual(row.x, -27.5)
        XCTAssertEqual(row.y, 512)
        XCTAssertEqual(row.base0, 1.0)
        XCTAssertEqual(row.railWidth, 156)
        XCTAssertTrue(row.drawn)
        XCTAssertFalse(row.ours)
        XCTAssertTrue(row.hasBase)
        XCTAssertFalse(row.teachLegal)
        XCTAssertFalse(row.retract)
        XCTAssertFalse(row.notInRailNow)
        XCTAssertTrue(row.candidateHeld)
        XCTAssertEqual(row.holdMs, 0)
        XCTAssertEqual(row.candidateTicks, 8)
        XCTAssertEqual(row.scale, 1.03, accuracy: 1e-9)
        XCTAssertEqual(row.raw, record)
    }

    func testUnknownFieldsAreIgnoredRatherThanRejectingTheRecord() throws {
        let future = record + " zz=9 future=hello retina=1"
        let row = try XCTUnwrap(TraceRecord(line: future))
        XCTAssertEqual(row.seq, 143)
        XCTAssertEqual(row.wid, 9812)
        XCTAssertEqual(row.raw, future)
    }

    func testSentinelMinusOneBecomesNoBaseAndNoRailWidth() throws {
        let unknown = "7 w=1 m0=1.0000 m4=0.0000 x=1.0 y=2.0 b0=-1.0000 rw=-1.0 "
            + "o=0 u=1 b=0 T=1 r=1 a=1 c=0 h=250 q=0 sm=1.000"
        let row = try XCTUnwrap(TraceRecord(line: unknown))
        XCTAssertNil(row.base0)
        XCTAssertNil(row.railWidth)
        XCTAssertFalse(row.drawn)
        XCTAssertTrue(row.ours)
        XCTAssertTrue(row.teachLegal)
        XCTAssertTrue(row.retract)
        XCTAssertTrue(row.notInRailNow)
        XCTAssertEqual(row.holdMs, 250)
    }

    func testIncompleteOrUnnumberedLinesAreNotRecords() {
        XCTAssertNil(TraceRecord(line: ""))
        XCTAssertNil(TraceRecord(line: "trace reads the keeper ring"))
        XCTAssertNil(TraceRecord(line: "w=1 m0=1.0"))
        // A known field is missing: the line cannot be rendered as a complete row.
        XCTAssertNil(TraceRecord(line: "1 w=1 m0=1.0000 m4=0.0000 x=0.0 y=0.0 b0=-1.0000"))
    }

    // MARK: - a read

    func testReadSortsAndReturnsTheTailWithTheTotal() throws {
        let out = [line(seq: 3), line(seq: 1), line(seq: 5), line(seq: 2), line(seq: 4)]
            .joined(separator: "\n")
        let read = TraceRead(result: RunResult(code: 0, out: out), limit: 2)
        XCTAssertEqual(read.rows.map(\.seq), [4, 5], "the table shows the newest records, in order")
        XCTAssertEqual(read.total, 5)
        XCTAssertNil(read.note)
        XCTAssertFalse(read.isFailure)
        XCTAssertFalse(read.isUnavailable)
    }

    func testReadAcceptsWarningsAroundRecords() throws {
        let out = "wmship: reading the ring\n" + line(seq: 9) + "\nsome trailing note\n"
        let read = TraceRead(result: RunResult(code: 0, out: out))
        XCTAssertEqual(read.rows.map(\.seq), [9])
    }

    func testEmptyRingIsUnavailableNotAnEmptyTable() {
        // An older payload that does not parse `trace` answers nothing and exits 0.  That is
        // "unavailable", not "no decisions": the distinction is what stops the UI lying.
        let read = TraceRead(result: RunResult(code: 0, out: ""))
        XCTAssertTrue(read.isUnavailable)
        XCTAssertFalse(read.isFailure)
        XCTAssertTrue(read.rows.isEmpty)
        XCTAssertEqual(read.note?.contains("no trace ring"), true)
        XCTAssertTrue(read.note?.contains("older image") == true)
    }

    func testWhitespaceAndGarbageWithNoRecordsIsStillUnavailable() {
        let read = TraceRead(result: RunResult(code: 0, out: "  \n\n"))
        XCTAssertTrue(read.isUnavailable)
        XCTAssertTrue(read.rows.isEmpty)
    }

    func testReadFailureSurfacesTheRefusalLine() {
        let result = RunResult(code: 1,
                               out: "",
                               err: "wmship: no root — '/tmp/x/bin/asroot' is not NOPASSWD\n"
                                   + "asroot: refused: unknown verb trace")
        let read = TraceRead(result: result)
        XCTAssertTrue(read.isFailure)
        XCTAssertFalse(read.isUnavailable)
        XCTAssertTrue(read.rows.isEmpty)
        XCTAssertEqual(read.note, "asroot: refused: unknown verb trace")
    }

    func testReadFailureWithoutTheWordRefusedKeepsTheLastLine() {
        let read = TraceRead(result: RunResult(code: 2, out: "", err: "WindowManager not running"))
        XCTAssertEqual(read.note, "WindowManager not running")
    }

    func testTimedOutReadIsAFailure() {
        let read = TraceRead(result: RunResult(code: -1, timedOut: true))
        XCTAssertTrue(read.isFailure)
        XCTAssertEqual(read.note, "trace read timed out")
    }
}
