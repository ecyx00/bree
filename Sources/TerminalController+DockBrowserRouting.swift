import AppKit
import Foundation
import WebKit

/// Dock routing for browser socket commands.
///
/// A browser surface is resolved together with the split container that owns it.
/// This matters for workspace Docks because their owner identifier is also the
/// main workspace identifier: `workspace_id` alone intentionally continues to
/// select the main workspace, while an explicit Dock `surface_id` or `pane_id`
/// disambiguates the Dock.
extension TerminalController {
    func v2ResolveDockBrowserPanelContext(
        params: [String: Any],
        tabManager: TabManager
    ) -> (handled: Bool, context: V2BrowserPanelContext?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id")
            ?? v2UUID(params, "tab_id")
        let requestedPaneID = v2UUID(params, "pane_id")
        let dockBySurface = requestedSurfaceID.flatMap {
            v2DockContainingPanel($0)
        }
        let dockByPane = requestedPaneID.flatMap {
            v2DockContainingPane($0)
        }
        guard dockBySurface != nil || dockByPane != nil else {
            return (false, nil, nil)
        }

        if let error = v2RejectUnresolvedHandles(
            params,
            ["workspace_id", "window_id", "surface_id", "tab_id", "pane_id"]
        ) {
            return (true, nil, error)
        }
        if v2DockBrowserSelectorsConflict(
            requestedWorkspaceID: requestedWorkspaceID,
            requestedWindowID: v2UUID(params, "window_id"),
            dockBySurface: dockBySurface,
            dockByPane: dockByPane
        ) {
            return (
                true,
                nil,
                .err(
                    code: "invalid_params",
                    message: dockConflictingRoutingSelectorsMessage(),
                    data: nil
                )
            )
        }
        guard let dock = dockBySurface ?? dockByPane else {
            return (
                true,
                nil,
                .err(
                    code: "not_found",
                    message: "No focused browser surface",
                    data: nil
                )
            )
        }

        let surfaceID: UUID?
        if let requestedSurfaceID {
            surfaceID = requestedSurfaceID
        } else if let requestedPaneID {
            guard let pane = dock.bonsplitController.allPaneIds.first(
                where: { $0.id == requestedPaneID }
            ) else {
                return (
                    true,
                    nil,
                    .err(
                        code: "not_found",
                        message: "Pane not found",
                        data: ["pane_id": requestedPaneID.uuidString]
                    )
                )
            }
            guard let selectedTab = dock.bonsplitController.selectedTab(
                inPane: pane
            ), let selectedSurface = dock.panel(for: selectedTab.id)?.id else {
                return (
                    true,
                    nil,
                    .err(
                        code: "not_found",
                        message: "Pane has no selected surface",
                        data: ["pane_id": requestedPaneID.uuidString]
                    )
                )
            }
            surfaceID = selectedSurface
        } else {
            surfaceID = dock.focusedPanelId
        }

        guard let surfaceID else {
            return (
                true,
                nil,
                .err(
                    code: "not_found",
                    message: "No focused browser surface",
                    data: nil
                )
            )
        }
        guard let browserPanel = dock.browserPanel(for: surfaceID) else {
            return (
                true,
                nil,
                .err(
                    code: "invalid_params",
                    message: "Surface is not a browser",
                    data: ["surface_id": surfaceID.uuidString]
                )
            )
        }
        return (
            true,
            V2BrowserPanelContext(
                host: .workspaceDock(dock.workspaceId),
                workspaceId: dock.workspaceId,
                surfaceId: surfaceID,
                browserPanel: browserPanel,
                webView: browserPanel.webViewForAutomationCommand()
            ),
            nil
        )
    }

    func v2ResolveDockBrowserTabStore(
        params: [String: Any],
        tabManager: TabManager
    ) -> (handled: Bool, dock: DockSplitStore?, error: V2CallResult?) {
        let requestedWorkspaceID = v2UUID(params, "workspace_id")
        let requestedSurfaceID = v2UUID(params, "surface_id")
            ?? v2UUID(params, "tab_id")
            ?? v2UUID(params, "target_surface_id")
        let requestedPaneID = v2UUID(params, "pane_id")
            ?? v2UUID(params, "target_pane_id")
        let dockBySurface = requestedSurfaceID.flatMap {
            v2DockContainingPanel($0)
        }
        let dockByPane = requestedPaneID.flatMap {
            v2DockContainingPane($0)
        }
        guard dockBySurface != nil || dockByPane != nil else {
            return (false, nil, nil)
        }

        if let error = v2RejectUnresolvedHandles(
            params,
            [
                "workspace_id",
                "window_id",
                "surface_id",
                "tab_id",
                "target_surface_id",
                "pane_id",
                "target_pane_id",
            ]
        ) {
            return (true, nil, error)
        }
        if v2DockBrowserSelectorsConflict(
            requestedWorkspaceID: requestedWorkspaceID,
            requestedWindowID: v2UUID(params, "window_id"),
            dockBySurface: dockBySurface,
            dockByPane: dockByPane
        ) {
            return (
                true,
                nil,
                .err(
                    code: "invalid_params",
                    message: dockConflictingRoutingSelectorsMessage(),
                    data: nil
                )
            )
        }
        guard let dock = dockBySurface ?? dockByPane else {
            return (
                true,
                nil,
                .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: nil
                )
            )
        }
        return (true, dock, nil)
    }

    /// Resolves the split tree that owns a browser-open source surface.
    func v2ResolveBrowserSplitContainer(
        params: [String: Any],
        tabManager: TabManager
    ) -> (container: BrowserSplitContainer?, error: V2CallResult?) {
        let dockResolution = v2ResolveDockBrowserTabStore(
            params: params,
            tabManager: tabManager
        )
        if dockResolution.handled {
            guard let dock = dockResolution.dock else {
                return (
                    nil,
                    dockResolution.error ?? .err(
                        code: "not_found",
                        message: "Workspace not found",
                        data: nil
                    )
                )
            }
            return (.dock(dock), nil)
        }

        guard let workspace = v2ResolveWorkspace(
            params: params,
            tabManager: tabManager
        ) else {
            return (
                nil,
                .err(
                    code: "not_found",
                    message: "Workspace not found",
                    data: nil
                )
            )
        }
        return (.workspace(workspace), nil)
    }

    func v2BrowserActionPayload(
        _ context: V2BrowserPanelContext,
        tabManager: TabManager,
        extra: [String: Any] = [:]
    ) -> [String: Any] {
        let windowID = v2BrowserWindowID(
            for: context.host,
            tabManager: tabManager
        )
        var payload: [String: Any] = [
            "workspace_id": context.workspaceId.uuidString,
            "workspace_ref": v2Ref(
                kind: .workspace,
                uuid: context.workspaceId
            ),
            "surface_id": context.surfaceId.uuidString,
            "surface_ref": v2Ref(kind: .surface, uuid: context.surfaceId),
            "window_id": v2OrNull(windowID?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowID),
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        return payload
    }

    func v2BrowserWindowID(
        for host: PanelHost,
        tabManager: TabManager
    ) -> UUID? {
        switch host {
        case .workspace:
            return v2ResolveWindowId(tabManager: tabManager)
        case .workspaceDock(let workspaceID):
            return AppDelegate.shared?.tabManagerFor(tabId: workspaceID)
                .flatMap { AppDelegate.shared?.windowId(for: $0) }
        }
    }

    func closeDockBrowserPanel(
        _ targetID: UUID,
        in dock: DockSplitStore
    ) -> Bool {
        guard let tabID = dock.surfaceId(forPanelId: targetID) else {
            return false
        }
        dock.forceCloseDockTabIds.insert(tabID)
        let closed = dock.bonsplitController.closeTab(tabID)
        if !closed {
            dock.forceCloseDockTabIds.remove(tabID)
        }
        return closed
    }

    private func v2DockBrowserSelectorsConflict(
        requestedWorkspaceID: UUID?,
        requestedWindowID: UUID?,
        dockBySurface: DockSplitStore?,
        dockByPane: DockSplitStore?
    ) -> Bool {
        let resolvedDocks = [dockBySurface, dockByPane]
            .compactMap { $0 }
        guard let dock = resolvedDocks.first else {
            return false
        }
        if resolvedDocks.contains(where: { $0 !== dock }) {
            return true
        }
        if let requestedWindowID,
           v2OwningWindowID(for: dock) != requestedWindowID {
            return true
        }
        guard let requestedWorkspaceID else {
            return false
        }
        return requestedWorkspaceID != dock.workspaceId
    }

    private func v2DockContainingPanel(_ panelID: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first(where: { $0.containsPanel(panelID) })
    }

    private func v2DockContainingPane(_ paneID: UUID) -> DockSplitStore? {
        DockSplitStore.liveStores.first(where: { $0.containsPane(paneID) })
    }

    private func v2OwningWindowID(for dock: DockSplitStore) -> UUID? {
        guard let app = AppDelegate.shared,
              let manager = app.tabManagerFor(tabId: dock.workspaceId) else {
            return nil
        }
        return app.windowId(for: manager)
    }
}
