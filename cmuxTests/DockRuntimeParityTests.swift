import AppKit
import Bonsplit
import Combine
import CmuxControlSocket
import CmuxFoundation
import CmuxNotifications
import CmuxTerminal
import Foundation
import Observation
import os
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
private final class DockRuntimeParityPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal
    let displayTitle: String
    let displayIcon: String? = "terminal.fill"
    var isDirty = false

    private(set) var flashReasons: [WorkspaceAttentionFlashReason] = []
    private(set) var closeCount = 0
    private(set) var focusCount = 0

    init(id: UUID = UUID(), title: String) {
        self.id = id
        displayTitle = title
    }

    func close() {
        closeCount += 1
    }
    func focus() {
        focusCount += 1
    }
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        flashReasons.append(reason)
    }
}

@MainActor
private final class DockRuntimeParityUnreadObserver {
    var publicationCount = 0
    var totalUnreadCounts: [Int] = []
}

@MainActor
private extension DockSplitStore {
    @discardableResult
    func seedRuntimeParityPanel(_ panel: any Panel) throws -> PaneID {
        let pane = try #require(bonsplitController.allPaneIds.first)
        panels[panel.id] = panel
        let tabID = try #require(
            bonsplitController.createTab(
                title: panel.displayTitle,
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: panel.isDirty,
                inPane: pane
            )
        )
        bindSurface(tabID, toPanelId: panel.id)
        installAttentionRouting(for: panel)
        return pane
    }
}

@MainActor
@Suite("Dock runtime parity", .serialized)
struct DockRuntimeParityTests {
    private static let socketWorker = DispatchQueue(label: "DockRuntimeParityTests.socketWorker")

    @Test("Conversations reuses a live Dock terminal")
    func conversationReusesLiveDockTerminal() async throws {
        try await withAppContext { app, manager, workspace, windowID in
            let dock = try #require(workspace.dockSplit)
            let terminal = TerminalPanel(
                workspaceId: dock.workspaceId,
                runtimeSpawnPolicy: .pacedSessionRestore
            )
            try dock.seedRuntimeParityPanel(terminal)
            let other = DockRuntimeParityPanel(title: "Other terminal")
            try dock.seedRuntimeParityPanel(other)
            dock.focusPanel(other.id)
            let sessionID = UUID().uuidString
            dock.restoredAgentLifecycle.setSnapshot(
                SessionRestorableAgentSnapshot(
                    kind: .claude, sessionId: sessionID, workingDirectory: "/tmp", launchCommand: nil
                ),
                panelId: terminal.id
            )
            terminal.updateShellActivityState(.commandRunning)
            let entry = SessionEntry(
                id: "claude:\(sessionID)", agent: .claude, sessionId: sessionID,
                title: "Dock conversation", cwd: "/tmp", gitBranch: nil,
                pullRequest: nil, modified: Date(), fileURL: nil,
                specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil)
            )
            let workspaceCount = manager.tabs.count
            let mainPanelCount = workspace.panels.count
            let dockPanelCount = dock.panels.count
            let target = try #require(SessionEntryResumeCoordinator.activeTarget(
                for: entry, tabManager: manager, schedulingIndexRefresh: false
            ))
            guard case .dock(let panelID) = target else {
                Issue.record("Dock session was routed to the workspace split tree")
                return
            }
            #expect(panelID == terminal.id)
            #expect(SessionEntryResumeCoordinator.focusIfActive(entry, tabManager: manager))
            #expect(dock.focusedPanelId == terminal.id)
            #expect(manager.tabs.count == workspaceCount)
            #expect(workspace.panels.count == mainPanelCount)
            #expect(dock.panels.count == dockPanelCount)
        }
    }

    @Test("Reconciling a stale tab alias preserves the live panel owner")
    func reconcilingStaleTabAliasPreservesLivePanelOwner() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Shared panel")
        let paneID = try dock.seedRuntimeParityPanel(panel)
        let liveTabID = try #require(dock.surfaceId(forPanelId: panel.id))
        let staleAliasID = try #require(
            dock.bonsplitController.createTab(
                title: "Stale alias",
                icon: panel.displayIcon,
                kind: panel.panelType.rawValue,
                isDirty: false,
                inPane: paneID
            )
        )
        // Seed only the stale forward alias; the live tab must remain the
        // authoritative reverse mapping for this fixture.
        dock.surfaceIdToPanelId[staleAliasID] = panel.id

        #expect(dock.bonsplitController.closeTab(staleAliasID))

        #expect(dock.panel(for: liveTabID) === panel)
        #expect(dock.surfaceId(forPanelId: panel.id) == liveTabID)
        #expect(dock.surfaceIdToPanelId[staleAliasID] == nil)
        #expect(panel.closeCount == 0)
    }

    @Test("Dock pane ownership follows split, close, and implicit move closure")
    func dockPaneOwnershipFollowsBonsplitLifecycle() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let otherDock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        // Every split below supplies its own tabs. Interactive split repair
        // would seed a terminal in the root and prevent its final empty close.
        dock.isProgrammaticDockSplit = true
        defer { dock.isProgrammaticDockSplit = false }
        let rootPane = try #require(dock.bonsplitController.allPaneIds.first)

        #expect(dock.containsPane(rootPane.id))
        #expect(!otherDock.containsPane(rootPane.id))
        #expect(DockSplitStore.liveStore(containingPane: rootPane.id) === dock)

        let closingTab = Bonsplit.Tab(title: "Closing tab")
        let closedPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: closingTab
            )
        )
        #expect(dock.containsPane(closedPane.id))
        #expect(DockSplitStore.liveStore(containingPane: closedPane.id) === dock)

        #expect(dock.bonsplitController.closeTab(closingTab.id))
        #expect(!dock.containsPane(closedPane.id))
        #expect(DockSplitStore.liveStore(containingPane: closedPane.id) == nil)

        let explicitlyClosedPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .horizontal,
                withTab: Bonsplit.Tab(title: "Explicitly closed pane")
            )
        )
        #expect(dock.bonsplitController.closePane(explicitlyClosedPane))
        #expect(!dock.containsPane(explicitlyClosedPane.id))

        let movingTab = try #require(
            dock.bonsplitController.createTab(
                title: "Moving tab",
                inPane: rootPane
            )
        )
        let destinationPane = try #require(
            dock.bonsplitController.splitPane(
                rootPane,
                orientation: .vertical,
                withTab: Bonsplit.Tab(title: "Destination tab")
            )
        )
        #expect(dock.bonsplitController.moveTab(movingTab, toPane: destinationPane))

        #expect(!dock.containsPane(rootPane.id))
        #expect(dock.containsPane(destinationPane.id))
        #expect(DockSplitStore.liveStore(containingPane: destinationPane.id) === dock)
    }

    private func socketEnvelope(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let raw = TerminalController.shared.handleSocketLine(line)
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketEnvelopeOnWorker(
        method: String,
        params: [String: Any] = [:]
    ) async throws -> [String: Any] {
        let request: [String: Any] = [
            "id": method,
            "method": method,
            "params": params,
        ]
        let data = try JSONSerialization.data(withJSONObject: request)
        let line = try #require(String(data: data, encoding: .utf8))
        let controller = TerminalController.shared
        let raw = await withCheckedContinuation { continuation in
            Self.socketWorker.async {
                continuation.resume(returning: controller.handleSocketLine(line))
            }
        }
        let responseData = try #require(raw.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
    }

    private func socketResult(
        method: String,
        params: [String: Any] = [:]
    ) throws -> [String: Any] {
        let envelope = try socketEnvelope(method: method, params: params)
        try #require(envelope["ok"] as? Bool == true, "\(envelope)")
        return try #require(envelope["result"] as? [String: Any])
    }

    private func waitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        for await _ in readiness { break }
    }

    private func withAppContext(
        fileExplorerState: FileExplorerState? = FileExplorerState(),
        _ body: @MainActor (AppDelegate, TabManager, Workspace, UUID) async throws -> Void
    ) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let appDelegate = AppDelegate()
            let manager = TabManager(autoWelcomeIfNeeded: false)
            AppDelegate.shared = appDelegate
            appDelegate.tabManager = manager
            TerminalController.shared.setActiveTabManager(manager)
            let windowID = UUID()
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowID.uuidString)")
            appDelegate.registerMainWindow(
                window,
                windowId: windowID,
                tabManager: manager,
                sidebarState: SidebarState(),
                sidebarSelectionState: SidebarSelectionState(),
                fileExplorerState: fileExplorerState
            )
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
                appDelegate.forgetRecoverableMainWindowRoute(windowId: windowID)
                manager.tabs.forEach { $0.teardownAllPanels() }
                window.orderOut(nil)
                window.close()
                AppDelegate.shared = previousAppDelegate
            }

            let workspace = try #require(manager.tabs.first)
            try await body(appDelegate, manager, workspace, windowID)
        }
    }

    @Test("Workspace panel unread invalidates only its keyed state")
    func workspacePanelUnreadInvalidatesOnlyItsKeyedState() async throws {
        try await withAppContext { _, _, workspace, _ in
            let panelID = try #require(workspace.focusedPanelId)
            let workspaceObserver = DockRuntimeParityUnreadObserver()
            let workspaceObservation = workspace.objectWillChange.sink {
                workspaceObserver.publicationCount += 1
            }
            let keyedInvalidationCount = OSAllocatedUnfairLock(initialState: 0)
            withObservationTracking {
                _ = workspace.manualUnreadPanelIds
            } onChange: {
                keyedInvalidationCount.withLock { $0 += 1 }
            }
            defer {
                workspaceObservation.cancel()
                workspace.clearManualUnread(panelId: panelID)
            }

            workspace.markPanelUnread(panelID)

            #expect(workspace.manualUnreadPanelIds == [panelID])
            #expect(keyedInvalidationCount.withLock { $0 } == 1)
            #expect(workspaceObserver.publicationCount == 0)
        }
    }

    @Test("Unavailable workspace Dock focus preserves window and workspace selection")
    func unavailableWorkspaceDockFocusPreservesWindowAndSelection() async throws {
        try await withAppContext { appDelegate, manager, selectedWorkspace, windowID in
            let targetWorkspace = manager.addWorkspace(title: "Dock focus target", select: false)
            let targetDock = try #require(targetWorkspace.dockSplit)
            let initiallyFocusedPanel = DockRuntimeParityPanel(title: "Initially focused")
            let targetPanel = DockRuntimeParityPanel(title: "Focus target")
            try targetDock.seedRuntimeParityPanel(initiallyFocusedPanel)
            try targetDock.seedRuntimeParityPanel(targetPanel)
            targetDock.focusPanel(initiallyFocusedPanel.id)

            let window = try #require(appDelegate.windowForMainWindowId(windowID))
            window.orderOut(nil)
            #expect(manager.selectedTabId == selectedWorkspace.id)
            #expect(targetDock.focusedPanelId == initiallyFocusedPanel.id)
            #expect(!window.isVisible)

            let envelope = try socketEnvelope(method: "surface.focus", params: [
                "workspace_id": targetWorkspace.id.uuidString,
                "surface_id": targetPanel.id.uuidString,
            ])

            #expect(envelope["ok"] as? Bool == false)
            let error = try #require(envelope["error"] as? [String: Any])
            #expect(error["code"] as? String == "unavailable")
            #expect(manager.selectedTabId == selectedWorkspace.id)
            #expect(targetDock.focusedPanelId == initiallyFocusedPanel.id)
            #expect(!window.isVisible)
        }
    }

}

@MainActor
@Suite("Dock notification attention", .serialized)
struct DockNotificationAttentionTests {
    @Test("Single-pane Dock attention bypasses workspace split gating")
    func singlePaneDockAttentionBypassesWorkspaceSplitGating() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Dock")
        try dock.seedRuntimeParityPanel(panel)

        let appDelegate = try #require(AppDelegate.shared, "Expected app-host AppDelegate")
        let routed = appDelegate.routeNotificationAttentionFlash(
            workspaceID: dock.workspaceId,
            panelID: panel.id,
            reason: .notificationArrival,
            requiresSplit: true
        )

        #expect(routed)
        #expect(panel.flashReasons == [.notificationArrival])
    }

    @Test("Dock unread projection is scoped to active Dock panels")
    func dockUnreadProjectionIsScopedToActiveDockPanels() {
        let workspaceID = UUID()
        let firstPanelID = UUID()
        let secondPanelID = UUID()
        let foreignPanelID = UUID()
        let unread = SidebarUnreadModel()
        let agentAttention = SurfaceAttentionModel()
        let projection = DockUnreadPanelProjection(
            source: unread,
            workspaceID: workspaceID,
            panelIDs: [firstPanelID, secondPanelID],
            isActive: true,
            agentAttentionSource: agentAttention
        )

        unread.apply(
            totalUnreadCount: 2,
            summaries: [:],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: firstPanelID),
                SidebarSurfaceUnreadKey(workspaceId: UUID(), surfaceId: foreignPanelID),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs == [firstPanelID])

        unread.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [],
            focusedReadIndicatorByWorkspaceId: [workspaceID: secondPanelID],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs == [secondPanelID])

        agentAttention.setAttention(true, forSurfaceId: firstPanelID)
        #expect(projection.unreadPanelIDs == [firstPanelID, secondPanelID])
        agentAttention.setAttention(false, forSurfaceId: firstPanelID)
        #expect(projection.unreadPanelIDs == [secondPanelID])

        projection.updateContext(
            panelIDs: [firstPanelID, secondPanelID],
            isActive: false
        )
        #expect(projection.unreadPanelIDs.isEmpty)

        unread.apply(
            totalUnreadCount: 1,
            summaries: [:],
            unreadSurfaceKeys: [
                SidebarSurfaceUnreadKey(workspaceId: workspaceID, surfaceId: firstPanelID),
            ],
            focusedReadIndicatorByWorkspaceId: [:],
            manualUnreadWorkspaceIds: []
        )
        #expect(projection.unreadPanelIDs.isEmpty)

        projection.updateContext(
            panelIDs: [firstPanelID, secondPanelID],
            isActive: true
        )
        #expect(projection.unreadPanelIDs == [firstPanelID])
    }

    @Test("Dock panel content receives projected unread state")
    func dockPanelContentReceivesProjectedUnreadState() throws {
        let dock = DockSplitStore(workspaceId: UUID(), baseDirectoryProvider: { nil })
        let panel = DockRuntimeParityPanel(title: "Dock")
        let paneID = try dock.seedRuntimeParityPanel(panel)
        let tabID = try #require(dock.surfaceId(forPanelId: panel.id))
        let content = DockSplitContentView(
            store: dock,
            appearance: .fromConfig(WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "test.dock.unread")),
            appearanceRevision: 0,
            windowAppearance: .rightSidebarPanelViewTestDefault,
            rightSidebarOwnsInputFocus: false,
            unreadPanelIDs: [panel.id]
        )

        let unreadPanelView = content.panelView(panel: panel, tabID: tabID, paneID: paneID)
        let readContent = DockSplitContentView(
            store: dock,
            appearance: content.appearance,
            appearanceRevision: 0,
            windowAppearance: content.windowAppearance,
            rightSidebarOwnsInputFocus: false,
            unreadPanelIDs: []
        )
        let readPanelView = readContent.panelView(panel: panel, tabID: tabID, paneID: paneID)

        #expect(unreadPanelView.panelContentView().hasUnreadNotification)
        #expect(unreadPanelView != readPanelView)
        let otherUnreadContent = DockSplitContentView(store: dock, appearance: content.appearance, appearanceRevision: 0, windowAppearance: content.windowAppearance, rightSidebarOwnsInputFocus: false, unreadPanelIDs: [UUID()])
        #expect(readPanelView == otherUnreadContent.panelView(panel: panel, tabID: tabID, paneID: paneID))
    }
}
