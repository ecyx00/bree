import BreeSurfaceCatalogModel

/// The daemon's creation receipt and the source snapshot's workspace identity.
public struct CloudTerminalLayoutCreationResult: Sendable {
    public init(
        created: BreeTuiSnapshotParser.CreatedTerminalPath,
        workspaceID: String
    ) {
        self.created = created
        self.workspaceID = workspaceID
    }

    public let created: BreeTuiSnapshotParser.CreatedTerminalPath
    public let workspaceID: String
}
