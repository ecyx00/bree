// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BREEAuthCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BREEAuthCore",
            targets: ["BREEAuthCore"]
        ),
    ],
    targets: [
        .target(
            name: "BREEAuthCore"
        ),
        .testTarget(
            name: "BREEAuthCoreTests",
            dependencies: ["BREEAuthCore"]
        ),
    ]
)
