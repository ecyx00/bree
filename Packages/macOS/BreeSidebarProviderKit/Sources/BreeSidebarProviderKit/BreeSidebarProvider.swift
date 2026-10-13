import Foundation

/// In-process sidebar provider used by BREE-owned sidebar presentations.
public protocol BreeSidebarProvider: Sendable {
    /// Stable metadata describing the provider in selection UI.
    var descriptor: BreeSidebarProviderDescriptor { get }

    /// Builds a render model from the latest sidebar snapshot.
    func render(snapshot: BreeSidebarProviderSnapshot) -> BreeSidebarProviderRenderModel
}
