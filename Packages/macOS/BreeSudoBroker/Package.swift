// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSudoBroker",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BreeSudoBroker", targets: ["BreeSudoBroker"]),
    ],
    targets: [
        .target(
            name: "BreeSudoBroker",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeSudoBrokerTests",
            dependencies: ["BreeSudoBroker"]
        ),
    ]
)
