import Foundation

extension TabManager {

    /// Reconciles task-create provenance only when the caller owns a cache.
    /// A nil cache intentionally leaves unrelated snapshot restores isolated.
    static func recordRestoredTaskCreateProvenance(
        for workspace: Workspace,
        in cache: TerminalController.WorkspaceCreateIdempotencyCache?
    ) {
        guard let operationID = workspace.taskCreateOperationID, let cache else { return }
        cache.record(operationID: operationID, workspaceID: workspace.id)
    }
}
