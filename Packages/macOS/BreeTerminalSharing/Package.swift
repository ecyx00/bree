// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeTerminalSharing",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BreeTerminalSharing", targets: ["BreeTerminalSharing"])],
    dependencies: [.package(path: "../../Shared/BreeTerminalSizing")],
    targets: [
        .target(name: "BreeTerminalSharing", dependencies: ["BreeTerminalSizing"]),
        .testTarget(name: "BreeTerminalSharingTests", dependencies: ["BreeTerminalSharing", "BreeTerminalSizing"]),
    ],
    swiftLanguageModes: [.v6]
)
