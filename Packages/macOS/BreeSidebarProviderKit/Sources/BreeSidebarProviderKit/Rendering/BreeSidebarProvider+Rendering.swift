import Foundation

public extension BreeSidebarProvider {
    /// Builds the default empty render model for providers that do not implement rendering.
    func render(snapshot: BreeSidebarProviderSnapshot) -> BreeSidebarProviderRenderModel {
        BreeSidebarProviderRenderModel(
            providerId: descriptor.id,
            snapshotSequence: snapshot.sequence,
            sections: []
        )
    }

    /// Builds a render model using contextual rendering when available.
    func render(
        snapshot: BreeSidebarProviderSnapshot,
        context: BreeSidebarProviderRenderContext
    ) -> BreeSidebarProviderRenderModel {
        render(snapshot: snapshot)
    }
}
