// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeMobileHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeMobileHost",
            targets: ["BreeMobileHost"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../../Shared/BreeAgentChat"),
    ],
    targets: [
        .target(
            name: "BreeMobileHost",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeAgentChat", package: "BreeAgentChat"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
