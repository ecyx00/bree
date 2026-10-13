// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeSidebarProviderKit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeSidebarProviderKit",
            targets: ["BreeSidebarProviderKit"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeFoundation"),
    ],
    targets: [
        .target(
            name: "BreeSidebarProviderKit",
            dependencies: ["BreeFoundation"]
        ),
    ]
)
