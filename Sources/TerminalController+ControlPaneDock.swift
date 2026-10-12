import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation

extension TerminalController {
    /// Creates a pane in the routed workspace's bottom panel instead of the
    /// main area, splitting the panel's own Bonsplit tree. Browser-disabled is
    /// handled by `controlPaneCreate` before this is reached.
    func dockPaneCreate(
        routing: ControlRoutingSelectors,
        tabManager: TabManager,
        panelType: PanelType,
        url: URL?,
        orientation: SplitOrientation,
        insertFirst: Bool,
        initialDividerPosition: CGFloat?,
        preferredProfileID: UUID?,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        if let invalid = validateDockPaneCreateRouting(routing: routing, tabManager: tabManager, panelType: panelType) {
            return invalid
        }
        guard let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager),
              let dock = workspace.dockSplit else {
            return .workspaceNotFound
        }
        dock.prepareForBottomPanel()
        // An explicit source surface must live in the panel tree; do not silently
        // fall back to another pane (mirrors the workspace `.noSourceSurface`).
        if let requestedSource = inputs.requestedSourceSurfaceID, !dock.containsPanel(requestedSource) {
            return .noSourceSurface
        }
        let focus = v2FocusAllowed(requested: inputs.requestedFocus)
        let kind: DockSurfaceKind = (panelType == .browser) ? .browser : .terminal
        let newPanelId = dock.newSplit(
            kind: kind,
            orientation: orientation,
            insertFirst: insertFirst,
            sourcePanelId: inputs.requestedSourceSurfaceID,
            url: kind == .browser ? url : nil,
            command: kind == .terminal ? inputs.initialCommand : nil,
            workingDirectory: kind == .terminal ? inputs.workingDirectory : nil,
            environment: inputs.startupEnvironment,
            tmuxStartCommand: kind == .terminal ? inputs.tmuxStartCommand : nil,
            initialInput: kind == .terminal ? inputs.initialInput : nil,
            initialDividerPosition: initialDividerPosition,
            preferredProfileID: preferredProfileID,
            preloadInitialNavigationInBackground: kind == .browser,
            focus: false
        )
        guard let newPanelId else {
            return .createFailed
        }
        revealBottomPanel(of: workspace, in: tabManager, focus: focus)
        if focus {
            dock.focusPanelFromDockInteraction(newPanelId, window: nil)
        }
        let paneUUID = dock.paneId(forPanelId: newPanelId)?.id
        return .createdDock(
            windowID: v2ResolveWindowId(tabManager: tabManager) ?? workspace.id,
            workspaceID: workspace.id,
            dockPaneID: paneUUID,
            dockSurfaceID: newPanelId,
            typeRawValue: panelType.rawValue
        )
    }
}
