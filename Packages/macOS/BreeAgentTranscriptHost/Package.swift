// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAgentTranscriptHost",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAgentTranscriptHost",
            targets: ["BreeAgentTranscriptHost"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../../Shared/BreeAgentChat"),
    ],
    targets: [
        .target(
            name: "BreeAgentTranscriptHost",
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
