// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeRemoteWorkspace",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeRemoteWorkspace",
            targets: ["BreeRemoteWorkspace"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeCore"),
        .package(path: "../BreeRemoteDaemon"),
        .package(path: "../BreeSettings"),
    ],
    targets: [
        .target(
            name: "BreeRemoteWorkspace",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeCore", package: "BreeCore"),
                .product(name: "BreeRemoteDaemon", package: "BreeRemoteDaemon"),
                .product(name: "BreeSettings", package: "BreeSettings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeRemoteWorkspaceTests",
            dependencies: [
                "BreeRemoteWorkspace",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ]
        ),
    ]
)
