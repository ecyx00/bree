// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSidebar",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSidebar",
            targets: ["BreeSidebar"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeSwiftRender"),
        // BreeExtensionKit backs the ExtensionHost/ sidebar-extension host view
        // and browser presenter.
        .package(path: "../BreeExtensionKit"),
    ],
    targets: [
        .target(
            name: "BreeSidebar",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeSwiftRender", package: "BreeSwiftRender"),
                .product(name: "BreeExtensionKit", package: "BreeExtensionKit"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeSidebarTests",
            dependencies: [
                "BreeSidebar",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeSwiftRender", package: "BreeSwiftRender"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
