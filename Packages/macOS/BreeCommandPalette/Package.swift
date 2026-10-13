// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeCommandPalette",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeCommandPalette",
            targets: ["BreeCommandPalette"]
        ),
    ],
    dependencies: [
        // BreeFoundation backs the FocusGuards/ command-palette focus-stealing
        // NSResponder/NSView guards.
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeCommandPalette",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeCommandPaletteTests",
            dependencies: [
                "BreeCommandPalette",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
