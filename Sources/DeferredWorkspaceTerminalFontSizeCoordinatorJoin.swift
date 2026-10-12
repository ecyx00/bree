import Foundation

/// An event that joins busy coordinators and waits until the prior owner
/// becomes available.
struct DeferredWorkspaceTerminalFontSizeCoordinatorJoin {
    let workspaceId: UUID
    let workspaceReference:
        WorkspaceTerminalFontSizeCoordinator.WeakWorkspaceReference
    let preferredCoordinator:
        WorkspaceTerminalFontSizeCoordinator
    let acceptedOrder: UInt64
    let projectionToken: UUID
    var change: WorkspaceTerminalFontSizeChange
    var deferFlush: Bool

    func matches(workspace: Workspace) -> Bool {
        workspaceId == workspace.id
            && workspaceReference.value === workspace
    }
}
