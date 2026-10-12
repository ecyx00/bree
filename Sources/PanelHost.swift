import Foundation

/// Identifies the split container that owns a panel.
enum PanelHost: Equatable, Hashable, Sendable {
    case workspace(UUID)
    case workspaceDock(UUID)

    var ownerID: UUID {
        switch self {
        case .workspace(let id),
             .workspaceDock(let id):
            return id
        }
    }

    var identityKey: String {
        switch self {
        case .workspace(let id):
            return "workspace:\(id.uuidString.lowercased())"
        case .workspaceDock(let id):
            return "workspace-dock:\(id.uuidString.lowercased())"
        }
    }
}
