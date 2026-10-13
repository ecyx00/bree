import AppKit
import BreeTerminal

extension AppDelegate.MainWindowContext {
    /// Cancels work scoped to this context before the window owner releases it.
    func teardownWindowOwnedWork() {
        tabManager.workspaceSwitchCoordinator.cancel()
        workspaceTerminalFontSizeCoordinator.cancelWindowOwnedWork()
    }
}

extension AppDelegate {
    /// Resolves the `TabManager` a Dock's cross-container moves should target.
    /// A workspace Dock maps to its owning workspace's window. Fails closed
    /// (`nil`) when the owning workspace cannot be resolved.
    func dockReferenceTabManager(for dock: DockSplitStore) -> TabManager? {
        tabManagerFor(tabId: dock.workspaceId)
    }
}

extension SessionWindowSnapshot {
    @MainActor
    func omitsRemoteMirrorOnlyWindow(liveWorkspaces: [Workspace]) -> Bool {
        tabManager.workspaces.isEmpty &&
            !liveWorkspaces.isEmpty &&
            liveWorkspaces.allSatisfy { $0.isRemoteTmuxMirror }
    }
}
