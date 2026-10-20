// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeSurfaceCatalogModel",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BreeSurfaceCatalogModel", targets: ["BreeSurfaceCatalogModel"])],
    dependencies: [
        .package(path: "../BREEDebugLog"),
        .package(path: "../BreeCore"),
        .package(path: "../../Shared/BreeAppSupport")
    ],
    targets: [
        .target(
            name: "BreeSurfaceCatalogModel",
            dependencies: ["BREEDebugLog", "BreeCore", "BreeAppSupport"],
            // The files moved out of the app target unchanged; keep its language mode.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "BreeSurfaceCatalogModelTests", dependencies: ["BreeSurfaceCatalogModel"])
    ]
)
