// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BREEProjectModel",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BREEProjectModel",
            targets: ["BREEProjectModel"]
        ),
        .executable(
            name: "bree-project-dump",
            targets: ["BREEProjectDump"]
        ),
    ],
    targets: [
        .target(
            name: "BREEProjectModel"
        ),
        .executableTarget(
            name: "BREEProjectDump",
            dependencies: ["BREEProjectModel"]
        ),
        .testTarget(
            name: "BREEProjectModelTests",
            dependencies: ["BREEProjectModel"]
        ),
    ]
)
