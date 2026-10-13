// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeFoundation",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeFoundation",
            targets: ["BreeFoundation"]
        ),
    ],
    targets: [
        .target(
            name: "BreeFoundationAtomicsC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BreeFoundation",
            dependencies: ["BreeFoundationAtomicsC"],
            resources: [.process("Resources")],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeFoundationTests",
            dependencies: ["BreeFoundation"]
        ),
    ]
)
