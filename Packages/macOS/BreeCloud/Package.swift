// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeCloud",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BreeCloud", targets: ["BreeCloud"])],
    dependencies: [
        .package(path: "../../Shared/BREEAuthCore"),
        .package(path: "../../Shared/BreeAuthRuntime"),
        .package(path: "../../Shared/BREEMobileCore"),
        .package(path: "../BREEDebugLog"),
        .package(path: "../BreeCloudBannerCore"),
        .package(path: "../BreeCloudImagePaste"),
        .package(path: "../BreeCloudMachines"),
        .package(path: "../BreeCloudTui"),
        .package(path: "../BreeCloudTunnelCore"),
        .package(path: "../BreeControlSocket"),
        .package(path: "../BreeCore"),
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeSettings"),
        .package(path: "../BreeSurfaceCatalogModel"),
        .package(path: "../BreeTerminal")
    ],
    targets: [
        .target(
            name: "BreeCloud",
            dependencies: [
                "BREEAuthCore",
                "BreeAuthRuntime",
                "BREEMobileCore",
                "BREEDebugLog",
                "BreeCloudBannerCore",
                "BreeCloudImagePaste",
                "BreeCloudMachines",
                "BreeCloudTui",
                "BreeCloudTunnelCore",
                "BreeControlSocket",
                "BreeCore",
                "BreeFoundation",
                "BreeSettings",
                "BreeSurfaceCatalogModel"
            ],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BreeCloudTests",
            dependencies: [
                "BreeCloud",
                "BreeAuthRuntime",
                "BreeCloudTui",
                "BreeCloudTunnelCore",
                "BREEMobileCore",
                "BreeSurfaceCatalogModel",
                // BreeTerminal binds libghostty, which SwiftPM cannot link here.
                .product(name: "BreeTerminalGhosttyRuntimeTestStubs", package: "BreeTerminal")
            ],
            // Most of these tests moved from the app's test target, which builds in Swift 5 mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
