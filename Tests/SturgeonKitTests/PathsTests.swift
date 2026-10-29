import Foundation
import XCTest
@testable import SturgeonKit

final class PathsTests: XCTestCase {
    // MARK: - fixtures

    private func makeTemp() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sturgeon-paths-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func writeExecutable(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: - the two layouts

    func testBundleLayoutWins() throws {
        let root = try makeTemp()
        let app = root.appendingPathComponent("Sturgeon.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        try writeExecutable(resources.appendingPathComponent("wmship/wmship.sh"))
        // A checkout-shaped tree around the executable must not win over the bundle.
        try writeExecutable(root.appendingPathComponent("wmship.sh"))

        let executable = app.appendingPathComponent("Contents/MacOS/Sturgeon")
        let paths = Paths.resolve(bundleResourceURL: resources, executableURL: executable)

        XCTAssertEqual(paths?.layout, .bundle)
        XCTAssertEqual(paths?.root.path, resources.appendingPathComponent("wmship").path)
        XCTAssertEqual(paths?.wmshipScript.path,
                       resources.appendingPathComponent("wmship/wmship.sh").path)
        XCTAssertEqual(paths?.executable.path, executable.path)
    }

    func testBundleNeedsAnExecutableLauncher() throws {
        let root = try makeTemp()
        let app = root.appendingPathComponent("Sturgeon.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        // Present but not executable: the bundle is incomplete, so resolution falls through.
        try FileManager.default.createDirectory(
            at: resources.appendingPathComponent("wmship"), withIntermediateDirectories: true)
        try Data().write(to: resources.appendingPathComponent("wmship/wmship.sh"))

        let paths = Paths.resolve(bundleResourceURL: resources,
                                  executableURL: app.appendingPathComponent("Contents/MacOS/Sturgeon"))
        XCTAssertNil(paths)
    }

    func testCheckoutLayoutWalksUpFromTheExecutable() throws {
        let checkout = try makeTemp()
        try writeExecutable(checkout.appendingPathComponent("wmship.sh"))

        let executable = checkout.appendingPathComponent(".build/release/Sturgeon")
        let paths = Paths.resolve(bundleResourceURL: nil, executableURL: executable)

        XCTAssertEqual(paths?.layout, .checkout)
        XCTAssertEqual(paths?.root.path, checkout.path)
    }

    func testCheckoutLayoutAcceptsAnInstallerOnlyTree() throws {
        let checkout = try makeTemp()
        // No launcher, but the tree still carries the installer: the old resolver accepted this.
        let installer = checkout.appendingPathComponent("wmship/install.py")
        try FileManager.default.createDirectory(at: installer.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("#!/usr/bin/python3\n".utf8).write(to: installer)

        let paths = Paths.resolve(bundleResourceURL: nil,
                                  executableURL: checkout.appendingPathComponent("tools/Sturgeon"))
        XCTAssertEqual(paths?.layout, .checkout)
        XCTAssertEqual(paths?.root.path, checkout.path)
    }

    func testOverrideIsTriedBeforeTheWalk() throws {
        let elsewhere = try makeTemp()
        let override = elsewhere.appendingPathComponent("tree", isDirectory: true)
        try writeExecutable(override.appendingPathComponent("wmship.sh"))

        let executable = elsewhere.appendingPathComponent("build/Sturgeon")
        let paths = Paths.resolve(bundleResourceURL: nil,
                                  executableURL: executable,
                                  override: override.path)

        XCTAssertEqual(paths?.layout, .checkout)
        XCTAssertEqual(paths?.root.path, override.path)
    }

    func testNoTreeResolvesToNil() throws {
        let empty = try makeTemp()
        let paths = Paths.resolve(bundleResourceURL: nil,
                                  executableURL: empty.appendingPathComponent("Sturgeon"))
        XCTAssertNil(paths)
    }

    // MARK: - entries

    func testEntryResolutionPrefersTheCheckoutSpellings() throws {
        let root = try makeTemp()
        try writeExecutable(root.appendingPathComponent("bin/asroot"))
        try writeExecutable(root.appendingPathComponent("a/stagepilot"))
        let paths = Paths(root: root, layout: .checkout,
                          executable: root.appendingPathComponent("Sturgeon"))

        XCTAssertEqual(paths.asroot?.path, root.appendingPathComponent("bin/asroot").path)
        XCTAssertEqual(paths.stagepilot?.path, root.appendingPathComponent("a/stagepilot").path)
        XCTAssertEqual(paths.installPy.path, root.appendingPathComponent("wmship/install.py").path)
        XCTAssertEqual(paths.setupScript.path, root.appendingPathComponent("setup.sh").path)
    }

    func testEntryResolutionToleratesTheTopLevelSpellings() throws {
        let root = try makeTemp()
        try writeExecutable(root.appendingPathComponent("asroot"))
        try writeExecutable(root.appendingPathComponent("bin/stagepilot"))
        let paths = Paths(root: root, layout: .checkout,
                          executable: root.appendingPathComponent("Sturgeon"))

        XCTAssertEqual(paths.asroot?.path, root.appendingPathComponent("asroot").path)
        XCTAssertEqual(paths.stagepilot?.path, root.appendingPathComponent("bin/stagepilot").path)
    }

    func testMissingEntriesAreNilRatherThanInvented() throws {
        let root = try makeTemp()
        let paths = Paths(root: root, layout: .bundle,
                          executable: root.appendingPathComponent("Sturgeon"))
        XCTAssertNil(paths.asroot)
        XCTAssertNil(paths.stagepilot)
    }

    func testQuoteIsShellSafe() {
        XCTAssertEqual(Paths.quote("plain"), "'plain'")
        XCTAssertEqual(Paths.quote("it's"), "'it'\\''s'")
    }
}
