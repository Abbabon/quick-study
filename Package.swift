// swift-tools-version: 5.9
import Foundation
import PackageDescription

// The Rust engine's XCFramework and Swift bindings are generated, not committed.
let enginePath = "engine/EngineFFI.xcframework"
if !FileManager.default.fileExists(atPath: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent(enginePath).path) {
    fatalError("Missing \(enginePath): run ./scripts/build-engine.sh once before `swift build` / `swift test`.")
}

let package = Package(
    name: "QuickStudy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuickStudy", targets: ["QuickStudy"]),
        .library(name: "Shared", targets: ["Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        // Rust engine (search + query parser) via UniFFI: prebuilt static lib + generated bindings.
        .binaryTarget(name: "engineFFI", path: enginePath),
        .target(
            name: "EngineBindings",
            dependencies: ["engineFFI"],
            path: "Sources/EngineBindings"
        ),
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "QuickStudy",
            dependencies: [
                "Shared",
                "EngineBindings",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/QuickStudy"
        ),
        .testTarget(
            name: "SearchEngineTests",
            dependencies: ["QuickStudy", "Shared", "EngineBindings"],
            path: "Tests/SearchEngineTests"
        ),
    ]
)
