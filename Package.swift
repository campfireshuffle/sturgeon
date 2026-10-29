// swift-tools-version: 6.0
// Sturgeon — the menu-bar app and its testable core.
//
// The app is a SwiftUI shell over `SturgeonKit`, which holds everything that is not UI: path
// resolution, the process runner, command construction and JSON decoding. Nothing here has a
// dependency; `swift build` and `swift test` need only the command line tools.
import PackageDescription

let package = Package(
    name: "Sturgeon",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Sturgeon", targets: ["Sturgeon"]),
        .library(name: "SturgeonKit", targets: ["SturgeonKit"]),
    ],
    targets: [
        .executableTarget(
            name: "Sturgeon",
            dependencies: ["SturgeonKit"]
        ),
        .target(name: "SturgeonKit"),
        .testTarget(
            name: "SturgeonKitTests",
            dependencies: ["SturgeonKit"]
        ),
    ],
    // The AppKit view model is callback-based (DispatchQueue + AppKit); Swift 5 language mode keeps
    // this restructuring a build-system change. Moving to Swift 6 concurrency is its own change.
    swiftLanguageModes: [.v5]
)
