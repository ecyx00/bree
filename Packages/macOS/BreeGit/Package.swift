// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeGit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeGit",
            targets: ["BreeGit"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../../Shared/BreeAgentChat"),
        .package(path: "../../Shared/BreeAppSupport"),
    ],
    targets: [
        .target(
            name: "BreeGit",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeAgentChat", package: "BreeAgentChat"),
                .product(name: "BreeAppSupport", package: "BreeAppSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeGitTests",
            dependencies: ["BreeGit"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
