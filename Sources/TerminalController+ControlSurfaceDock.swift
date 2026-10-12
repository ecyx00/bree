import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    func validateDockSurfaceCreateRouting(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType
    ) -> ControlSurfaceCreateResolution? {
        validateDockCreateRouting(
            routing: routing,
            tabManager: tabManager,
            panelType: panelType,
            unsupportedType: { .dockUnsupportedType(typeRawValue: $0, message: $1) },
            workspaceNotFound: .workspaceNotFound,
            conflictingSelectors: { .dockConflictingRoutingSelectors(message: $0) }
        )
    }

    func validateDockPaneCreateRouting(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType
    ) -> ControlPaneCreateResolution? {
        validateDockCreateRouting(
            routing: routing,
            tabManager: tabManager,
            panelType: panelType,
            unsupportedType: { .dockUnsupportedType(typeRawValue: $0, message: $1) },
            workspaceNotFound: .workspaceNotFound,
            conflictingSelectors: { .dockConflictingRoutingSelectors(message: $0) }
        )
    }

    func validateDockCreateRouting<Resolution>(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType,
        unsupportedType: (String, String) -> Resolution,
        workspaceNotFound: Resolution,
        conflictingSelectors: (String) -> Resolution
    ) -> Resolution? {
        guard panelType == .terminal || panelType == .browser else {
            return unsupportedType(panelType.rawValue, dockUnsupportedSurfaceTypeMessage())
        }
        return nil
    }

    func dockUnsupportedSurfaceTypeMessage() -> String {
        String(localized: "dock.error.unsupportedSurfaceType", defaultValue: "Panel placement supports only terminal and browser surfaces")
    }

    func dockUnavailableMessage() -> String {
        String(localized: "dock.error.unavailable", defaultValue: "Panel placement is unavailable")
    }

    func dockFocusUnavailableMessage() -> String {
        String(localized: "dock.error.focusUnavailable", defaultValue: "Panel could not be revealed")
    }

    func dockConflictingRoutingSelectorsMessage() -> String {
        String(localized: "dock.error.conflictingRoutingSelectors", defaultValue: "Conflicting Panel routing selectors")
    }

    /// Creates a surface (tab) in the routed workspace's bottom panel, then
    /// reveals the panel. The panel hosts terminal and browser surfaces only.
    func dockSurfaceCreate(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType,
        url: URL?,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        if let invalid = validateDockSurfaceCreateRouting(routing: routing, tabManager: tabManager, panelType: panelType) {
            return invalid
        }
        guard let workspace = resolveSurfaceCreateWorkspace(routing: routing, tabManager: tabManager),
              let dock = workspace.dockSplit else {
            return .workspaceNotFound
        }
        dock.prepareForBottomPanel()
        guard let paneId = dock.resolvePane(requestedPaneID: inputs.requestedPaneID) else {
            return .paneNotFound
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = (panelType == .browser) ? .browser : .terminal
        let newPanelId = dock.newSurface(
            kind: kind,
            inPane: paneId,
            url: kind == .browser ? url : nil,
            command: kind == .terminal ? inputs.initialCommand : nil,
            workingDirectory: kind == .terminal ? inputs.workingDirectory : nil,
            environment: inputs.startupEnvironment,
            tmuxStartCommand: kind == .terminal ? inputs.tmuxStartCommand : nil,
            initialInput: kind == .terminal ? inputs.initialInput : nil,
            focus: false,
            preloadInitialNavigationInBackground: kind == .browser
        )
        guard let newPanelId else {
            return .createFailed
        }
        revealBottomPanel(of: workspace, in: tabManager, focus: focus)
        if focus {
            dock.focusPanelFromDockInteraction(newPanelId, window: nil)
        }
        return .createdDock(
            windowID: v2ResolveWindowId(tabManager: tabManager) ?? workspace.id,
            workspaceID: workspace.id,
            dockPaneID: paneId.id,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }

    /// Selects `workspace` (when focus mutations are allowed) and opens its
    /// bottom panel without seeding a default terminal.
    func revealBottomPanel(of workspace: Workspace, in tabManager: TabManager, focus: Bool) {
        if focus {
            v2MaybeFocusWindow(for: tabManager)
            v2MaybeSelectWorkspace(tabManager, workspace: workspace)
        }
        workspace.setBottomPanelOpen(true, focus: focus, seedTerminal: false)
    }

    func resolveSurfaceCreateWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        return resolveSurfaceWorkspace(routing: routing, tabManager: tabManager)
    }

    func dockReferenceWindowId(app: AppDelegate, tabManager: TabManager) -> UUID? {
        app.windowId(for: tabManager) ?? v2ResolveWindowId(tabManager: tabManager)
    }

    /// Focuses the owning window, selects the owning workspace and opens its
    /// bottom panel. Returns whether the panel became available.
    @discardableResult
    func focusAndRevealDock(for dock: DockSplitStore, fallback tabManager: TabManager) -> Bool {
        guard dock.scope == .workspace,
              let owningTabManager = AppDelegate.shared?.dockReferenceTabManager(for: dock),
              let workspace = owningTabManager.tabs.first(where: { $0.id == dock.workspaceId }),
              workspace._dockSplit === dock else {
            return false
        }
        revealBottomPanel(of: workspace, in: owningTabManager, focus: true)
        setActiveTabManager(owningTabManager)
        return true
    }

    /// The window id Dock-scoped results report.
    func dockResultWindowId(for dock: DockSplitStore, tabManager: TabManager) -> UUID? {
        v2ResolveWindowId(tabManager: tabManager)
    }

    /// The `TabManager` Dock-scoped focus/reveal should act on.
    func dockOwnerTabManager(for dock: DockSplitStore, fallback: TabManager) -> TabManager {
        fallback
    }

    func orderedPanels(in dock: DockSplitStore) -> [any Panel] {
        var seenPanelIds: Set<UUID> = []
        var ordered: [any Panel] = []
        for tabId in dock.bonsplitController.allTabIds {
            guard let panel = dock.panel(for: tabId),
                  seenPanelIds.insert(panel.id).inserted else { continue }
            ordered.append(panel)
        }
        return ordered
    }

    func dockPanelTitle(_ panel: any Panel, in dock: DockSplitStore) -> String {
        guard let tabId = dock.surfaceId(forPanelId: panel.id),
              let paneId = dock.paneId(forPanelId: panel.id),
              let tab = dock.bonsplitController.tabs(inPane: paneId).first(where: { $0.id == tabId }) else {
            return panel.displayTitle
        }
        return tab.title
    }

    func resolvedSurfaceIdForClose(
        explicitSurfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        routing: ControlRoutingSelectors,
        fallbackWorkspace: Workspace
    ) -> UUID? {
        if hasSurfaceIDParam && explicitSurfaceID == nil {
            return nil
        }
        if let explicitSurfaceID {
            return explicitSurfaceID
        }
        if let routedSurfaceID = routing.surfaceID {
            return routedSurfaceID
        }
        return fallbackWorkspace.focusedPanelId
    }

    func resolvedDockSurfaceId(
        explicitSurfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        routing: ControlRoutingSelectors,
        dock: DockSplitStore
    ) -> (surfaceID: UUID?, invalidSurfaceID: Bool) {
        if hasSurfaceIDParam && explicitSurfaceID == nil {
            return (nil, true)
        }
        if let explicitSurfaceID {
            return (explicitSurfaceID, false)
        }
        if let routedSurfaceID = routing.surfaceID {
            return (routedSurfaceID, false)
        }
        if let routedPaneID = routing.paneID {
            guard let paneID = dock.bonsplitController.allPaneIds.first(where: {
                $0.id == routedPaneID
            }),
            let tabID = dock.bonsplitController.selectedTab(inPane: paneID)?.id,
            let panel = dock.panel(for: tabID) else {
                return (nil, false)
            }
            return (panel.id, false)
        }
        return (dock.focusedPanelId, false)
    }

    func terminalPanel(
        in dock: DockSplitStore,
        explicitSurfaceID: UUID?,
        hasSurfaceIDParam: Bool,
        routing: ControlRoutingSelectors
    ) -> (surfaceID: UUID?, terminalPanel: TerminalPanel?, invalidSurfaceID: Bool) {
        let resolved = resolvedDockSurfaceId(
            explicitSurfaceID: explicitSurfaceID,
            hasSurfaceIDParam: hasSurfaceIDParam,
            routing: routing,
            dock: dock
        )
        guard let surfaceID = resolved.surfaceID else {
            return (nil, nil, resolved.invalidSurfaceID)
        }
        return (surfaceID, dock.panels[surfaceID] as? TerminalPanel, false)
    }

    func locateDockSurface(_ surfaceId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager)? {
        guard let app = AppDelegate.shared else { return nil }
        // Indexed path: only workspaces/windows that actually have a Dock
        // register a live store, so this asks each store's authoritative
        // `containsPanel` instead of walking every window × workspace tab.
        // Falls through to the scan if a store can't be located.
        for store in DockSplitStore.liveStores where store.containsPanel(surfaceId) {
            if let location = dockStoreLocation(store, app: app) {
                return (location.windowId, location.workspaceId, location.tabManager)
            }
        }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPanel(surfaceId) }) else { continue }
            return (summary.windowId, workspace.id, manager)
        }
        return nil
    }

    func locateDockPane(_ paneId: UUID) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager, workspace: Workspace)? {
        guard let app = AppDelegate.shared else { return nil }
        for store in DockSplitStore.liveStores where store.containsPane(paneId) {
            if let location = dockStoreLocation(store, app: app), let workspace = location.workspace {
                return (location.windowId, location.workspaceId, location.tabManager, workspace)
            }
        }
        for summary in app.listMainWindowSummaries() {
            guard let manager = app.tabManagerFor(windowId: summary.windowId),
                  let workspace = manager.tabs.first(where: { $0.containsDockPane(paneId) }) else { continue }
            return (summary.windowId, workspace.id, manager, workspace)
        }
        return nil
    }

    /// Resolves the owning window, workspace id, tab manager, and (for
    /// per-workspace Docks) the `Workspace` for a live Dock `store`. Used by the
    /// indexed `locateDockSurface` / `locateDockPane` paths.
    private func dockStoreLocation(
        _ store: DockSplitStore,
        app: AppDelegate
    ) -> (windowId: UUID, workspaceId: UUID, tabManager: TabManager, workspace: Workspace?)? {
        guard let tabManager = app.tabManagerFor(tabId: store.workspaceId),
              let workspace = tabManager.tabs.first(where: { $0.id == store.workspaceId }),
              let windowId = dockReferenceWindowId(app: app, tabManager: tabManager) else { return nil }
        return (windowId, store.workspaceId, tabManager, workspace)
    }
}
