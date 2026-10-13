// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeCore",
            targets: ["BreeCore"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeCore",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeCoreTests",
            dependencies: ["BreeCore"]
        ),
    ]
)
