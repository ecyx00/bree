// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BreeAgentJournal",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "BreeAgentJournal",
            targets: ["BreeAgentJournal"]
        ),
    ],
    targets: [
        .target(
            name: "BreeAgentJournal",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "BreeAgentJournalTests",
            dependencies: ["BreeAgentJournal"]
        ),
    ]
)
