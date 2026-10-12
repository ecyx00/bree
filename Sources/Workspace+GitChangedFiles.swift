import CmuxSidebar
import Foundation

extension Workspace {
    /// Applies sidebar Git branch state plus the probed changed-file count
    /// unless the panel belongs to a Cloud machine.
    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool, changedFileCount: Int?) {
        if cloudDirectoryProvenanceRequired(panelId: panelId) {
            clearPanelGitBranch(panelId: panelId)
            return
        }
        let state = SidebarGitBranchState(branch: branch, isDirty: isDirty, changedFileCount: changedFileCount)
        let existing = panelGitBranches[panelId]
        if existing != state {
            panelGitBranches[panelId] = state
        }
        if panelId == focusedPanelId, gitBranch != state {
            gitBranch = state
        }
    }
}
