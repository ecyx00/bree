// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeTerminal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeTerminal",
            targets: ["BreeTerminal"]
        ),
        // Lets other packages' test targets that link BreeTerminal satisfy the
        // libghostty symbols the same way BreeTerminalTests does.
        .library(
            name: "BreeTerminalGhosttyRuntimeTestStubs",
            targets: ["BreeTerminalGhosttyRuntimeTestStubs"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeTerminalCore"),
        .package(path: "../BREEDebugLog"),
        .package(path: "../BREEAgentLaunch"),
        .package(path: "../../Shared/BREEMobileCore"),
        .package(path: "../../Shared/BreeTerminalPrediction"),
        .package(path: "../../Shared/BreeGhosttyKit"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "BreeTerminal",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeTerminalCore", package: "BreeTerminalCore"),
                .product(name: "BreeGhosttyKit", package: "BreeGhosttyKit"),
                .product(name: "BREEDebugLog", package: "BREEDebugLog"),
                .product(name: "BREEAgentLaunch", package: "BREEAgentLaunch"),
                .product(name: "BREEMobileCore", package: "BREEMobileCore"),
                .product(name: "BreeTerminalPrediction", package: "BreeTerminalPrediction"),
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        // Test-only stand-in for the @_silgen_name libghostty symbol bound by
        // BreeTerminalCore's GhosttyRuntimeCInterop: SwiftPM cannot link the
        // GhosttyKit macOS archive (its binary lacks the lib prefix), so the
        // test runner satisfies the link with a stub. The app links the real
        // GhosttyKit. Named distinctly from BreeTerminalCore's own
        // GhosttyRuntimeTestStubs target (a different implementation for a
        // different test suite): SwiftPM target names must be unique across
        // the whole resolved graph, and both packages resolve together in
        // bree.xcworkspace.
        .target(
            name: "BreeTerminalGhosttyRuntimeTestStubs",
            path: "Tests/GhosttyRuntimeTestStubs"
        ),
        .testTarget(
            name: "BreeTerminalTests",
            dependencies: [
                "BreeTerminal",
                "BreeTerminalGhosttyRuntimeTestStubs",
                .product(name: "BreeTerminalCore", package: "BreeTerminalCore"),
                .product(name: "BreeGhosttyKit", package: "BreeGhosttyKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
