// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeCloudTui",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BreeCloudTui", targets: ["BreeCloudTui"])],
    dependencies: [
        .package(path: "../BreeCloudImagePaste"),
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeSurfaceCatalogModel"),
        .package(path: "../BreeTerminal"),
        .package(path: "../../Shared/BreeTerminalSizing")
    ],
    targets: [
        .target(
            name: "BreeCloudTui",
            dependencies: ["BreeCloudImagePaste", "BreeFoundation", "BreeSurfaceCatalogModel", "BreeTerminal", "BreeTerminalSizing"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BreeCloudTuiTests",
            dependencies: [
                "BreeCloudTui",
                // BreeTerminal binds libghostty, which SwiftPM cannot link here.
                .product(name: "BreeTerminalGhosttyRuntimeTestStubs", package: "BreeTerminal"),
            ]
        )
    ]
)
