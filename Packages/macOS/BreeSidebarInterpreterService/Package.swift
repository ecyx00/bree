// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BreeSidebarInterpreterService",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // Host-side client + wire protocol the app links against.
        .library(
            name: "BreeSidebarInterpreterClient",
            targets: ["BreeSidebarInterpreterClient"]
        ),
        // The out-of-process worker that runs the untrusted interpreter.
        .executable(
            name: "bree-sidebar-interpreter",
            targets: ["bree-sidebar-interpreter"]
        ),
        // Headless protocol fixture for RenderWorkerClient supervision tests.
        .executable(
            name: "bree-sidebar-render-fixture",
            targets: ["bree-sidebar-render-fixture"]
        ),
        // Remote rendering: the faceless render-worker loop and the host-side
        // layer-hosting sidebar surface.
        .library(
            name: "BreeSidebarRemoteRender",
            targets: ["BreeSidebarRemoteRender"]
        ),
    ],
    dependencies: [
        .package(path: "../BreeSwiftRender"),
        .package(path: "../BreeSwiftRenderUI"),
    ],
    targets: [
        .target(
            name: "BreeSidebarInterpreterClient",
            dependencies: ["BreeSwiftRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "bree-sidebar-interpreter",
            dependencies: ["BreeSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .executableTarget(
            name: "bree-sidebar-render-fixture",
            dependencies: ["BreeSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .target(
            name: "BreeSidebarRemoteRender",
            dependencies: [
                "BreeSidebarInterpreterClient",
                .product(name: "BreeSwiftRenderUI", package: "BreeSwiftRenderUI"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BreeSidebarInterpreterClientTests",
            dependencies: ["BreeSidebarInterpreterClient"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        .testTarget(
            name: "BreeSidebarRemoteRenderTests",
            dependencies: ["BreeSidebarRemoteRender"],
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
    ]
)
