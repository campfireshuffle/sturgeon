import Foundation
import XCTest
@testable import SturgeonKit

/// Pins the exact argv for every control. The tool tree is a throwaway directory, so these tests
/// need no WindowManager, no root and no checkout layout.
final class CommandTests: XCTestCase {
    private var root: URL!
    private var paths: Paths!
    private var toolchain: Toolchain!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturgeon-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wmship"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a"),
                                                withIntermediateDirectories: true)
        for relative in ["wmship.sh", "bin/asroot", "a/stagepilot"] {
            let url = root.appendingPathComponent(relative)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try Data("#!/usr/bin/python3\n".utf8).write(to: root.appendingPathComponent("wmship/install.py"))

        paths = Paths(root: root, layout: .checkout,
                      executable: root.appendingPathComponent("Sturgeon"))
        toolchain = Toolchain(paths: paths)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.root) }
    }

    private func invocation(_ command: SturgeonCommand) throws -> Invocation {
        try toolchain.invocation(for: command)
    }

    private func json(_ change: ConfigChange, from fixture: String =
        #"{"births":false,"replay":false,"levels":false,"level_manual":0,"s":1.0,"qx":16.0,"qy":490.0,"gen":1,"dilate":false}"#) throws -> String {
        let config = try XCTUnwrap(PayloadConfig(json: fixture))
        return try XCTUnwrap(config.applying(change).encoded())
    }

    private var installPy: String { Paths.quote(root.appendingPathComponent("wmship/install.py").path) }
    private var asroot: String { root.appendingPathComponent("bin/asroot").path }

    // MARK: - privileged commands

    func testStatusRunsInstallPyThroughTheAsrootPassthrough() throws {
        let call = try invocation(.status)
        XCTAssertEqual(call.executable.path, "/usr/bin/sudo")
        XCTAssertEqual(call.arguments,
                       ["-n", asroot, "-c", "/usr/bin/python3 \(installPy) status --json"])
        XCTAssertEqual(call.timeout, 40)
    }

    func testBirthsWritesOneConfigKey() throws {
        let payload = try json(.births(true))
        XCTAssertEqual(payload,
                       #"{"births":true,"dilate":false,"gen":1,"level_manual":0,"levels":false,"qx":16,"qy":490,"replay":false,"s":1}"#)

        let call = try invocation(.configWrite(json: payload))
        XCTAssertEqual(call.executable.path, "/usr/bin/sudo")
        XCTAssertEqual(call.arguments,
                       ["-n", asroot, "-c",
                        "/usr/bin/python3 \(installPy) cfg \(Paths.quote(payload))"])
        XCTAssertEqual(call.timeout, 40)
    }

    func testOnTopWritesBothReplayAndLevels() throws {
        let payload = try json(.onTop(true))
        XCTAssertEqual(payload,
                       #"{"births":false,"dilate":false,"gen":1,"level_manual":0,"levels":true,"qx":16,"qy":490,"replay":true,"s":1}"#)

        let call = try invocation(.configWrite(json: payload))
        XCTAssertEqual(call.arguments[3],
                       "/usr/bin/python3 \(installPy) cfg \(Paths.quote(payload))")
    }

    func testLevelWritesLevelManualThree() throws {
        let payload = try json(.level(true))
        XCTAssertEqual(payload,
                       #"{"births":false,"dilate":false,"gen":1,"level_manual":3,"levels":false,"qx":16,"qy":490,"replay":false,"s":1}"#)

        let call = try invocation(.configWrite(json: payload))
        XCTAssertEqual(call.arguments[3],
                       "/usr/bin/python3 \(installPy) cfg \(Paths.quote(payload))")
    }

    func testRootProbeIsTheSingleBareTrue() throws {
        let call = try invocation(.rootProbe)
        XCTAssertEqual(call.executable.path, "/usr/bin/sudo")
        XCTAssertEqual(call.arguments, ["-n", asroot, "-c", "true"])
        XCTAssertEqual(call.timeout, 20)
    }

    // MARK: - unprivileged commands

    func testResizeBuildsTwoDecimals() throws {
        let wide = try invocation(.resize(scale: 1.3))
        XCTAssertEqual(wide.executable.path, root.appendingPathComponent("wmship.sh").path)
        XCTAssertEqual(wide.arguments, ["resize", "1.30"])
        XCTAssertEqual(wide.timeout, 180)

        let narrow = try invocation(.resize(scale: 0.6))
        XCTAssertEqual(narrow.arguments, ["resize", "0.60"])

        let reset = try invocation(.resize(scale: 1.0))
        XCTAssertEqual(reset.arguments, ["resize", "1.00"])
    }

    func testMovePassesTheStageTitleVerbatim() throws {
        let call = try invocation(.move(stage: "Granola's stage"))
        XCTAssertEqual(call.executable.path, root.appendingPathComponent("wmship.sh").path)
        XCTAssertEqual(call.arguments, ["move", "Granola's stage"])
        XCTAssertEqual(call.timeout, 180)
    }

    func testDoctorConfigReadStartStop() throws {
        XCTAssertEqual(try invocation(.doctor).arguments, ["doctor", "--json"])
        XCTAssertEqual(try invocation(.doctor).timeout, 240)
        XCTAssertEqual(try invocation(.configRead).arguments, ["cfg"])
        XCTAssertEqual(try invocation(.configRead).timeout, 40)
        XCTAssertEqual(try invocation(.start).arguments, ["start"])
        XCTAssertEqual(try invocation(.start).timeout, 300)
        XCTAssertEqual(try invocation(.stop).arguments, ["stop"])
        XCTAssertEqual(try invocation(.stop).timeout, 240)
    }

    func testStagesRunsTheStagepilot() throws {
        let call = try invocation(.stages)
        XCTAssertEqual(call.executable.path, root.appendingPathComponent("a/stagepilot").path)
        XCTAssertEqual(call.arguments, ["stages"])
        XCTAssertEqual(call.timeout, 20)
    }

    // MARK: - an incomplete tree

    func testMissingAsrootRefusesInsteadOfGuessingAPath() throws {
        let empty = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let toolchain = Toolchain(paths: Paths(root: empty, layout: .checkout,
                                              executable: empty.appendingPathComponent("Sturgeon")))
        XCTAssertThrowsError(try toolchain.invocation(for: .status)) { error in
            XCTAssertEqual("\(error)", "bundle incomplete: asroot missing")
        }
    }
}
