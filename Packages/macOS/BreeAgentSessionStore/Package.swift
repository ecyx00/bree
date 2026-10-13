// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAgentSessionStore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAgentSessionStore",
            targets: ["BreeAgentSessionStore"]
        ),
    ],
    dependencies: [
        .package(path: "../BREEAgentLaunch"),
    ],
    targets: [
        .target(
            name: "BreeAgentSessionStore",
            dependencies: [
                .product(name: "BREEAgentLaunch", package: "BREEAgentLaunch"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeAgentSessionStoreTests",
            dependencies: ["BreeAgentSessionStore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
