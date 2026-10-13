import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// A session file or closed-item history written by a build that had more panel types or
/// built-in tab bar actions must degrade by dropping the unknown pieces, never by losing the
/// whole file.
@Suite @MainActor struct SessionTolerantDecodingTests {
    private static let unknownPanelTypes = ["futureUnknownPanelType", "anotherRemovedPanelType"]

    private func panelJSON(id: UUID, type: String) -> [String: Any] {
        [
            "id": id.uuidString,
            "type": type,
            "isPinned": false,
            "isManuallyUnread": false,
            "listeningPorts": [Int](),
        ]
    }

    private func workspaceJSON(terminalId: UUID, extraPanelTypes: [String]) throws -> [String: Any] {
        let layout = SessionWorkspaceLayoutSnapshot.pane(
            SessionPaneLayoutSnapshot(panelIds: [terminalId], selectedPanelId: terminalId)
        )
        let layoutObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(layout))
        var panels = [panelJSON(id: terminalId, type: "terminal")]
        panels += extraPanelTypes.map { panelJSON(id: UUID(), type: $0) }
        return [
            "processTitle": "shell",
            "isPinned": false,
            "currentDirectory": "/tmp",
            "layout": layoutObject,
            "panels": panels,
            "statusEntries": [Any](),
            "logEntries": [Any](),
            // Persisted by removed features; must stay decodable and ignored.
            "layoutMode": "canvas",
            "canvasPanes": [["panelId": terminalId.uuidString, "x": 0, "y": 0, "width": 10, "height": 10]],
        ]
    }

    @Test func unknownPanelTypesAreDroppedAndTheWorkspaceSurvives() throws {
        let terminalId = UUID()
        let json = try workspaceJSON(terminalId: terminalId, extraPanelTypes: Self.unknownPanelTypes)
        let data = try JSONSerialization.data(withJSONObject: json)

        let workspace = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)

        #expect(workspace.panels.map(\.id) == [terminalId])
        #expect(workspace.panels.first?.type == .terminal)
        #expect(workspace.currentDirectory == "/tmp")
    }

    @Test func wellFormedPanelsKeepTheirOrderAndRoundTrip() throws {
        let ids = [UUID(), UUID(), UUID()]
        var json = try workspaceJSON(terminalId: ids[0], extraPanelTypes: [])
        json["panels"] = [
            panelJSON(id: ids[0], type: "terminal"),
            panelJSON(id: UUID(), type: "futureUnknownPanelType"),
            panelJSON(id: ids[1], type: "browser"),
            panelJSON(id: ids[2], type: "markdown"),
        ]
        let data = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)
        #expect(decoded.panels.map(\.id) == ids)

        // The wrapper must encode as a plain array so the file format does not change.
        let reencoded = try JSONEncoder().encode(decoded)
        let object = try #require(try JSONSerialization.jsonObject(with: reencoded) as? [String: Any])
        #expect((object["panels"] as? [[String: Any]])?.count == 3)
        #expect(try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: reencoded).panels.map(\.id) == ids)
    }

    @Test func aWorkspaceWithOnlyUnknownPanelsStillDecodes() throws {
        var json = try workspaceJSON(terminalId: UUID(), extraPanelTypes: [])
        json["panels"] = [panelJSON(id: UUID(), type: "futureUnknownPanelType")]
        let data = try JSONSerialization.data(withJSONObject: json)

        let workspace = try JSONDecoder().decode(SessionWorkspaceSnapshot.self, from: data)

        #expect(workspace.panels.isEmpty)
    }

    @Test func closedItemHistoryDropsOnlyTheRecordsThatNoLongerDecode() throws {
        let goodPanel = try JSONDecoder().decode(
            SessionPanelSnapshot.self,
            from: JSONSerialization.data(withJSONObject: panelJSON(id: UUID(), type: "terminal"))
        )
        func record(_ panel: SessionPanelSnapshot) -> ClosedItemHistoryRecord {
            ClosedItemHistoryRecord(
                entry: .panel(
                    ClosedPanelHistoryEntry(
                        workspaceId: UUID(),
                        paneId: UUID(),
                        tabIndex: 0,
                        snapshot: panel
                    )
                )
            )
        }
        let encoder = JSONEncoder()
        let first = try JSONSerialization.jsonObject(with: encoder.encode(record(goodPanel)))
        let second = try JSONSerialization.jsonObject(with: encoder.encode(record(goodPanel)))
        let third = try JSONSerialization.jsonObject(with: encoder.encode(record(goodPanel)))
        let corrupted = Self.replacingPanelType(in: second, with: "futureUnknownPanelType")

        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("closed-history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "records": [first, corrupted, third],
        ])
        try data.write(to: file)

        let store = ClosedItemHistoryStore(
            fileURL: file,
            loadPersisted: true,
            loadsPersistedRecordsSynchronously: true
        )

        #expect(store.menuSnapshot().totalItemCount == 2)

        // The legacy bare-array file format is tolerant as well.
        let legacyData = try JSONSerialization.data(withJSONObject: [first, corrupted, third])
        try legacyData.write(to: file)
        let legacyStore = ClosedItemHistoryStore(
            fileURL: file,
            loadPersisted: true,
            loadsPersistedRecordsSynchronously: true
        )
        #expect(legacyStore.menuSnapshot().totalItemCount == 2)
    }

    @Test func surfaceTabBarButtonsSkipUnknownBuiltInActionsButKeepTheRest() throws {
        let json = """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": [
                { "builtin": "bree.removedForTest" },
                { "builtin": "bree.newTerminal" },
                { "builtin": "newRemovedForTest" },
                { "id": "start-codex", "command": "codex" }
              ]
            }
          }
        }
        """
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: Data(json.utf8))

        let buttons = try #require(config.surfaceTabBarButtons)
        #expect(buttons.map(\.id).contains("start-codex"))
        #expect(!buttons.contains { $0.id.contains("RemovedForTest") || $0.id.contains("removedForTest") })
        #expect(buttons.count == 2)
    }

    @Test func rootSurfaceTabBarButtonsSkipUnknownBuiltInActions() throws {
        let json = """
        {
          "surfaceTabBarButtons": [
            { "builtin": "bree.doesNotExist" },
            { "id": "start-codex", "command": "codex" }
          ]
        }
        """
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: Data(json.utf8))

        #expect(config.surfaceTabBarButtons?.map(\.id) == ["start-codex"])
    }

    @Test func actionDefinitionsSkipUnknownBuiltInsButKeepTheRest() throws {
        let json = """
        {
          "actions": {
            "bree.removedForTest": { "type": "builtin", "builtin": "bree.removedForTest", "newWorkspaceMenu": false },
            "start-codex": { "type": "command", "command": "codex" }
          }
        }
        """
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: Data(json.utf8))

        #expect(Array(config.actions.keys) == ["start-codex"])
    }

    @Test func surfaceTabBarButtonsStillRejectOtherMalformedEntries() {
        let json = """
        { "surfaceTabBarButtons": [ { "type": "notARealButtonType" } ] }
        """
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(BreeConfigFile.self, from: Data(json.utf8))
        }
    }

    private static func replacingPanelType(in object: Any, with type: String) -> Any {
        if var dictionary = object as? [String: Any] {
            if dictionary["type"] as? String == "terminal", dictionary["isManuallyUnread"] != nil {
                dictionary["type"] = type
            }
            return dictionary.mapValues { replacingPanelType(in: $0, with: type) }
        }
        if let array = object as? [Any] {
            return array.map { replacingPanelType(in: $0, with: type) }
        }
        return object
    }
}
