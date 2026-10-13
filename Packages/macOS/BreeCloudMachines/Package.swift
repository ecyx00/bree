// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeCloudMachines",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BreeCloudMachines", targets: ["BreeCloudMachines"])],
    targets: [
        .target(name: "BreeCloudMachines"),
        .testTarget(name: "BreeCloudMachinesTests", dependencies: ["BreeCloudMachines"])
    ]
)
