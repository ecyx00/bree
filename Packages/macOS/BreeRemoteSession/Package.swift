// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeRemoteSession",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeRemoteSession",
            targets: ["BreeRemoteSession"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeCore"),
        .package(path: "../BreeRemoteDaemon"),
        .package(path: "../BreeRemoteWorkspace"),
        .package(path: "../BREEDebugLog"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "BreeRemoteSession",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeCore", package: "BreeCore"),
                .product(name: "BreeRemoteDaemon", package: "BreeRemoteDaemon"),
                .product(name: "BreeRemoteWorkspace", package: "BreeRemoteWorkspace"),
                .product(name: "BREEDebugLog", package: "BREEDebugLog"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeRemoteSessionTests",
            dependencies: [
                "BreeRemoteSession",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeCore", package: "BreeCore"),
                .product(name: "BreeRemoteDaemon", package: "BreeRemoteDaemon"),
                .product(name: "BreeRemoteWorkspace", package: "BreeRemoteWorkspace"),
                .product(name: "Bonsplit", package: "bonsplit"),
            ]
        ),
    ]
)
