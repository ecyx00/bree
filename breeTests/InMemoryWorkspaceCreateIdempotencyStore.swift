import Foundation

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class InMemoryWorkspaceCreateIdempotencyStore:
    TerminalController.WorkspaceCreateIdempotencyPersisting {
    private var operationIDs: [UUID] = []

    func loadOperationIDs() -> [UUID] { operationIDs }

    func saveOperationIDs(_ operationIDs: [UUID]) {
        self.operationIDs = operationIDs
    }
}
