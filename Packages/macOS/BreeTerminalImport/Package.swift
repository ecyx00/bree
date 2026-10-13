// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeTerminalImport",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeTerminalImport",
            targets: ["BreeTerminalImport"]
        ),
    ],
    targets: [
        .target(
            name: "BreeTerminalImport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeTerminalImportTests",
            dependencies: ["BreeTerminalImport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
