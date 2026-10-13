import Foundation

/// Provider that renders with explicit render context.
public protocol BreeContextualSidebarProvider: BreeSidebarProvider {
    /// Builds a render model from a sidebar snapshot and render context.
    func render(snapshot: BreeSidebarProviderSnapshot, context: BreeSidebarProviderRenderContext) -> BreeSidebarProviderRenderModel
}
