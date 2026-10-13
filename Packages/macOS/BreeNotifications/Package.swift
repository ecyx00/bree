// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeNotifications",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeNotifications",
            targets: ["BreeNotifications"]
        ),
    ],
    targets: [
        .target(
            name: "BreeNotifications",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeNotificationsTests",
            dependencies: ["BreeNotifications"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
