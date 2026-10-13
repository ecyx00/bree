import Foundation

extension TabManager {
    /// Closes a socket/API-targeted workspace without an interactive veto.
    ///
    /// Closing a window's last workspace opens a fresh terminal workspace in its
    /// place, so the window stays. Remote-tmux mirrors detach in `closeWorkspace`.
    @discardableResult
    func closeWorkspaceNonInteractively(
        _ workspace: Workspace,
        recordHistory: Bool = true,
        allowPinned: Bool = false
    ) -> Bool {
        guard canCloseWorkspace(workspace, allowPinned: allowPinned),
              tabs.contains(where: { $0.id == workspace.id }) else { return false }
        closeWorkspaceKeepingWindowPopulated(workspace, recordHistory: recordHistory)
        return !tabs.contains(where: { $0.id == workspace.id })
    }
}
