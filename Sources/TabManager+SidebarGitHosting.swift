import Foundation
import BreeGit
import BreeSidebarGit
import BreeSidebar

// MARK: - SidebarGitHosting conformance
//
// TabManager is the window-side host of the extracted BreeSidebarGit
// services: snapshot reads of workspace/panel state, synchronous projection
// writes of branch and PR badge state onto Workspace, and the environment
// toggles (settings) the schedulers honor. Every
// method forwards to the same Workspace/defaults accessors the legacy
// in-class subsystem used, so state transitions stay byte-identical.

extension TabManager: SidebarGitHosting {
    // MARK: Workspace/panel reads

    func orderedWorkspaceIds() -> [UUID] {
        tabs.map(\.id)
    }

    func workspaceExists(_ workspaceId: UUID) -> Bool {
        tabs.contains(where: { $0.id == workspaceId })
    }

    func isRemoteWorkspace(_ workspaceId: UUID) -> Bool? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return workspace.usesRemoteDirectoryProvenance
    }

    func panelIds(in workspaceId: UUID) -> [UUID] {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Array(workspace.panels.keys)
    }

    func panelExists(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.panels[panelId] != nil
    }

    func hasTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        tabs.first(where: { $0.id == workspaceId })?.terminalPanel(for: panelId) != nil
    }

    func isRemoteTerminalPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.isRemoteTerminalSurface(panelId) ||
            workspace.cloudDirectoryProvenanceRequired(panelId: panelId)
    }

    func gitProbeDirectory(workspaceId: UUID, panelId: UUID) -> String? {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return nil }
        return gitProbeDirectory(for: workspace, panelId: panelId)
    }

    func hasTrustedRemotePanelDirectory(workspaceId: UUID, panelId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.remoteDirectoryReportPanelIds.contains(panelId)
    }

    func panelGitBranch(workspaceId: UUID, panelId: UUID) -> SidebarPanelGitBranch? {
        guard let state = tabs.first(where: { $0.id == workspaceId })?.panelGitBranches[panelId] else {
            return nil
        }
        return SidebarPanelGitBranch(
            branch: state.branch,
            isDirty: state.isDirty,
            changedFileCount: state.changedFileCount
        )
    }

    func panelGitBranchPanelIds(in workspaceId: UUID) -> Set<UUID> {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return [] }
        return Set(workspace.panelGitBranches.keys)
    }

    func focusedPanelId(in workspaceId: UUID) -> UUID? {
        tabs.first(where: { $0.id == workspaceId })?.focusedPanelId
    }

    func hasWorkspaceLevelGitSignal(_ workspaceId: UUID) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.gitBranch != nil
    }

    func isSelectedFocusedPanel(workspaceId: UUID, panelId: UUID) -> Bool {
        selectedWorkspace?.id == workspaceId && selectedWorkspace?.focusedPanelId == panelId
    }

    // MARK: Projection writes

    @discardableResult
    func updatePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.updatePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel)
    }

    func updateRemoteSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String, displayLabel: String? = nil) {
        sidebarGitMetadataService.updateRemoteSurfaceDirectory(
            workspaceId: tabId,
            panelId: surfaceId,
            directory: directory,
            displayLabel: displayLabel
        )
    }

    func updateReportedSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String, displayLabel: String? = nil) {
        // A Cloud pane's local renderer/launcher cannot outrank the revisioned daemon graph.
        if tabs.first(where: { $0.id == tabId })?.cloudDirectoryProvenanceRequired(panelId: surfaceId) == true { return }
        if let workspace = tabs.first(where: { $0.id == tabId }),
           !workspace.allowsLocalDirectoryFallback(panelId: surfaceId) {
            updateRemoteSurfaceDirectory(tabId: tabId, surfaceId: surfaceId, directory: directory, displayLabel: displayLabel)
        } else {
            updateSurfaceDirectory(tabId: tabId, surfaceId: surfaceId, directory: directory, displayLabel: displayLabel)
        }
    }

    @discardableResult
    func updateRemotePanelDirectory(workspaceId: UUID, panelId: UUID, directory: String, displayLabel: String?) -> Bool {
        guard let workspace = tabs.first(where: { $0.id == workspaceId }) else { return false }
        return workspace.updateRemotePanelDirectory(panelId: panelId, directory: directory, displayLabel: displayLabel)
    }

    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool) {
        tabs.first(where: { $0.id == workspaceId })?
            .updatePanelGitBranch(panelId: panelId, branch: branch, isDirty: isDirty)
    }

    func updatePanelGitBranch(workspaceId: UUID, panelId: UUID, branch: String, isDirty: Bool, changedFileCount: Int?) {
        tabs.first(where: { $0.id == workspaceId })?.updatePanelGitBranch(
            panelId: panelId,
            branch: branch,
            isDirty: isDirty,
            changedFileCount: changedFileCount
        )
    }

    func clearPanelGitBranch(workspaceId: UUID, panelId: UUID) {
        tabs.first(where: { $0.id == workspaceId })?.clearPanelGitBranch(panelId: panelId)
    }

    func schedulePanelGitMetadataProbe(workspaceId: UUID, panelId: UUID, reason: String) {
        sidebarGitMetadataService.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: reason
        )
    }

    func clearAllSidebarGitMetadata() {
        for workspace in tabs {
            workspace.clearSidebarGitMetadata()
        }
    }

    // MARK: Environment

    var gitMetadataActivity: SidebarGitMetadataActivity {
        SidebarWorkspaceDetailDefaults.gitMetadataActivity(defaults: .standard)
    }

    func mobileHostHasRecentActivity(within interval: TimeInterval) -> Bool {
        false  // no mobile host any more; seam kept for the BreeSidebarGit protocol
    }

    func mobileHostQuietDelay(for interval: TimeInterval) -> TimeInterval {
        0
    }

    /// Reports whether the app-wide terminal input admission window is active.
    func terminalTypingIsActive(within interval: TimeInterval) -> Bool {
        terminalTypingQuietDelay(for: interval) > 0
    }

    /// Returns the remaining terminal input quiet period from the shared typing timestamp.
    func terminalTypingQuietDelay(for interval: TimeInterval) -> TimeInterval {
        guard let lastTypingActivityAt = AppDelegate.shared?.lastTypingActivityAt,
              lastTypingActivityAt > 0 else {
            return 0
        }
        return max(0, interval - (ProcessInfo.processInfo.systemUptime - lastTypingActivityAt))
    }
}
