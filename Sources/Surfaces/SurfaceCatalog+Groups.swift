import BreeCore
import BreeSurfaceCatalogModel
import Foundation
/// A collection of resources that travels as one drag or one "open all": a bree-tui
/// workspace on a machine, or a local workspace (the panes it projects). The canonical
/// payload is typed placements. `resources` and the group workspace id remain as derived
/// compatibility views for older callers and persisted drag records.
struct SurfaceResourceGroup: Hashable, Codable, Sendable {
    let title: String
    let placements: [SurfaceResourcePlacement]
    /// A common placement used by legacy callers that have no per-member tab id.
    let remoteWorkspaceID: String?
    /// True only for a whole workspace row, never a selection of its tabs.
    let representsWorkspace: Bool

    var resources: [SurfaceResourceID] { placements.map(\.resource) }
    var isEmpty: Bool { placements.isEmpty }

    func withRemoteWorkspaceID(_ id: String?) -> Self {
        SurfaceResourceGroup(title: title, placements: placements, remoteWorkspaceID: id ?? remoteWorkspaceID, representsWorkspace: representsWorkspace)
    }

    init(title: String, resources: [SurfaceResourceID], remoteWorkspaceID: String? = nil) {
        self.init(
            title: title,
            placements: resources.map {
                SurfaceResourcePlacement(resource: $0, remoteWorkspaceID: remoteWorkspaceID)
            },
            remoteWorkspaceID: remoteWorkspaceID
        )
    }

    init(
        title: String,
        placements: [SurfaceResourcePlacement],
        remoteWorkspaceID: String? = nil,
        representsWorkspace: Bool = false
    ) {
        self.representsWorkspace = representsWorkspace
        self.title = title
        self.placements = placements
        self.remoteWorkspaceID = remoteWorkspaceID
    }

    init(single resource: SurfaceResource) {
        let view = resource.remoteViews?.count == 1 ? resource.remoteViews?.first : nil
        self.init(title: resource.title, placements: [SurfaceResourcePlacement(resource: resource.id, remoteView: view)])
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case resources
        case placements
        case remoteWorkspaceID
        case representsWorkspace
    }

    /// Decode both the placement-aware format and the original id-only format.
    /// Old records are deliberately marked only with their common workspace; if
    /// that workspace has several views, opening fails with an ambiguity error.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decode(String.self, forKey: .title)
        representsWorkspace = try container.decodeIfPresent(Bool.self, forKey: .representsWorkspace) ?? false
        let decodedRemoteWorkspaceID = try container.decodeIfPresent(String.self, forKey: .remoteWorkspaceID)
        remoteWorkspaceID = decodedRemoteWorkspaceID
        if let decoded = try container.decodeIfPresent([SurfaceResourcePlacement].self, forKey: .placements) {
            placements = decoded
        } else {
            let ids = try container.decodeIfPresent([SurfaceResourceID].self, forKey: .resources) ?? []
            placements = ids.map {
                SurfaceResourcePlacement(resource: $0, remoteWorkspaceID: decodedRemoteWorkspaceID)
            }
        }
    }

    /// Emit both fields for one migration window. Older clients read `resources`;
    /// newer clients retain exact tab ids from `placements`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(representsWorkspace, forKey: .representsWorkspace)
        try container.encode(resources, forKey: .resources)
        try container.encode(placements, forKey: .placements)
        try container.encodeIfPresent(remoteWorkspaceID, forKey: .remoteWorkspaceID)
    }
}

extension SurfaceCatalog {
    /// Finds the pane hosting a panel, so the rest of a group can join it as tabs.
    typealias PaneLookup = @MainActor (_ panelID: UUID, _ workspaceID: UUID) -> String?

    /// Projects a group: the first resource lands exactly at `destination` (never reusing a
    /// pane elsewhere), every following one becomes a tab in the pane the first one created,
    /// so a dropped workspace arrives as one pane with its terminals and browsers as tabs.
    /// Resources the catalog does not know (or that fail to materialize) are skipped; only
    /// the first pane takes focus. Throws only when nothing could be projected.
    @discardableResult
    func projectGroup(
        _ ids: [SurfaceResourceID],
        into destination: SurfaceDestination,
        focus: Bool,
        remoteWorkspaceID: String? = nil,
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) }
    ) async throws -> [SurfaceProjection] {
        try await projectGroup(
            SurfaceResourceGroup(
                title: "",
                resources: ids,
                remoteWorkspaceID: remoteWorkspaceID
            ),
            into: destination,
            focus: focus,
            paneLookup: paneLookup
        )
    }

    /// Placement-aware group projection. Each member resolves its opaque tab id
    /// against the current catalog; a stale explicit tab is rejected rather than
    /// silently falling back to another view.
    @discardableResult
    func projectGroup(
        _ group: SurfaceResourceGroup,
        into destination: SurfaceDestination,
        focus: Bool,
        paneLookup: PaneLookup = { panelID, workspaceID in SurfacePaneFactory.paneID(ofPanel: panelID, in: workspaceID) }
    ) async throws -> [SurfaceProjection] {
        try validateOwnership(of: group.resources, at: destination)
        var projected: [SurfaceProjection] = []
        var firstError: Error?
        var anchor: SurfaceDestination?
        for member in group.placements {
            let id = member.resource
            let target: SurfaceDestination
            if let anchor {
                target = anchor
            } else {
                target = destination
            }
            do {
                let result = try await project(
                    id,
                    into: target,
                    focus: anchor == nil && focus,
                    reuseExisting: false
                )
                projected.append(result.projection)
                if anchor == nil {
                    let lead = result.projection
                    if let paneID = paneLookup(lead.panelID, lead.workspaceID) {
                        anchor = .tab(workspaceID: lead.workspaceID, paneID: paneID, index: nil)
                    } else {
                        anchor = .workspace(id: lead.workspaceID, placement: .tab)
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if projected.isEmpty, let firstError {
            throw firstError
        }
        if projected.isEmpty {
            throw SurfaceCatalogError.destinationNotFound("empty group")
        }
        return projected
    }
}
