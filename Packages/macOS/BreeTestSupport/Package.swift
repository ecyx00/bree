// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeTestSupport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeTestSupport",
            targets: ["BreeTestSupport"]
        ),
    ],
    targets: [
        .target(
            name: "BreeTestSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeTestSupportTests",
            dependencies: ["BreeTestSupport"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
