// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeCloudTunnelCore",
    platforms: [
        .macOS(.v14),
        // The iOS Cloud VPN extension (ios/CloudVPN) runs the same lifecycle.
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "BreeCloudTunnelCore",
            targets: ["BreeCloudTunnelCore"]
        ),
    ],
    targets: [
        .target(
            name: "BreeCloudTunnelCore",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(name: "BreeCloudTunnelCoreTests", dependencies: ["BreeCloudTunnelCore"]),
    ]
)
