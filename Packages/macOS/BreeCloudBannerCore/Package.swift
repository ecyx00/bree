// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeCloudBannerCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeCloudBannerCore",
            targets: ["BreeCloudBannerCore"]
        ),
    ],
    targets: [
        .target(
            name: "BreeCloudBannerCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeCloudBannerCoreTests",
            dependencies: ["BreeCloudBannerCore"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
