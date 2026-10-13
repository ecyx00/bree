import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite struct SavedLayoutDefinitionTests {
    @Test func savedLayoutCodableRoundTripsNestedSplitTree() throws {
        let layout = BreeSavedLayout(
            name: "Nested",
            description: "Round trip",
            workspace: BreeWorkspaceDefinition(
                name: "Workspace",
                cwd: "/tmp/project",
                color: "#123456",
                env: ["A": "B"],
                layout: Self.nestedLayout
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(layout)
        let decoded = try JSONDecoder().decode(BreeSavedLayout.self, from: data)

        #expect(decoded.name == "Nested")
        #expect(decoded.description == "Round trip")
        #expect(decoded.workspace.cwd == "/tmp/project")
        let root = try #require(decoded.workspace.layout)
        guard case .split(let split) = root else {
            Issue.record("Expected split root")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.split == 0.33)
        guard case .pane(let firstPane) = split.children[0] else {
            Issue.record("Expected first pane")
            return
        }
        #expect(firstPane.surfaces[0].type == .terminal)
        #expect(firstPane.surfaces[0].cwd == "server")
        #expect(firstPane.surfaces[0].name == "Server")
        #expect(firstPane.surfaces[0].focus == true)
    }

    @Test func splitDefinitionClampsDividerPosition() {
        #expect(BreeSplitDefinition(direction: .horizontal, split: -1, children: Self.twoPanes).clampedSplitPosition == 0.1)
        #expect(BreeSplitDefinition(direction: .horizontal, split: 2, children: Self.twoPanes).clampedSplitPosition == 0.9)
        #expect(BreeSplitDefinition(direction: .horizontal, split: 0.42, children: Self.twoPanes).clampedSplitPosition == 0.42)
        #expect(BreeSplitDefinition(direction: .horizontal, children: Self.twoPanes).clampedSplitPosition == 0.5)
    }

    @Test func storeJSONLayoutDecodesThroughWorkspaceCreateLayoutDecoder() throws {
        let context = try TemporarySavedLayoutContext()
        defer { context.cleanup() }
        let store = SavedLayoutStore(fileURL: context.fileURL)
        try store.save(
            BreeSavedLayout(
                name: "Nested",
                description: nil,
                workspace: BreeWorkspaceDefinition(cwd: "/tmp/project", layout: Self.nestedLayout)
            ),
            overwrite: false
        )

        let data = try Data(contentsOf: context.fileURL)
        let decoded = try JSONDecoder().decode(SavedLayoutStore.LayoutsFile.self, from: data)
        let layoutNode = try #require(decoded.layouts.first?.workspace.layout)
        let layoutData = try JSONEncoder().encode(layoutNode)
        _ = try JSONDecoder().decode(BreeLayoutNode.self, from: layoutData)
    }

    private static var nestedLayout: BreeLayoutNode {
        .split(
            BreeSplitDefinition(
                direction: .horizontal,
                split: 0.33,
                children: [
                    .pane(BreePaneDefinition(surfaces: [
                        BreeSurfaceDefinition(type: .terminal, name: "Server", command: nil, cwd: "server", env: nil, url: nil, focus: true),
                    ])),
                    .split(BreeSplitDefinition(
                        direction: .vertical,
                        split: 0.66,
                        children: [
                            .pane(BreePaneDefinition(surfaces: [
                                BreeSurfaceDefinition(type: .browser, name: "Docs", command: nil, cwd: nil, env: nil, url: "https://example.com", focus: nil),
                            ])),
                            .pane(BreePaneDefinition(surfaces: [
                                BreeSurfaceDefinition(type: .terminal, name: nil, command: nil, cwd: nil, env: nil, url: nil, focus: nil),
                            ])),
                        ]
                    )),
                ]
            )
        )
    }

    private static var twoPanes: [BreeLayoutNode] {
        [
            .pane(BreePaneDefinition(surfaces: [BreeSurfaceDefinition(type: .terminal)])),
            .pane(BreePaneDefinition(surfaces: [BreeSurfaceDefinition(type: .terminal)])),
        ]
    }
}
