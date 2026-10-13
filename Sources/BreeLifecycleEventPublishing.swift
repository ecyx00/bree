import Foundation
import AppKit
import Bonsplit

@MainActor
private enum BreeSelectionEventState {
    static var selectedSurfaceByWorkspacePane: [String: UUID] = [:]
    static var focusedPaneByWorkspace: [UUID: UUID] = [:]
    static var focusedSurfaceByWorkspace: [UUID: UUID] = [:]

    static func paneKey(workspaceId: UUID, paneId: UUID) -> String {
        "\(workspaceId.uuidString):\(paneId.uuidString)"
    }

    static func clearWorkspace(_ workspaceId: UUID) {
        selectedSurfaceByWorkspacePane = selectedSurfaceByWorkspacePane.filter {
            !$0.key.hasPrefix("\(workspaceId.uuidString):")
        }
        focusedPaneByWorkspace.removeValue(forKey: workspaceId)
        focusedSurfaceByWorkspace.removeValue(forKey: workspaceId)
    }

    static func clearPane(workspaceId: UUID, paneId: UUID) {
        selectedSurfaceByWorkspacePane.removeValue(forKey: paneKey(workspaceId: workspaceId, paneId: paneId))
        if focusedPaneByWorkspace[workspaceId] == paneId {
            focusedPaneByWorkspace.removeValue(forKey: workspaceId)
        }
    }

    static func clearSurface(workspaceId: UUID, surfaceId: UUID) {
        selectedSurfaceByWorkspacePane = selectedSurfaceByWorkspacePane.filter { $0.value != surfaceId }
        if focusedSurfaceByWorkspace[workspaceId] == surfaceId {
            focusedSurfaceByWorkspace.removeValue(forKey: workspaceId)
        }
    }
}

extension TabManager {
    func publishBreeWorkspaceCreated(_ workspace: Workspace, selected: Bool) {
        BreeEventBus.shared.publishWorkspaceCreated(
            workspaceId: workspace.id,
            title: workspace.breeEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            selected: selected,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }

    func publishBreeInitialSurfaceCreated(_ workspace: Workspace, selected: Bool) {
        guard let panelId = workspace.focusedSurfaceId,
              let panel = workspace.panels[panelId] else { return }
        workspace.publishBreeSurfaceCreated(
            panelId,
            paneId: workspace.paneId(forPanelId: panelId),
            kind: Workspace.breeEventSurfaceKind(panel),
            origin: "workspace_initial",
            focused: selected
        )
    }

    func publishBreeWorkspaceClosed(_ workspace: Workspace) {
        BreeEventBus.shared.publishWorkspaceClosed(
            workspaceId: workspace.id,
            title: workspace.breeEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            remainingTabCount: tabs.count
        )
        BreeSelectionEventState.clearWorkspace(workspace.id)
    }

    func publishBreeWorkspaceSelected(_ workspace: Workspace) {
        BreeEventBus.shared.publishWorkspaceSelected(
            workspaceId: workspace.id,
            title: workspace.breeEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            previousWorkspaceId: nil,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }

    func publishBreeWorkspaceSelectedChange(from previousWorkspaceId: UUID?) {
        guard let selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedTabId }) else { return }
        BreeEventBus.shared.publishWorkspaceSelected(
            workspaceId: workspace.id,
            title: workspace.breeEventWorkspaceTitle,
            customTitle: workspace.customTitle,
            currentDirectory: workspace.currentDirectory,
            previousWorkspaceId: previousWorkspaceId,
            index: tabs.firstIndex(where: { $0.id == workspace.id }),
            tabCount: tabs.count
        )
    }
}

extension Workspace {
    var breeEventWorkspaceTitle: String {
        customTitle ?? title
    }

    func publishBreeSplitCreated(
        _ paneId: PaneID,
        sourcePaneId: PaneID?,
        orientation: SplitOrientation,
        surfaceId: UUID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        BreeEventBus.shared.publishPaneCreated(
            workspaceId: id,
            paneId: paneId.id,
            sourcePaneId: sourcePaneId?.id,
            orientation: orientation.rawValue,
            surfaceId: surfaceId,
            origin: origin
        )
        if let surfaceId {
            publishBreeSurfaceCreated(surfaceId, paneId: paneId, kind: kind, origin: origin, focused: focused)
        }
    }

    func publishBreeSurfaceCreated(
        _ surfaceId: UUID,
        paneId: PaneID?,
        kind: String,
        origin: String,
        focused: Bool
    ) {
        BreeEventBus.shared.publishSurfaceCreated(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: kind,
            origin: origin,
            focused: focused
        )
    }

    func publishBreeSurfaceClosed(_ surfaceId: UUID, paneId: PaneID?, panel: (any Panel)?, origin: String) {
        BreeEventBus.shared.publishSurfaceClosed(
            workspaceId: id,
            surfaceId: surfaceId,
            paneId: paneId?.id,
            kind: panel.map(Self.breeEventSurfaceKind),
            origin: origin
        )
        BreeSelectionEventState.clearSurface(workspaceId: id, surfaceId: surfaceId)
    }

    func publishBreePaneClosed(_ paneId: PaneID, closedPanelIds: [UUID], origin: String) {
        BreeEventBus.shared.publishPaneClosed(
            workspaceId: id,
            paneId: paneId.id,
            closedSurfaceIds: closedPanelIds,
            origin: origin
        )
        BreeSelectionEventState.clearPane(workspaceId: id, paneId: paneId.id)
    }

    func publishBreeFocusedSelection(paneId: PaneID, surfaceId: UUID, origin: String) {
        let paneKey = BreeSelectionEventState.paneKey(workspaceId: id, paneId: paneId.id)
        let previousSelectedSurfaceId = BreeSelectionEventState.selectedSurfaceByWorkspacePane[paneKey]
        let kind = panels[surfaceId].map(Self.breeEventSurfaceKind)

        if previousSelectedSurfaceId != surfaceId {
            BreeSelectionEventState.selectedSurfaceByWorkspacePane[paneKey] = surfaceId
            BreeEventBus.shared.publishSurfaceSelected(
                workspaceId: id,
                surfaceId: surfaceId,
                paneId: paneId.id,
                kind: kind,
                previousSurfaceId: previousSelectedSurfaceId,
                focused: true,
                origin: origin
            )
        }

        if BreeSelectionEventState.focusedPaneByWorkspace[id] != paneId.id {
            BreeSelectionEventState.focusedPaneByWorkspace[id] = paneId.id
            BreeEventBus.shared.publishPaneFocused(
                workspaceId: id,
                paneId: paneId.id,
                selectedSurfaceId: surfaceId,
                origin: origin
            )
        }

        if BreeSelectionEventState.focusedSurfaceByWorkspace[id] != surfaceId {
            BreeSelectionEventState.focusedSurfaceByWorkspace[id] = surfaceId
            BreeEventBus.shared.publishSurfaceFocused(
                workspaceId: id,
                surfaceId: surfaceId,
                paneId: paneId.id,
                kind: kind,
                origin: origin
            )
        }
    }

    static func breeEventSurfaceKind(_ panel: any Panel) -> String {
        switch panel.panelType {
        case .terminal:
            return "terminal"
        case .browser:
            return "browser"
        case .markdown:
            return "markdown"
        case .filePreview:
            return "file_preview"
        case .rightSidebarTool:
            return "right_sidebar_tool"
        case .customSidebar:
            return "custom_sidebar"
        case .project:
            return "project"
        case .extensionBrowser:
            return "extension_browser"
        case .workspaceTodo:
            return "workspace_todo"
        case .notifications:
            return "notifications"
        case .accountSignIn:
            return "account_sign_in"
        }
    }
}

@MainActor
private enum MainWindowKeyRegainRefresh {
    static func refresh(window: NSWindow, context: AppDelegate.MainWindowContext) {
        // Window focus regain owns the redraw invariant. Cursor tracking and
        // focused subviews can update themselves only after this invalidation.
        invalidateContentDisplayTree(window: window)
        _ = context.keyboardFocusCoordinator.restoreTargetAfterWindowBecameKey()
    }

    private static func invalidateContentDisplayTree(window: NSWindow) {
        guard let contentView = window.contentView else { return }
        invalidateDisplayTree(rootedAt: contentView)
        window.invalidateCursorRects(for: contentView)
    }

    private static func invalidateDisplayTree(rootedAt view: NSView) {
        guard !view.isHidden else { return }
        view.needsDisplay = true
        view.layer?.setNeedsDisplay()
        for subview in view.subviews {
            invalidateDisplayTree(rootedAt: subview)
        }
    }
}

extension AppDelegate {
    func handleBreeWindowBecameKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            let context = senderRelativeMainWindowContext(for: window)
            setActiveMainWindow(window)
            if let windowId = mainWindowId(from: window) {
                publishBreeWindowLifecycle(
                    name: "window.keyed",
                    windowId: windowId,
                    origin: "appkit_key",
                    exactWindow: window,
                    allowTeardownRoute: false
                )
            }
            if let context {
                MainWindowKeyRegainRefresh.refresh(window: window, context: context)
            }
        }
    }

    func handleBreeWindowResignedKey(_ note: Notification) {
        guard let window = note.object as? NSWindow else { return }
        MainActor.assumeIsolated {
            if let windowId = mainWindowId(from: window) {
                publishBreeWindowLifecycle(
                    name: "window.unkeyed",
                    windowId: windowId,
                    origin: "appkit_key",
                    exactWindow: window,
                    allowTeardownRoute: false
                )
            }
        }
    }

    func publishBreeWindowLifecycle(
        name: String,
        windowId: UUID,
        origin: String,
        exactWindow: NSWindow? = nil,
        allowTeardownRoute: Bool = true
    ) {
        let manager: TabManager?
        if let exactWindow {
            manager = contextForMainTerminalWindow(exactWindow, reindex: false)?.tabManager
                ?? recoverableMainWindowIdentity(forExactWindow: exactWindow)?.tabManager
        } else if allowTeardownRoute {
            manager = tabManagerForWindowTeardown(windowId: windowId)
        } else {
            manager = tabManagerFor(windowId: windowId)
        }
        let workspaceId = manager?.selectedTabId
        let selectedWorkspaceIndex = workspaceId.flatMap { selectedId in
            manager?.tabs.firstIndex(where: { $0.id == selectedId })
        }
        let window = mainWindow(for: windowId)
        BreeEventBus.shared.publishWindowLifecycle(
            name: name,
            windowId: windowId,
            workspaceId: workspaceId,
            workspaceCount: manager?.tabs.count,
            selectedWorkspaceIndex: selectedWorkspaceIndex,
            isKeyWindow: window?.isKeyWindow,
            isMainWindow: window?.isMainWindow,
            origin: origin
        )
    }
}
