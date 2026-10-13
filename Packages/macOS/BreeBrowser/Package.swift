// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeBrowser",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeBrowser",
            targets: ["BreeBrowser"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BREEDebugLog"),
        .package(path: "../BreeSettings"),
        .package(path: "../../../vendor/bonsplit"),
    ],
    targets: [
        .target(
            name: "BreeBrowser",
            dependencies: [
                "BreeFoundation",
                "BREEDebugLog",
                "BreeSettings",
                .product(name: "Bonsplit", package: "bonsplit"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeBrowserTests",
            dependencies: [
                "BreeBrowser",
                "BreeFoundation",
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
