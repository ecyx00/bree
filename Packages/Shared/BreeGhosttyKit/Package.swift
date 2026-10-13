// swift-tools-version: 6.0

import PackageDescription

// Wraps the single GhosttyKit.xcframework binary so both the macOS
// (BreeTerminalCore) and iOS (BreeMobileTerminal) terminal packages can
// depend on the same target instead of each declaring their own
// binaryTarget of the same name pointing at the same file. SwiftPM requires
// target names to be unique across the whole resolved graph, and both
// platform-specific packages resolve together in bree.xcworkspace.
let package = Package(
    name: "BreeGhosttyKit",
    products: [
        .library(
            name: "BreeGhosttyKit",
            targets: ["GhosttyKit"]
        ),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "../../../GhosttyKit.xcframework"
        ),
    ]
)
