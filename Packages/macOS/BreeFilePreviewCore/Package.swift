// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeFilePreviewCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeFilePreviewCore",
            targets: ["BreeFilePreviewCore"]
        ),
    ],
    targets: [
        .target(
            name: "BreeFilePreviewCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeFilePreviewCoreTests",
            dependencies: ["BreeFilePreviewCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
