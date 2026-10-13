// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeLiveEval",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeLiveEval",
            targets: ["BreeLiveEval"]
        ),
        .executable(
            name: "LiveEvalDemo",
            targets: ["LiveEvalDemo"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeSwiftRender"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
    ],
    targets: [
        .target(
            name: "BreeLiveEval",
            dependencies: [
                .product(name: "BreeSwiftRender", package: "BreeSwiftRender"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftOperators", package: "swift-syntax"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "LiveEvalDemo",
            dependencies: ["BreeLiveEval"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BreeLiveEvalTests",
            dependencies: ["BreeLiveEval"]
        ),
    ]
)
