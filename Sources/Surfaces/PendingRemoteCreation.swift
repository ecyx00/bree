import BreeSurfaceCatalogModel
import Foundation

@MainActor
extension BreeTuiSurfaceProvider {
    /// A committed terminal retained until the canonical graph reaches its receipt.
    struct PendingRemoteCreation {
        var resource: SurfaceResource
        var receipt: CloudVMCursor?
        let tabID: String?
    }
}
