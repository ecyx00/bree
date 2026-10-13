import AppKit
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Plus-button menu resolution: auto-append of workspace actions, opt-in/out,
/// validation of workspaceCommand references, and de-duplication.
@Suite(.serialized)
struct BreeConfigNewWorkspaceMenuTests {

    // MARK: - Store: plus-button menu auto-append

    @MainActor
    private func loadStore(globalJSON: String) throws -> (store: BreeConfigStore, root: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bree-workspace-action-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let globalConfigURL = root.appendingPathComponent("bree.json")
        try globalJSON.write(to: globalConfigURL, atomically: true, encoding: .utf8)
        let store = BreeConfigStore(
            globalConfigPath: globalConfigURL.path,
            localConfigPath: nil,
            startFileWatchers: false
        )
        store.loadAll()
        return (store, root)
    }

    @MainActor
    private func menuActionIDs(_ store: BreeConfigStore) -> [String] {
        store.newWorkspaceContextMenuItems.compactMap { item in
            if case .action(let menuAction) = item {
                return menuAction.action.id
            }
            return nil
        }
    }

    @MainActor
    private func contextMenuActionIDs(_ menu: NSMenu) -> [String] {
        menu.items.compactMap { item in
            (item.representedObject as? NewWorkspaceContextMenuActionBox)?.action.id
        }
    }

    @MainActor
    private func contextMenuActionID(_ item: NSMenuItem) -> String? {
        (item.representedObject as? NewWorkspaceContextMenuActionBox)?.action.id
    }

    @MainActor
    private func firstContextMenuIndex(_ menu: NSMenu, actionID: String) -> Int? {
        menu.items.firstIndex { contextMenuActionID($0) == actionID }
    }

    @MainActor
    private func allMenuItemTitles(_ menu: NSMenu) -> [String] {
        menu.items.flatMap { item -> [String] in
            [item.title] + (item.submenu.map(allMenuItemTitles) ?? [])
        }
    }

    private func twoLayoutConfig(defaultActionID: String? = nil) -> String {
        let defaultBlock = defaultActionID.map {
            """
            ,
              "ui": { "newWorkspace": { "action": "\($0)" } }
            """
        } ?? ""
        return """
        {
          "actions": {
            "review-layout": {
              "type": "workspace",
              "title": "Review Layout",
              "workspace": { "name": "Review" }
            },
            "dev-layout": {
              "type": "workspace",
              "title": "Dev Layout",
              "workspace": { "name": "Dev" }
            }
          }\(defaultBlock)
        }
        """
    }

    @MainActor
    private func withNewWorkspaceContextMenu<T>(
        store: BreeConfigStore,
        _ body: (NSMenu) throws -> T
    ) throws -> T {
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(
            tabManager: tabManager,
            breeConfigStore: store
        )
        defer { appDelegate.unregisterMainWindowContextForTesting(windowId: windowId) }
        let context = try #require(appDelegate.mainWindowContexts.values.first { $0.windowId == windowId })
        let menu = try #require(appDelegate.makeNewWorkspaceContextMenu(
            context: context,
            breeConfigStore: store
        ))
        return try body(menu)
    }

    @MainActor
    @Test func storeAutoAppendsWorkspaceActionsToPlusButtonMenu() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(ids.contains("dev-setup"), "workspace action should be auto-offered, got \(ids)")
        // Defaults stay first.
        #expect(ids.first == BreeSurfaceTabBarBuiltInAction.newWorkspace.configID)
        // Auto block is separated from the configured items.
        if case .separator? = store.newWorkspaceContextMenuItems.dropLast().last {} else {
            Issue.record("Expected separator before auto-appended actions")
        }
    }

    @MainActor
    @Test func renderedContextMenuGroupsCreateLayoutsAndManagementTail() throws {
        let (store, root) = try loadStore(globalJSON: twoLayoutConfig(defaultActionID: "review-layout"))
        defer { try? FileManager.default.removeItem(at: root) }

        try withNewWorkspaceContextMenu(store: store) { menu in
            let layoutsHeader = String(localized: "menu.newWorkspace.layoutsHeader", defaultValue: "Layouts")
            let headerIndex = try #require(menu.items.firstIndex { $0.title == layoutsHeader })
            let saveTitle = String(localized: "menu.newWorkspace.saveWorkspaceAsLayout", defaultValue: "Save Workspace as Layout…")
            let saveIndex = try #require(menu.items.firstIndex { $0.title == saveTitle })
            let newWorkspaceIndex = try #require(firstContextMenuIndex(menu, actionID: BreeSurfaceTabBarBuiltInAction.newWorkspace.configID))
            let reviewIndex = try #require(firstContextMenuIndex(menu, actionID: "review-layout"))
            let devIndex = try #require(firstContextMenuIndex(menu, actionID: "dev-layout"))

            #expect(newWorkspaceIndex < headerIndex)
            #expect(headerIndex < reviewIndex)
            #expect(headerIndex < devIndex)
            #expect(reviewIndex < saveIndex)
            #expect(devIndex < saveIndex)
            let layoutRange = (headerIndex + 1)..<saveIndex
            let nonLayoutIDs = menu.items[layoutRange].compactMap(contextMenuActionID).filter {
                $0 != "review-layout" && $0 != "dev-layout"
            }
            #expect(nonLayoutIDs.isEmpty)
        }
    }

    @MainActor
    @Test func renderedContextMenuDefaultBadgeMovesWhenDefaultChanges() throws {
        let (store, root) = try loadStore(globalJSON: twoLayoutConfig(defaultActionID: "review-layout"))
        defer { try? FileManager.default.removeItem(at: root) }

        try withNewWorkspaceContextMenu(store: store) { menu in
            let review = try #require(menu.items.first { contextMenuActionID($0) == "review-layout" })
            let dev = try #require(menu.items.first { contextMenuActionID($0) == "dev-layout" })
            #expect(review.badge != nil)
            #expect(dev.badge == nil)
        }

        try twoLayoutConfig(defaultActionID: "dev-layout")
            .write(to: root.appendingPathComponent("bree.json"), atomically: true, encoding: .utf8)
        store.loadAll()

        try withNewWorkspaceContextMenu(store: store) { menu in
            let review = try #require(menu.items.first { contextMenuActionID($0) == "review-layout" })
            let dev = try #require(menu.items.first { contextMenuActionID($0) == "dev-layout" })
            #expect(review.badge == nil)
            #expect(dev.badge != nil)
        }
    }

    @MainActor
    @Test func renderedContextMenuRemovesCustomizeAndPreservesDeleteAlternates() throws {
        let (store, root) = try loadStore(globalJSON: twoLayoutConfig())
        defer { try? FileManager.default.removeItem(at: root) }

        try withNewWorkspaceContextMenu(store: store) { menu in
            #expect(!allMenuItemTitles(menu).contains("Customize Workspace Layouts…"))
            for actionID in ["review-layout", "dev-layout"] {
                let index = try #require(firstContextMenuIndex(menu, actionID: actionID))
                let alternate = try #require(menu.items.dropFirst(index + 1).first)
                #expect(alternate.isAlternate)
                #expect(alternate.keyEquivalentModifierMask.contains(.option))
                #expect(alternate.representedObject is WorkspaceActionDeleteBox)
            }
        }
    }

    @MainActor
    @Test func renderedContextMenuManagementTailIsSaveAndManageLayouts() throws {
        let (store, root) = try loadStore(globalJSON: twoLayoutConfig(defaultActionID: "review-layout"))
        defer { try? FileManager.default.removeItem(at: root) }

        try withNewWorkspaceContextMenu(store: store) { menu in
            let nonSeparators = menu.items.filter { !$0.isSeparatorItem }
            let save = try #require(nonSeparators.dropLast(2).last)
            let manage = try #require(nonSeparators.dropLast().last)
            let actions = try #require(nonSeparators.last)
            #expect(save.title == String(localized: "menu.newWorkspace.saveWorkspaceAsLayout", defaultValue: "Save Workspace as Layout…"))
            #expect(manage.title == String(localized: "menu.newWorkspace.manageLayouts", defaultValue: "Manage Layouts"))
            #expect(actions.title == AppDelegate.actionsAndLaunchersMenuTitle)
            #expect(actions.action == Selector(("presentActionsAndLaunchersMenuItem:")))
            let submenu = try #require(manage.submenu)
            #expect(submenu.items.contains { $0.title == String(localized: "menu.newWorkspace.defaultLayoutSubmenu", defaultValue: "Default for New Workspace") })
            let none = try #require(submenu.items.first {
                $0.representedObject is WorkspaceDefaultLayoutBox && $0.title == String(localized: "menu.newWorkspace.defaultLayoutNone", defaultValue: "None (Blank Terminal)")
            })
            // The current default is marked with a trailing "Default" badge,
            // never a leading checkmark (the state column misaligns titles
            // against icon-bearing rows).
            #expect(none.badge == nil)
            #expect(none.image != nil)
            let reviewDefault = try #require(submenu.items.first {
                ($0.representedObject as? WorkspaceDefaultLayoutBox)?.actionID == "review-layout"
            })
            #expect(reviewDefault.badge != nil)
            #expect(submenu.items.allSatisfy { $0.state == .off })
            #expect(submenu.items.contains { $0.title == String(localized: "menu.newWorkspace.deleteLayoutSubmenu", defaultValue: "Delete Workspace Layout") })
            let deleteIDs = submenu.items.compactMap { ($0.representedObject as? WorkspaceActionDeleteBox)?.actionID }
            #expect(deleteIDs == ["dev-layout", "review-layout"])
            #expect(submenu.items.allSatisfy { $0.submenu == nil })
        }
    }

    @MainActor
    @Test func storeRespectsNewWorkspaceMenuOptOut() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "hidden": {
              "type": "workspace",
              "title": "Hidden",
              "newWorkspaceMenu": false,
              "workspace": { "name": "Hidden" }
            },
            "shown-command": {
              "type": "command",
              "title": "Shown",
              "command": "make",
              "newWorkspaceMenu": true
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(!ids.contains("hidden"))
        #expect(ids.contains("shown-command"))
    }

    @MainActor
    @Test func storeValidatesAutoAppendedWorkspaceCommandActions() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dead-ref": {
              "type": "workspaceCommand",
              "commandName": "No Such Command",
              "newWorkspaceMenu": true
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!menuActionIDs(store).contains("dead-ref"))
        #expect(
            store.configurationIssues.contains { $0.commandName == "No Such Command" },
            "a dead workspaceCommand reference must surface as a config issue"
        )
    }

    @MainActor
    @Test func storeDoesNotDuplicateExplicitMenuEntries() throws {
        let (store, root) = try loadStore(globalJSON: """
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "workspace": { "name": "Dev" }
            }
          },
          "ui": {
            "newWorkspace": {
              "contextMenu": ["dev-setup"]
            }
          }
        }
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let ids = menuActionIDs(store)
        #expect(ids.filter { $0 == "dev-setup" }.count == 1)
    }
}
