/// The git branch shown for a workspace or panel in the sidebar.
public struct SidebarGitBranchState: Equatable, Sendable {
    /// The branch name.
    public let branch: String
    /// Whether the working tree is dirty.
    public let isDirty: Bool
    /// Changed-file count (untracked included), or `nil` when unknown.
    public let changedFileCount: Int?

    /// Creates a branch state.
    public init(branch: String, isDirty: Bool, changedFileCount: Int? = nil) {
        self.branch = branch
        self.isDirty = isDirty
        self.changedFileCount = changedFileCount
    }
}
