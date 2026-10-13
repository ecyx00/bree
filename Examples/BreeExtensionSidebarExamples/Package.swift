// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeExtensionSidebarExamples",
    platforms: [.macOS(.v14)],
    products: [
        .library(
            name: "BreeExtensionSidebarExamples",
            targets: ["BreeExtensionSidebarExamples"]
        ),
    ],
    dependencies: [
        .package(path: "../../Packages/macOS/BreeSidebarProviderKit"),
    ],
    targets: [
        .target(
            name: "BreeExtensionSidebarExamples",
            dependencies: ["BreeSidebarProviderKit"]
        ),
        .testTarget(
            name: "BreeExtensionSidebarExamplesTests",
            dependencies: ["BreeExtensionSidebarExamples"]
        ),
    ]
)
