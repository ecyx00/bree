import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    struct PendingRequest {
        let token: UUID
        let sequence: UInt64
        let acceptedOrder: UInt64
        let resourceKey: RequestResourceKey
        let target: RequestTarget
        let batchLineage: EventBatchLineage
        var change: WorkspaceTerminalFontSizeChange
    }
}
