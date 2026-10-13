// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BREEDebugLog",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BREEDebugLog",
            targets: ["BREEDebugLog"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BREEDebugLog",
            dependencies: [
                .product(name: "BreeFoundation", package: "BreeFoundation"),
            ],
            path: "Sources/BREEDebugLog"
        ),
        .testTarget(
            name: "BREEDebugLogTests",
            dependencies: ["BREEDebugLog"],
            path: "Tests/BREEDebugLogTests"
        ),
    ]
)
