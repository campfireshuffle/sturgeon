import CoreGraphics
import XCTest
@testable import SturgeonKit

/// Drop hit-testing is the part that must be provably conservative: a point in one tile moves,
/// a point in the empty gutter keeps the native behaviour, and overlapping frames do nothing.
final class DropTests: XCTestCase {
    private let strip = CGRect(x: 0, y: 0, width: 286.92, height: 945)

    private func stage(_ index: Int, _ title: String, _ frame: CGRect?) -> StageItem {
        StageItem(id: index, title: title, frame: frame)
    }

    // MARK: - point in frame

    func testPointInSingleTileMoves() {
        let tile = stage(0, "Granola", CGRect(x: 16, y: 60, width: 220, height: 120))
        let decision = DropHitTest.resolve(point: CGPoint(x: 100, y: 100), strip: strip, tiles: [tile])
        XCTAssertEqual(decision, .move(tile))
        XCTAssertTrue(decision.shouldMove)
        XCTAssertEqual(decision.tile, tile)
    }

    func testPointOnTileEdgeIsInsideButBeyondItIsNot() {
        let tile = stage(0, "Granola", CGRect(x: 16, y: 60, width: 220, height: 120))
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 16, y: 60), strip: strip, tiles: [tile]),
                       .move(tile))
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 236, y: 60), strip: strip, tiles: [tile]),
                       .emptyGutter)
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 16, y: 180), strip: strip, tiles: [tile]),
                       .emptyGutter)
    }

    func testPointInTileWithoutAFrameIsNotAHit() {
        let tile = stage(0, "Granola", nil)
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 100, y: 100), strip: strip, tiles: [tile]),
                       .emptyGutter)
    }

    // MARK: - overlapping frames

    func testOverlappingTilesAreAmbiguousAndNeverMove() {
        let a = stage(0, "Granola", CGRect(x: 16, y: 60, width: 220, height: 140))
        let b = stage(1, "Safari", CGRect(x: 30, y: 120, width: 220, height: 140))
        let decision = DropHitTest.resolve(point: CGPoint(x: 100, y: 130), strip: strip, tiles: [a, b])
        XCTAssertEqual(decision, .ambiguous([a, b]))
        XCTAssertTrue(decision.isAmbiguous)
        XCTAssertFalse(decision.shouldMove)
        XCTAssertNil(decision.tile)
    }

    func testOnlyTheTileUnderThePointCounts() {
        let a = stage(0, "Granola", CGRect(x: 16, y: 60, width: 220, height: 100))
        let b = stage(1, "Safari", CGRect(x: 16, y: 200, width: 220, height: 100))
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 100, y: 250), strip: strip, tiles: [a, b]),
                       .move(b))
    }

    // MARK: - the gutter

    func testEmptyGutterIsNativeBehaviour() {
        let decision = DropHitTest.resolve(point: CGPoint(x: 100, y: 600), strip: strip, tiles: [])
        XCTAssertEqual(decision, .emptyGutter)
        XCTAssertFalse(decision.shouldMove)
        XCTAssertFalse(decision.isAmbiguous)
    }

    func testOutsideTheStripIsIgnored() {
        let tile = stage(0, "Granola", CGRect(x: 600, y: 60, width: 220, height: 120))
        let decision = DropHitTest.resolve(point: CGPoint(x: 700, y: 100), strip: strip, tiles: [tile])
        XCTAssertEqual(decision, .ignore,
                       "a drop outside the strip belongs to the native drag gesture")
        XCTAssertFalse(decision.shouldMove)
    }

    func testUnknownStripGeometryDoesNothing() {
        let tile = stage(0, "Granola", CGRect(x: 16, y: 60, width: 220, height: 120))
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 100, y: 100), strip: nil, tiles: [tile]),
                       .ignore)
        XCTAssertEqual(DropHitTest.resolve(point: CGPoint(x: 100, y: 100),
                                           strip: CGRect(x: 0, y: 0, width: 0, height: 0),
                                           tiles: [tile]),
                       .ignore)
    }

    // MARK: - the listing the hit-test reads

    func testStagesListingCarriesTileFramesAndTheStripRect() {
        let text = """
        [0] 'Granola' frame=(16.0, 60.0, 220.0, 118.0) windows=[59, 57]
        [1] 'Safari' frame=(16.0, 190.0, 220.0, 118.0) windows=[57]
        strip=Optional((0.0, 0.0, 286.92, 945.0))
        """
        let snapshot = StageSnapshot.parse(text)
        XCTAssertEqual(snapshot.stages.count, 2)
        XCTAssertEqual(snapshot.stages[0].frame, CGRect(x: 16, y: 60, width: 220, height: 118))
        XCTAssertEqual(snapshot.stages[1].windows, [57])
        XCTAssertEqual(snapshot.strip, CGRect(x: 0, y: 0, width: 286.92, height: 945))
    }

    func testCollapsedStripLineParsesToNil() {
        let snapshot = StageSnapshot.parse("strip=nil")
        XCTAssertNil(snapshot.strip)
        XCTAssertEqual(snapshot.stages, [])
    }

    // MARK: - the command

    func testMoveWindowCommandAddressesTheDraggedWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturgeon-drop-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("wmship.sh")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: launcher)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        let toolchain = Toolchain(paths: Paths(root: root, layout: .checkout,
                                               executable: root.appendingPathComponent("Sturgeon")))

        let call = try toolchain.invocation(for: .moveWindow(stage: "Granola", cgid: 4021))
        XCTAssertEqual(call.executable.path, launcher.path)
        XCTAssertEqual(call.arguments, ["move", "Granola", "--cgid", "4021"])
        XCTAssertEqual(call.timeout, 180)

        let plain = try toolchain.invocation(for: .move(stage: "Granola"))
        XCTAssertEqual(plain.arguments, ["move", "Granola"])
    }

    // MARK: - the counters command

    func testCountersUsesTheHelperVerbNotTheLegacyPassthrough() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturgeon-counters-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        let asroot = root.appendingPathComponent("bin/asroot")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: asroot)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: asroot.path)

        let toolchain = Toolchain(paths: Paths(root: root, layout: .checkout,
                                               executable: root.appendingPathComponent("Sturgeon")))
        let call = try toolchain.invocation(for: .counters)
        XCTAssertEqual(call.executable.path, "/usr/bin/sudo")
        // The helper is a verb dispatcher after #24: the only accepted forms are a verb or the
        // three named legacy shapes, and `install.py counters` was never one of the three.
        XCTAssertEqual(call.arguments, ["-n", asroot.path, "counters"])
        XCTAssertFalse(call.arguments.contains("-c"))
        XCTAssertFalse(call.arguments.contains(where: { $0.contains("install.py") }))
        XCTAssertEqual(call.timeout, 40)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    }
}
