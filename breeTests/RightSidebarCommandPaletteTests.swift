import BreeCommandPalette
import Foundation
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class RightSidebarCommandPaletteTests: XCTestCase {
    @MainActor
    func testCommandPaletteOffersToggleBottomPanel() throws {
        let contributions = ContentView.commandPaletteBottomPanelCommandContributions()
        let contribution = try XCTUnwrap(contributions.first { $0.commandId == "palette.toggleBottomPanel" })
        let context = CommandPaletteContextSnapshot()
        XCTAssertEqual(contribution.title(context), String(localized: "command.toggleBottomPanel.title", defaultValue: "Toggle Panel"))
        XCTAssertTrue(contribution.when(context))
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleBottomPanel"),
            .toggleBottomPanel
        )
    }

    func testRightSidebarModesNoLongerIncludeDock() {
        XCTAssertNil(RightSidebarMode(rawValue: "dock"))
    }

    @MainActor
    func testCommandPaletteIncludesDefaultRightSidebarModes() throws {
        try withSavedBetaFeatureDefaults {
            let defaults = UserDefaults.standard
            defaults.removeObject(forKey: "rightSidebar.beta.dock.enabled")
            // Cloud Machines defaults on in dev builds (d6584c07e0); pin the toggle off so
            // the default-mode contract below is the same on every build.
            defaults.set(false, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
            let cloudFlag = BreeFeatureFlags.cloudMachinesFlag
            let previousCloudOverride = BreeFeatureFlags.shared.overrideValue(for: cloudFlag)
            BreeFeatureFlags.shared.setOverride(true, for: cloudFlag)
            defer { BreeFeatureFlags.shared.setOverride(previousCloudOverride, for: cloudFlag) }
            let contributions = ContentView.commandPaletteRightSidebarModeCommandContributions()
            let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
            let context = CommandPaletteContextSnapshot()

            for mode in RightSidebarMode.availableModes() {
                let commandID = ContentView.commandPaletteRightSidebarModeCommandID(mode)
                let contribution = try XCTUnwrap(
                    contributionsByID[commandID],
                    "Expected command palette contribution for \(mode.rawValue)"
                )

                XCTAssertEqual(contribution.title(context), mode.shortcutAction?.label ?? mode.label)
                XCTAssertEqual(
                    contribution.subtitle(context),
                    String(localized: "command.rightSidebarMode.subtitle", defaultValue: "Right Sidebar")
                )
                XCTAssertTrue(contribution.keywords.contains("right"))
                XCTAssertTrue(contribution.keywords.contains("sidebar"))
                XCTAssertTrue(contribution.keywords.contains(mode.rawValue))
                XCTAssertTrue(contribution.when(context))
                XCTAssertTrue(contribution.enablement(context))
            }

            // Files/Sessions/Activity/Architecture are discoverable.
            XCTAssertEqual(contributions.count, 4)
            XCTAssertNotNil(contributionsByID[ContentView.commandPaletteRightSidebarModeCommandID(.activity)])
        }
    }

    @MainActor
    func testCommandPaletteRightSidebarActionsUseModeShortcutActions() {
        withSavedBetaFeatureDefaults {
            let definition = BreeFeatureFlags.cloudMachinesFlag
            let previousOverride = BreeFeatureFlags.shared.overrideValue(for: definition)
            BreeFeatureFlags.shared.setOverride(true, for: definition)
            defer { BreeFeatureFlags.shared.setOverride(previousOverride, for: definition) }
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)

            for mode in RightSidebarMode.allCases {
                XCTAssertEqual(
                    ContentView.commandPaletteShortcutAction(
                        forCommandID: ContentView.commandPaletteRightSidebarModeCommandID(mode)
                    ),
                    mode.shortcutAction
                )
            }
        }
    }

    func testCommandPaletteUnreadActionsUseConfigurableShortcutActions() {
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.toggleUnread"),
            .toggleUnread
        )
        XCTAssertEqual(
            ContentView.commandPaletteShortcutAction(forCommandID: "palette.markOldestUnreadAndJumpNext"),
            .markOldestUnreadAndJumpNext
        )
    }

    func testCopyModeVisibilityFollowsTheTerminalTheShortcutWouldHit() {
        // Dock owns focus: its focused panel decides, whatever the main area holds.
        XCTAssertTrue(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: true,
            mainAreaPanelIsTerminal: false
        ))
        XCTAssertFalse(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: false,
            mainAreaPanelIsTerminal: true
        ))
        // Main area owns focus.
        XCTAssertTrue(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: nil,
            mainAreaPanelIsTerminal: true
        ))
        XCTAssertFalse(ContentView.commandPaletteShortcutTerminalFocused(
            focusedDockPanelIsTerminal: nil,
            mainAreaPanelIsTerminal: false
        ))
    }

    func testCopyModeRestoresFocusToTheFocusedDockTerminal() {
        XCTAssertTrue(ContentView.commandPalettePostRunFocusFollowsFocusedDock(
            forCommandId: ShortcutParityPaletteCommand.toggleTerminalCopyMode.rawValue
        ))
        // Text box commands act on the main-area terminal, so their restore stays there.
        XCTAssertFalse(ContentView.commandPalettePostRunFocusFollowsFocusedDock(
            forCommandId: "palette.terminalFocusTextBoxInput"
        ))
    }

    @MainActor
    func testShortcutOnlyActionsHavePaletteCommandsLabeledAndBoundLikeTheirShortcuts() throws {
        let contributions = ContentView.commandPaletteShortcutParityContributions(
            workspaceSubtitle: { _ in "workspace" },
            terminalSubtitle: { _ in "terminal" },
            browserSubtitle: { _ in "browser" }
        )
        let contributionsByID = Dictionary(uniqueKeysWithValues: contributions.map { ($0.commandId, $0) })
        XCTAssertEqual(contributions.count, ShortcutParityPaletteCommand.allCases.count)

        var terminalContext = CommandPaletteContextSnapshot()
        terminalContext.setBool(ContentView.commandPaletteShortcutTerminalFocusedKey, true)
        var browserContext = CommandPaletteContextSnapshot()
        browserContext.setBool(CommandPaletteContextKeys.panelIsBrowser, true)
        var workspaceContext = CommandPaletteContextSnapshot()
        workspaceContext.setBool(CommandPaletteContextKeys.hasWorkspace, true)
        var splitsContext = CommandPaletteContextSnapshot()
        splitsContext.setBool(CommandPaletteContextKeys.workspaceHasSplits, true)
        let emptyContext = CommandPaletteContextSnapshot()

        for command in ShortcutParityPaletteCommand.allCases {
            let contribution = try XCTUnwrap(contributionsByID[command.rawValue], command.rawValue)
            XCTAssertEqual(contribution.title(emptyContext), command.shortcutAction.label)
            XCTAssertEqual(
                ContentView.commandPaletteShortcutAction(forCommandID: command.rawValue),
                command.shortcutAction
            )
            XCTAssertFalse(contribution.when(emptyContext), command.rawValue)
            let visibleContext: CommandPaletteContextSnapshot = switch command.scope {
            case .terminal: terminalContext
            case .browser: browserContext
            case .workspace: workspaceContext
            case .splits: splitsContext
            }
            XCTAssertTrue(contribution.when(visibleContext), command.rawValue)
        }

        let covered = Set(ShortcutParityPaletteCommand.allCases.map(\.shortcutAction))
        for action: KeyboardShortcutSettings.Action in [
            .toggleTerminalCopyMode,
            .increaseWorkspaceTerminalFontSize,
            .decreaseWorkspaceTerminalFontSize,
            .resetWorkspaceTerminalFontSize,
            .focusLeft, .focusRight, .focusUp, .focusDown,
            .focusPreviousPane, .focusNextPane,
            .groupSelectedWorkspaces,
            .toggleFocusedWorkspaceGroupCollapsed,
            .browserHardReload,
        ] {
            XCTAssertTrue(covered.contains(action), action.rawValue)
        }
    }

    @MainActor
    func testBrowserHardReloadPaletteCommandDispatchesHardReload() {
        var dispatched: [BrowserAction] = []
        let handled = ContentView.performShortcutParityCommand(
            .browserHardReload,
            performBrowserAction: { action in
                dispatched.append(action)
                return true
            },
            preferredWindow: nil
        )
        XCTAssertTrue(handled)
        XCTAssertEqual(dispatched.count, 1)
        guard case .hardReload = dispatched.first else {
            return XCTFail("expected .hardReload, got \(String(describing: dispatched.first))")
        }
    }

    @MainActor
    func testPaletteAndShortcutPaneFocusCycleSharesMainAreaPath() throws {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let initialPanelID = try XCTUnwrap(workspace.focusedPanelId)
        XCTAssertNotNil(workspace.newTerminalSplit(from: initialPanelID, orientation: .horizontal, focus: false))
        let initialPaneID = workspace.bonsplitController.focusedPaneId

        XCTAssertTrue(AppDelegate.moveMainAreaPaneFocus(.next, tabManager: manager, window: nil))
        let movedPaneID = workspace.bonsplitController.focusedPaneId
        XCTAssertNotEqual(movedPaneID, initialPaneID)

        XCTAssertTrue(AppDelegate.moveMainAreaPaneFocus(.previous, tabManager: manager, window: nil))
        XCTAssertEqual(workspace.bonsplitController.focusedPaneId, initialPaneID)

        XCTAssertFalse(AppDelegate.moveMainAreaPaneFocus(.next, tabManager: nil, window: nil))
    }

    private func withSavedBetaFeatureDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let previousLegacyDockBeta = defaults.object(forKey: "rightSidebar.beta.dock.enabled")
        let previousCloudMachines = defaults.object(forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        defer {
            restore(previousLegacyDockBeta, forKey: "rightSidebar.beta.dock.enabled")
            restore(previousCloudMachines, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        }
        try body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
