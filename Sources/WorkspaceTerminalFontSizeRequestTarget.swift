import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    enum RequestTarget {
        case workspace(
            id: UUID,
            reference: WeakWorkspaceReference
        )
    }
}
