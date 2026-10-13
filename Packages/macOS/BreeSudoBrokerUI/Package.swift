// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSudoBrokerUI",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "BreeSudoBrokerUI", targets: ["BreeSudoBrokerUI"]),
    ],
    dependencies: [
        .package(path: "../BreeSudoBroker"),
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeSudoBrokerUI",
            dependencies: [
                "BreeSudoBroker",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeSudoBrokerUITests",
            dependencies: ["BreeSudoBrokerUI"]
        ),
    ]
)
