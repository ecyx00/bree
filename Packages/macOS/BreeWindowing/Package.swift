// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeWindowing",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeWindowing",
            targets: ["BreeWindowing"]
        ),
    ],
    targets: [
        .target(
            name: "BreeWindowing",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeWindowingTests",
            dependencies: ["BreeWindowing"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
