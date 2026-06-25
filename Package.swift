// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "QuickStudy",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "QuickStudy", targets: ["QuickStudy"]),
        .executable(name: "mtg-fetcher", targets: ["Fetcher"]),
        .library(name: "Shared", targets: ["Shared"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/Shared"
        ),
        .executableTarget(
            name: "Fetcher",
            dependencies: ["Shared"],
            path: "Sources/Fetcher"
        ),
        .executableTarget(
            name: "QuickStudy",
            dependencies: [
                "Shared",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/QuickStudy"
        ),
        .testTarget(
            name: "SearchEngineTests",
            dependencies: ["QuickStudy", "Shared", "Fetcher"],
            path: "Tests/SearchEngineTests"
        ),
    ]
)
