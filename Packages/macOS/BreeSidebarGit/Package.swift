// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSidebarGit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSidebarGit",
            targets: ["BreeSidebarGit"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeGit"),
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeSidebarGit",
            dependencies: [
                .product(name: "BreeGit", package: "BreeGit"),
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeSidebarGitTests",
            dependencies: [
                "BreeSidebarGit",
                .product(name: "BreeGit", package: "BreeGit"),
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
