// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSettings",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSettings",
            targets: ["BreeSettings"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeCore"),
    ],
    targets: [
        .target(
            name: "BreeSettings",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeCore", package: "BreeCore"),
            ],
            resources: [
                .copy("Resources/CustomSidebarTemplates"),
            ]
        ),
        .testTarget(
            name: "BreeSettingsTests",
            dependencies: ["BreeSettings"]
        ),
    ]
)
