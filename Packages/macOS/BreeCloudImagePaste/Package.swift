// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeCloudImagePaste",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BreeCloudImagePaste", targets: ["BreeCloudImagePaste"]),
    ],
    targets: [
        .target(
            name: "BreeCloudImagePaste",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeCloudImagePasteTests",
            dependencies: ["BreeCloudImagePaste"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
