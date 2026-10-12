/// The live signals a workspace samples to infer its ``WorkspaceTaskStatus``.
/// A pure value so inference is unit-testable without live app state.
public struct WorkspaceTaskStatusSignals: Equatable, Sendable {
    /// Whether any agent in the workspace is waiting on user input.
    public var anyAgentNeedsInput: Bool
    /// Whether any agent in the workspace is running.
    public var anyAgentRunning: Bool
    /// Whether any tracked git working tree is dirty.
    public var isGitDirty: Bool

    /// Creates a signal sample (everything defaults to `false`).
    public init(
        anyAgentNeedsInput: Bool = false,
        anyAgentRunning: Bool = false,
        isGitDirty: Bool = false
    ) {
        self.anyAgentNeedsInput = anyAgentNeedsInput
        self.anyAgentRunning = anyAgentRunning
        self.isGitDirty = isGitDirty
    }
}
