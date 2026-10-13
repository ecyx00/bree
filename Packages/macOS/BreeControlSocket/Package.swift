// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeControlSocket",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeControlSocket",
            targets: ["BreeControlSocket"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeCore"),
        .package(path: "../BreeFoundation"),
        .package(path: "../BreeSettings"),
    ],
    targets: [
        .target(
            name: "BreeControlSocketAtomicsC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "BreeControlSocket",
            dependencies: [
                .product(name: "BreeCore", package: "BreeCore"),
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeSettings", package: "BreeSettings"),
                "BreeControlSocketAtomicsC",
            ],
            resources: [
                .process("Resources/Localizable.xcstrings"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeControlSocketTests",
            dependencies: [
                "BreeControlSocket",
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "BreeSettings", package: "BreeSettings"),
            ]
        ),
    ]
)
