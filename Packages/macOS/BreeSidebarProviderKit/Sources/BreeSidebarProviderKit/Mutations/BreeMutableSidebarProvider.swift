import Foundation

/// Provider that can both render sidebar state and handle host mutations.
public protocol BreeMutableSidebarProvider: BreeContextualSidebarProvider {
    /// Handles a mutation against the latest sidebar snapshot.
    func handle(
        _ mutation: BreeSidebarProviderMutation,
        snapshot: BreeSidebarProviderSnapshot
    ) throws -> BreeSidebarProviderCommandResult
}
