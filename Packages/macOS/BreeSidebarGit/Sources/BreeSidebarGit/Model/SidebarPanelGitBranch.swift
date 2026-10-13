/// A panel's git branch as the sidebar shows it: the branch name plus whether
/// the working tree is dirty.
///
/// This is the package's wire value for host reads: the host maps its own
/// sidebar branch state type to and from this value at the seam.
public struct SidebarPanelGitBranch: Equatable, Sendable {
    /// The branch name.
    public let branch: String
    /// Whether the working tree has uncommitted changes.
    public let isDirty: Bool
    /// Changed-file count (untracked included), or `nil` when unknown.
    public let changedFileCount: Int?

    /// Creates a panel branch value.
    public init(branch: String, isDirty: Bool, changedFileCount: Int? = nil) {
        self.branch = branch
        self.isDirty = isDirty
        self.changedFileCount = changedFileCount
    }
}
