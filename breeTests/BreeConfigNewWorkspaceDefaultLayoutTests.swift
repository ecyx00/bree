import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Default workspace layout for new workspaces: persisting
/// `ui.newWorkspace.action` through the comment-preserving JSONC editors
/// (set/replace/unset, fail-closed on malformed config), resolving the
/// saved default through `BreeConfigStore`, and the plus-menu
/// default-layout submenu model.
struct BreeConfigNewWorkspaceDefaultLayoutTests {
    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bree-workspace-action-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func decodeJSONC(_ source: String) throws -> BreeConfigFile {
        let sanitized = try JSONCParser.preprocess(data: Data(source.utf8))
        return try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
    }

    @MainActor
    @Test func setNewWorkspaceDefaultActionPreservesCommentsAndResolves() throws {
        let root = try temporaryRoot("default-comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let existing = """
        {
          // saved layouts
          "actions": {
            "review-setup": {
              "type": "workspace",
              "title": "Review Setup",
              "workspace": { "name": "Review" }
            } // keep action note
          }
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(
            id: "review-setup",
            globalConfigPath: configPath
        )

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// saved layouts"))
        #expect(saved.contains("// keep action note"))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "review-setup")

        let store = BreeConfigStore(globalConfigPath: configPath)
        store.loadAll()
        #expect(store.newWorkspaceActionID == "review-setup")
        #expect(store.resolvedNewWorkspaceAction()?.id == "review-setup")
    }

    @Test func setNewWorkspaceDefaultActionReplacesExistingValue() throws {
        let root = try temporaryRoot("default-replace")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "ui": {
            "newWorkspace": {
              "action": "first"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: "second", globalConfigPath: configPath)
        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: "second", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(!saved.contains("\"action\": \"first\""))
        #expect(saved.components(separatedBy: "\"action\": \"second\"").count - 1 == 1)
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "second")
    }

    @Test func setNewWorkspaceDefaultActionCreatesMissingNewWorkspaceObject() throws {
        let root = try temporaryRoot("default-create-new-workspace")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "ui": {
            "surfaceTabBar": {
              "buttons": ["bree.newTerminal"]
            }
          },
          "commands": []
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.components(separatedBy: "\"ui\"").count - 1 == 1)
        #expect(saved.contains("\"surfaceTabBar\""))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == "layout")
    }

    @Test func unsetNewWorkspaceDefaultActionRemovesKeyAndIsIdempotent() throws {
        let root = try temporaryRoot("default-remove")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          // ui note
          "ui": {
            "newWorkspace": {
              "contextMenu": ["bree.newTerminal"], // keep menu
              "action": "layout"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: nil, globalConfigPath: configPath)
        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// ui note"))
        #expect(saved.contains("// keep menu"))
        #expect(!saved.contains("\"action\": \"layout\""))
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == nil)

        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: nil, globalConfigPath: configPath)
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == saved)
    }

    @Test func setNewWorkspaceDefaultActionFailsClosedForMalformedConfig() throws {
        let root = try temporaryRoot("default-fail-closed")
        defer { try? FileManager.default.removeItem(at: root) }
        let brokenPath = root.appendingPathComponent("broken.json").path
        let broken = "{ \"ui\": tru }\n"
        try broken.write(toFile: brokenPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: brokenPath)
        }
        #expect(try String(contentsOfFile: brokenPath, encoding: .utf8) == broken)

        let nonObjectPath = root.appendingPathComponent("non-object.json").path
        let nonObject = "{\n  \"ui\": \"not an object\"\n}\n"
        try nonObject.write(toFile: nonObjectPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try BreeConfigActionSaver.setNewWorkspaceDefaultAction(id: "layout", globalConfigPath: nonObjectPath)
        }
        #expect(try String(contentsOfFile: nonObjectPath, encoding: .utf8) == nonObject)
    }

    @Test func saveWorkspaceActionThenSetAsDefaultResolvesNewID() throws {
        let root = try temporaryRoot("save-then-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path

        let result = try BreeConfigActionSaver.saveWorkspaceAction(
            title: "Review Setup",
            definition: BreeWorkspaceDefinition(name: "Review"),
            globalConfigPath: configPath
        )
        try BreeConfigActionSaver.setNewWorkspaceDefaultAction(
            id: result.actionID,
            globalConfigPath: configPath
        )

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let config = try decodeJSONC(saved)
        #expect(config.ui?.newWorkspace?.action == result.actionID)
    }

    @Test func newWorkspaceDefaultLayoutMenuModelBuildsSortedState() throws {
        let zebra = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "zebra",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Zebra"), restart: nil),
                title: "Zebra"
            ),
            sourcePath: nil
        ))
        let alphaTwo = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "alpha-2",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Alpha"), restart: nil),
                title: "Alpha"
            ),
            sourcePath: nil
        ))
        let alphaOne = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "alpha-1",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Alpha"), restart: nil),
                title: "Alpha"
            ),
            sourcePath: nil
        ))

        let none = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: nil
        )
        #expect(none.entries.map(\.id) == ["alpha-1", "alpha-2", "zebra"])
        #expect(none.entries.allSatisfy { !$0.isCurrent })
        #expect(!none.hasDefault)

        let current = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: "alpha-2"
        )
        #expect(current.hasDefault)
        #expect(current.entries.map(\.id) == ["alpha-1", "alpha-2", "zebra"])
        #expect(current.entries.map(\.isCurrent) == [false, true, false])

        let dangling = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [zebra, alphaTwo, alphaOne],
            newWorkspaceActionID: "missing"
        )
        #expect(dangling.hasDefault)
        #expect(dangling.entries.allSatisfy { !$0.isCurrent })
    }

    @Test func newWorkspaceDefaultLayoutMenuModelListsOnlyWorkspaceLayouts() throws {
        let layout = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "layout",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Layout"), restart: nil),
                title: "Layout"
            ),
            sourcePath: nil
        ))
        let workspaceCommand = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "ws-dev",
            definition: BreeConfigActionDefinition(
                action: .workspaceCommand("dev"),
                title: "Dev"
            ),
            sourcePath: nil
        ))
        let commandAction = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "claudia",
            definition: BreeConfigActionDefinition(
                action: .command("claudia"),
                title: "claudia"
            ),
            sourcePath: nil
        ))
        let builtIn = BreeResolvedConfigAction.builtIn(.splitRight)

        let model = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [builtIn, commandAction, workspaceCommand, layout],
            newWorkspaceActionID: nil
        )
        #expect(model.entries.map(\.id) == ["ws-dev", "layout"])

        // A hand-edited default pointing at a non-layout action still
        // surfaces, checked, so the submenu reflects the real state.
        let handEdited = NewWorkspaceDefaultLayoutMenuModel.build(
            loadedActions: [builtIn, commandAction, workspaceCommand, layout],
            newWorkspaceActionID: "claudia"
        )
        #expect(handEdited.hasDefault)
        #expect(handEdited.entries.map(\.id) == ["ws-dev", "layout", "claudia"])
        #expect(handEdited.entries.map(\.isCurrent) == [false, false, true])
    }

    @Test func deleteActionClearsMatchingNewWorkspaceDefault() throws {
        let root = try temporaryRoot("delete-clears-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          // saved layouts
          "actions": {
            "review-setup": {
              "type": "workspace",
              "title": "Review Setup",
              "workspace": { "name": "Review" }
            },
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": ["bree.newTerminal"], // keep menu
              "action": "review-setup"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "review-setup", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// saved layouts"))
        #expect(saved.contains("// keep menu"))
        let config = try decodeJSONC(saved)
        #expect(config.actions["review-setup"] == nil)
        #expect(config.actions["dev-setup"] != nil)
        #expect(config.ui?.newWorkspace?.action == nil)
    }

    @Test func deleteActionKeepsUnrelatedNewWorkspaceDefault() throws {
        let root = try temporaryRoot("delete-keeps-default")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "actions": {
            "review-setup": {
              "type": "workspace",
              "title": "Review Setup",
              "workspace": { "name": "Review" }
            },
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          },
          "ui": {
            "newWorkspace": {
              "action": "dev-setup"
            }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "review-setup", globalConfigPath: configPath)

        let config = try decodeJSONC(try String(contentsOfFile: configPath, encoding: .utf8))
        #expect(config.actions["review-setup"] == nil)
        #expect(config.ui?.newWorkspace?.action == "dev-setup")
    }
}
