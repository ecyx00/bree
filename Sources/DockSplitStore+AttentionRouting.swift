import AppKit
import Foundation

@MainActor
extension DockSplitStore {
    /// Resolves the notification authority injected by the owning window.
    ///
    /// Workspace-scoped Docks predate per-window ownership and retain the
    /// late-bound fallback until their construction path can inject the store.
    func resolvedNotificationStore() -> TerminalNotificationStore? {
        notificationStore ?? AppDelegate.shared?.notificationStore
    }

    /// Routes a panel attention request through the shared live-container
    /// registry. This is the Dock equivalent of Workspace's panel lookup and is
    /// intentionally container-agnostic: workspace Docks register in `liveStores`.
    @discardableResult
    static func routeAttentionFlash(
        panelID: UUID,
        reason: WorkspaceAttentionFlashReason,
        shouldFocus: Bool = false
    ) -> Bool {
        guard let dock = liveStore(containingPanel: panelID),
              let panel = dock.panels[panelID],
              panel.panelType == .terminal else {
            return false
        }
        if shouldFocus {
            dock.focusPanelFromDockInteraction(panelID, window: nil)
        }
        panel.triggerFlash(reason: reason)
        return true
    }

    /// Gives a Dock-owned terminal Dock-owned flash and visual-BEL callbacks.
    /// A moved terminal can otherwise retain its prior container's closures and
    /// publish attention into the wrong owner.
    func installAttentionRouting(for panel: any Panel) {
        guard let terminal = panel as? TerminalPanel else { return }
        let ownerTabManager = AppDelegate.shared?.dockReferenceTabManager(for: self)
        terminal.surface.onExplicitInput = { [weak self, weak terminal, weak ownerTabManager] in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            AgentAutoResumeCoordinator.shared.userDidInput(surfaceId: terminal.id)
            // The user (or a socket client) took over the pane: never replay a
            // lost restore selector into a line they are typing.
            self.restoredAgentLifecycle.clearStartupInput(panelId: terminal.id)
            _ = AppDelegate.shared?.notificationStore?.clearAgentAttentionNotification(
                forTabId: self.workspaceId,
                surfaceId: terminal.id
            )
            ownerTabManager?.dismissNotificationOnTerminalInteraction(
                tabId: self.workspaceId,
                surfaceId: terminal.id
            )
        }
        terminal.surface.onStartupRestoreAdmissionCancelled = { [weak self, weak terminal] in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal,
                  let restore = self.deferredAgentResumeRestoresByPanelId[terminal.id] else {
                return
            }
            self.cancelDeferredAgentResumeRestore(
                panelId: terminal.id,
                restore: restore
            )
        }
        terminal.onRequestWorkspacePaneFlash = { [weak self, weak terminal] reason in
            guard let self, let terminal,
                  let mountedTerminal = self.panels[terminal.id] as? TerminalPanel,
                  mountedTerminal === terminal else {
                return
            }
            mountedTerminal.hostedView.triggerFlash(
                style: GhosttySurfaceScrollView.flashStyle(for: reason)
            )
        }
        // The workspace Dock has no window-level unread target. Audio still
        // rings, but visual BEL attention must not create a phantom target
        // that navigation cannot reveal.
        terminal.surface.onVisualBell = nil
    }
}
