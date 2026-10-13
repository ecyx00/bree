// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeExtensionKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeExtensionKit",
            targets: ["BreeExtensionKit"]
        ),
    ],
    targets: [
        .target(
            name: "BreeExtensionKit"
        ),
        .testTarget(
            name: "BreeExtensionKitTests",
            dependencies: ["BreeExtensionKit"]
        ),
    ]
)
