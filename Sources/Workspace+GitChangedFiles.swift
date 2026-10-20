import BreeSidebar
import Foundation

extension Workspace {
    /// Applies sidebar Git branch state plus the probed changed-file count
    /// unless the panel belongs to a remote machine.
    func updatePanelGitBranch(panelId: UUID, branch: String, isDirty: Bool, changedFileCount: Int?) {
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
