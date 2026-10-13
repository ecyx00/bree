// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BREEMobileCore",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BREEMobileCore",
            targets: ["BREEMobileCore"]
        ),
    ],
    targets: [
        .target(
            name: "BREEMobileCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BREEMobileCoreTests",
            dependencies: ["BREEMobileCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
