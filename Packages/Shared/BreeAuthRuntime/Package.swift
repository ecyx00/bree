// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeAuthRuntime",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAuthRuntime",
            targets: ["BreeAuthRuntime"]
        ),
    ],
    dependencies: [
        .package(path: "../BREEAuthCore"),
        .package(path: "../BREEMobileCore"),
        .package(path: "../../../vendor/stack-auth-swift-sdk-prerelease"),
    ],
    targets: [
        .target(
            name: "BreeAuthRuntime",
            dependencies: [
                "BREEAuthCore",
                "BREEMobileCore",
                .product(name: "StackAuth", package: "stack-auth-swift-sdk-prerelease"),
            ],
            swiftSettings: [
                .define("BREE_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeAuthRuntimeTests",
            dependencies: ["BreeAuthRuntime"],
            swiftSettings: [
                .define("BREE_DEV_AUTH", .when(configuration: .debug)),
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
