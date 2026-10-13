import BreeCloud
import BreeSurfaceCatalogModel
import Foundation

/// A browser pane opened at the New Display click, before the guest has
/// assigned the display. Display creation takes a round trip to the VM, so the
/// pane shows "Starting display…" immediately and the projection that follows
/// adopts it instead of opening a second pane.
struct CloudDisplayPaneReservation: Sendable {
    @TaskLocal static var current: CloudDisplayPaneReservation?

    /// The display the guest created; only that resource may adopt the pane.
    let resource: SurfaceResourceID
    let workspaceID: UUID
    let panelID: UUID

    /// The reserved pane for the created display. Nil for any other resource,
    /// which opens its own pane. Throws when the person closed the reserved
    /// pane while the display started: the display stays in the pool rather
    /// than reappearing somewhere else.
    @MainActor
    func pane(for resource: SurfaceResource) throws -> (workspaceID: UUID, panelID: UUID)? {
        guard resource.id == self.resource else { return nil }
        guard SurfacePaneFactory.browserPanel(panelID: panelID, in: workspaceID) != nil else { throw CancellationError() }
        return (workspaceID, panelID)
    }
}
