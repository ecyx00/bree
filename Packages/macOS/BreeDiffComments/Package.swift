// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BreeDiffComments",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "BreeDiffComments",
            targets: ["BreeDiffComments"]
        ),
    ],
    targets: [
        .target(
            name: "BreeDiffComments",
            path: "Sources/BreeDiffComments"
        ),
    ]
)
