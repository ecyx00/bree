import Foundation

extension TabManager {
    /// Restores each workspace's persisted Dock after workspace topology exists.
    ///
    /// Deferred browser panels are passed through without constructing WebKit
    /// until the corresponding Dock pane becomes visible.
    func restoreWorkspaceDockSessionSnapshots(
        from snapshot: SessionTabManagerSnapshot,
        excludingStableIdentities: Set<UUID>,
        deferBrowserPanels: Bool = false
    ) {
        let pairs = restoredSessionWorkspacePairs(from: snapshot)
        var workspacesByOriginalId: [UUID: Workspace] = [:]
        for pair in pairs {
            if let originalId = pair.snapshot.workspaceId {
                workspacesByOriginalId[originalId] = pair.workspace
            }
        }
        for pair in pairs {
            guard let dockSnapshot = pair.snapshot.dock else { continue }
            guard let dock = pair.workspace.dockSplit else { continue }
            dock.suppressBottomPanelEmptyHide = true
            _ = dock.restoreSessionSnapshot(
                dockSnapshot,
                excludingStableIdentities: excludingStableIdentities,
                deferBrowserPanels: deferBrowserPanels,
                sourceWorkspaceResolver: { workspacesByOriginalId[$0] }
            )
            dock.suppressBottomPanelEmptyHide = false
            dock.applyBottomPanelSnapshot(
                isOpen: dockSnapshot.bottomPanelIsOpen,
                height: dockSnapshot.bottomPanelHeight
            )
            pair.workspace.objectWillChange.send()
        }
    }

    func restoredSessionWorkspace(
        originalId: UUID,
        from snapshot: SessionTabManagerSnapshot
    ) -> Workspace? {
        restoredSessionWorkspacePairs(from: snapshot).first {
            $0.snapshot.workspaceId == originalId
        }?.workspace
    }

    private func restoredSessionWorkspacePairs(
        from snapshot: SessionTabManagerSnapshot
    ) -> [(snapshot: SessionWorkspaceSnapshot, workspace: Workspace)] {
        let (normalizedSnapshots, _) = Self.normalizedCloudVMSessionRestoreWorkspaces(
            snapshot.workspaces.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            selectedWorkspaceIndex: snapshot.selectedWorkspaceIndex
        )
        return Array(zip(
            normalizedSnapshots.prefix(SessionPersistencePolicy.maxWorkspacesPerWindow),
            tabs
        ))
    }
}
