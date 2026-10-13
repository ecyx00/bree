// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeWorkspaces",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeWorkspaces",
            targets: ["BreeWorkspaces"]
        ),
    ],
    dependencies: [
        // WorkspaceGroupNewPlacement (the typed setting value for new
        // in-group workspace placement) is owned by BreeSettings.
        .package(path: "../BreeSettings"),
        // BreeIdentity names the Application Support folder snapshots live in.
        .package(path: "../BreeFoundation"),
        // Bonsplit drives the Window/ tmux pane-overlay geometry.
        .package(path: "../../../vendor/bonsplit"),
        // BREEDebugLog backs the Session/ snapshot-restore logging.
        .package(path: "../BREEDebugLog"),
        // BreeTestSupport backs FileOpen/ PreferredEditorService UI-test capture.
        .package(path: "../BreeTestSupport"),
    ],
    targets: [
        .target(
            name: "BreeWorkspaces",
            dependencies: [
                .product(name: "BreeSettings", package: "BreeSettings"),
                .product(name: "BreeFoundation", package: "BreeFoundation"),
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "BREEDebugLog", package: "BREEDebugLog"),
                .product(name: "BreeTestSupport", package: "BreeTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeWorkspacesTests",
            dependencies: [
                "BreeWorkspaces",
                .product(name: "Bonsplit", package: "bonsplit"),
                .product(name: "BreeTestSupport", package: "BreeTestSupport"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
