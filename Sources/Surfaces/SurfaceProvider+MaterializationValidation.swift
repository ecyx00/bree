import BreeSurfaceCatalogModel
import Foundation

extension SurfaceProvider {
    /// Checks the provider receipt before it can become a catalog projection.
    func materializeValidated(
        _ resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        at destination: SurfaceDestination,
        focus: Bool
    ) async throws -> SurfaceProjection {
        let projection = try await materialize(resource, remoteView: remoteView, at: destination, focus: focus)
        guard projection.resource == resource.id, projection.workspaceID == destination.workspaceID else {
            discardMaterialization(projection)
            throw SurfaceCatalogError.unavailable(resource.id, reason: "materialized pane does not match the request")
        }
        return projection
    }
}
