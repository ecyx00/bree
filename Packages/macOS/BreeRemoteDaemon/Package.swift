// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeRemoteDaemon",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeRemoteDaemon",
            targets: ["BreeRemoteDaemon"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeCore"),
    ],
    targets: [
        .target(
            name: "BreeRemoteDaemon",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeCore", package: "BreeCore"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeRemoteDaemonTests",
            dependencies: [
                "BreeRemoteDaemon",
                .product(name: "BreeCore", package: "BreeCore"),
            ]
        ),
    ]
)
