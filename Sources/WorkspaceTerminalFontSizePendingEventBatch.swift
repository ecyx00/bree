import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    struct PendingEventBatch {
        let lineage: EventBatchLineage
        var workspaceRequests: [UUID: PendingRequest] = [:]
        var workspaceOrder: [UUID] = []
    }
}
