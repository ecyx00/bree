// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSettingsUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSettingsUI",
            targets: ["BreeSettingsUI"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeSettings"),
    ],
    targets: [
        .target(
            name: "BreeSettingsUI",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeSettings", package: "BreeSettings"),
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
                .copy("Resources/CustomSidebars"),
                .copy("Resources/CustomSidebarTemplatePreviews"),
            ]
        ),
        .testTarget(
            name: "BreeSettingsUITests",
            dependencies: [
                "BreeSettingsUI",
                "BreeSettings",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ]
        ),
    ]
)
