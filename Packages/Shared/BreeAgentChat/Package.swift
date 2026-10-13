// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAgentChat",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAgentChat",
            targets: ["BreeAgentChat"]
        ),
    ],
    targets: [
        .target(
            name: "BreeAgentChat",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BreeAgentChatTests",
            dependencies: ["BreeAgentChat"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
