// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAppSupport",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAppSupport",
            targets: ["BreeAppSupport"]
        ),
    ],
    targets: [
        .target(
            name: "BreeAppSupport",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BreeAppSupportTests",
            dependencies: ["BreeAppSupport"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
