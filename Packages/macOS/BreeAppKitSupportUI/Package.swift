// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAppKitSupportUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAppKitSupportUI",
            targets: ["BreeAppKitSupportUI"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeWorkspaces"),
    ],
    targets: [
        .target(
            name: "BreeAppKitSupportUI",
            dependencies: [
                "BreeFoundation",
                "BreeWorkspaces",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeAppKitSupportUITests",
            dependencies: ["BreeAppKitSupportUI"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
