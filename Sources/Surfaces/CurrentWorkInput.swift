import BreeSurfaceCatalogModel
import Foundation

/// Immutable capture for the pure current-work reduction; never persisted as a graph.
struct CurrentWorkInput: Sendable {
    init(
        export: SurfaceCatalogExport,
        observedAt: Date,
        workspaces: [UUID: WorkspaceFacts],
        agentsByPanelID: [UUID: [CurrentWorkSnapshot.Agent]],
        unreadPanelIDs: Set<UUID>,
        agentOwnerAvailable: Bool
    ) {
        self.export = export
        self.observedAt = observedAt
        self.workspaces = workspaces
        self.agentsByPanelID = agentsByPanelID
        self.unreadPanelIDs = unreadPanelIDs
        self.agentOwnerAvailable = agentOwnerAvailable
    }

    var export: SurfaceCatalogExport
    var observedAt: Date
    var workspaces: [UUID: WorkspaceFacts]
    var agentsByPanelID: [UUID: [CurrentWorkSnapshot.Agent]]
    var unreadPanelIDs: Set<UUID>
    var agentOwnerAvailable: Bool

    struct WorkspaceFacts: Sendable {
        init(
            projectRoot: String?,
            unreadCount: Int,
            notificationID: UUID?
        ) {
            self.projectRoot = projectRoot
            self.unreadCount = unreadCount
            self.notificationID = notificationID
        }

        var projectRoot: String?
        var unreadCount: Int
        var notificationID: UUID?
    }
}
