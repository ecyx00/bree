import BreeSurfaceCatalogModel
import Foundation
import Testing
import BreeSettings

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// A @MainActor Swift Testing body already runs inside a main queue block, so
/// the main queue cannot drain until the test returns and every
/// `drainMainQueue` call spins the run loop until its timeout. Spin briefly.
private let mainActorTestMainQueueSpin: TimeInterval = 0.1

@MainActor
@Suite(.serialized)
struct LastSurfaceClosePreferenceTests {
    private func drainMainQueueForCloseTest(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        } while Date() < deadline
    }
    private let closeWorkspaceOnLastSurfaceKey = "closeWorkspaceOnLastSurfaceShortcut"

    @Test
    func tabCloseButtonClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId) == false)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func tabCloseButtonKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            var didClose = false
            secondWorkspace.withClosedPanelHistorySuppressed {
                secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
                didClose = secondWorkspace.closePanel(secondPanelId)
            }
            #expect(didClose)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func middleClickClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.markTabStripMiddleClickClose(surfaceId: secondSurfaceId)
            #expect(secondWorkspace.closePanel(secondPanelId) == false)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func middleClickKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            var didClose = false
            secondWorkspace.withClosedPanelHistorySuppressed {
                secondWorkspace.markTabStripMiddleClickClose(surfaceId: secondSurfaceId)
                didClose = secondWorkspace.closePanel(secondPanelId)
            }
            #expect(didClose)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseClosesWorkspaceWhenKeepWorkspaceOpenPreferenceIsDisabled() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            #expect(secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func remoteTmuxWindowCloseKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxSessionEndKeepsWorkspaceOpenWhenKeepWorkspaceOpenPreferenceIsEnabled() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            secondWorkspace.markTabCloseButtonClose(surfaceId: secondSurfaceId)
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseKeepsWorkspaceOpenImmediatelyForShortcut() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            secondWorkspace.markCloseHistoryEligible(panelId: secondPanelId)
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: false,
                tabCloseButton: false
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [firstWorkspace.id, secondWorkspace.id])
            #expect(manager.selectedTabId == secondWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.focusedPanelId != secondPanelId)
        }
    }

    @Test
    func remoteTmuxWindowCloseClearsKeepOpenMarkerWhenWorkspaceNoLongerEmpty() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let closingPanelId = try #require(secondWorkspace.focusedPanelId)
            let closingSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(closingPanelId))

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(!secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: closingSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            let remainingPanel = try #require(secondWorkspace.createReplacementTerminalPanel())
            #expect(secondWorkspace.closePanel(closingPanelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(secondWorkspace.panels[closingPanelId] == nil)
            #expect(secondWorkspace.panels[remainingPanel.id] != nil)
            #expect(secondWorkspace.panels.count == 1)
            #expect(secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
        }
    }

    @Test
    func remoteTmuxWindowCloseDoesNotPromptAgainAfterRemoteCloseCommitted() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let firstWorkspace = manager.tabs[0]
            let secondWorkspace = manager.addWorkspace()
            manager.selectWorkspace(secondWorkspace)

            let secondPanelId = try #require(secondWorkspace.focusedPanelId)
            let secondSurfaceId = try #require(secondWorkspace.surfaceIdFromPanelId(secondPanelId))
            let catalog = AppCatalogSection()
            manager.closeTabWarningDefaults.set(true, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
            var confirmationCount = 0
            manager.confirmCloseHandler = { _, _, _ in
                confirmationCount += 1
                return false
            }

            secondWorkspace.isRemoteTmuxMirror = true
            #expect(secondWorkspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: secondSurfaceId,
                tabStripClose: true,
                tabCloseButton: true
            ))
            #expect(secondWorkspace.closePanel(secondPanelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(confirmationCount == 0)
            #expect(manager.tabs.map(\.id) == [firstWorkspace.id])
            #expect(manager.selectedTabId == firstWorkspace.id)
            #expect(!secondWorkspace.isRemoteTmuxMirror)
            #expect(!secondWorkspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
            #expect(secondWorkspace.panels[secondPanelId] == nil)
            #expect(secondWorkspace.panels.isEmpty)
        }
    }

    @Test
    func remoteTmuxWindowCloseCreatesReplacementWhenOnlyMainWindowWouldBeEmpty() throws {
        try withManager(closeWorkspaceOnLastSurface: true) { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let surfaceId = try #require(workspace.surfaceIdFromPanelId(panelId))

            workspace.isRemoteTmuxMirror = true
            #expect(workspace.markRemoteTmuxWorkspaceCloseAfterWindowCloseIfNeeded(
                surfaceId: surfaceId,
                tabStripClose: true,
                tabCloseButton: true,
                explicitUserClose: true
            ))
            #expect(workspace.closePanel(panelId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(manager.tabs.map(\.id) == [workspace.id])
            #expect(workspace.panels[panelId] == nil)
            #expect(!workspace.isRemoteTmuxMirror)
            #expect(workspace.panels.count == 1)
            #expect(workspace.focusedPanelId != panelId)
            #expect(!workspace.handleRemoteTmuxSessionEndedKeepingWorkspaceOpenIfNeeded())
        }
    }

    @Test
    func reopeningAClosedPanelRestoresMixedSplitTopology() throws {
        try withManager(closeWorkspaceOnLastSurface: false) { manager in
            let workspace = try #require(manager.selectedWorkspace)
            let focusedPanelId = try #require(workspace.focusedPanelId)
            let browserId = try #require(manager.newBrowserSplit(
                tabId: workspace.id,
                fromPanelId: focusedPanelId,
                orientation: .horizontal,
                url: URL(string: "https://example.com/closed-mixed-split")
            ))
            let browserPane = try #require(workspace.paneId(forPanelId: browserId))
            let terminalId = try #require(workspace.newTerminalSurface(inPane: browserPane, focus: true)?.id)
            let originalOrientation: String = {
                guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else { return "" }
                return split.orientation
            }()

            workspace.markCloseHistoryEligible(panelId: terminalId)
            #expect(workspace.closePanel(terminalId, force: true))
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)
            #expect(manager.reopenMostRecentlyClosedItem())
            drainMainQueueForCloseTest(timeout: mainActorTestMainQueueSpin)

            #expect(workspace.bonsplitController.allPaneIds.count == 2)
            #expect(workspace.panels.values.contains { $0 is BrowserPanel })
            #expect(workspace.panels.values.contains { $0 is TerminalPanel })
            let restoredTerminalId = try #require(workspace.panels.first { panelId, panel in
                panel is TerminalPanel && panelId != focusedPanelId
            }?.key)
            #expect(workspace.paneId(forPanelId: restoredTerminalId) == workspace.paneId(forPanelId: browserId))
            let restoredOrientation: String = {
                guard case .split(let split) = workspace.bonsplitController.treeSnapshot() else { return "" }
                return split.orientation
            }()
            #expect(restoredOrientation == originalOrientation)
        }
    }

    private func withManager(
        closeWorkspaceOnLastSurface: Bool,
        run: (TabManager) throws -> Void
    ) throws {
        let suiteName = "LastSurfaceClosePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(closeWorkspaceOnLastSurface, forKey: closeWorkspaceOnLastSurfaceKey)
        let settings = UserDefaultsSettingsClient(defaults: defaults)
        let catalog = AppCatalogSection()
        ClosedItemHistoryStore.shared.removeAll()
        defaults.set(false, forKey: catalog.warnBeforeClosingTab.userDefaultsKey)
        defaults.set(false, forKey: catalog.warnBeforeClosingTabXButton.userDefaultsKey)
        defer {
            ClosedItemHistoryStore.shared.removeAll()
        }
        let manager = TabManager(settings: settings, closeTabWarningDefaults: defaults)
        defer { manager.finalizeAllWorkspacesForWindowClose() }
        try run(manager)
    }
}
