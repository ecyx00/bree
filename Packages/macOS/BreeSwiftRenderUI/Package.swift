// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSwiftRenderUI",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSwiftRenderUI",
            targets: ["BreeSwiftRenderUI"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeSwiftRender"),
        .package(path: "../BreeSettings"),
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeSwiftRenderUI",
            dependencies: [
                .product(name: "BreeSwiftRender", package: "BreeSwiftRender"),
                .product(name: "BreeSettings", package: "BreeSettings"),
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "BreeSwiftRenderUITests",
            dependencies: ["BreeSwiftRenderUI"]
        ),
        // Dev-only GUI lab for iterating on the reorderable drag interaction
        // without an app build. Run: swift run reorder-lab
        .executableTarget(
            name: "reorder-lab",
            dependencies: ["BreeSwiftRenderUI"]
        ),
    ]
)
