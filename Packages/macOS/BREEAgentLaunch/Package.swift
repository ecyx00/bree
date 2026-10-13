// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BREEAgentLaunch",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BREEAgentLaunch",
            targets: ["BREEAgentLaunch"]
        ),
    ],
    targets: [
        .target(
            name: "BREEAgentLaunch"
        ),
        .testTarget(
            name: "BREEAgentLaunchTests",
            dependencies: ["BREEAgentLaunch"]
        ),
    ]
)
