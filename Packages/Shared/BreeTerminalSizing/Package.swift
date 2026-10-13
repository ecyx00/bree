// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeTerminalSizing",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "BreeTerminalSizing", targets: ["BreeTerminalSizing"])],
    targets: [
        .target(name: "BreeTerminalSizing"),
        .testTarget(name: "BreeTerminalSizingTests", dependencies: ["BreeTerminalSizing"])
    ],
    swiftLanguageModes: [.v6]
)
