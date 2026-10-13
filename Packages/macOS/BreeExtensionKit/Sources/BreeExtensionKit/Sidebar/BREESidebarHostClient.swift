import Foundation

@_spi(BreeHostTransport)
/// Host-side callbacks used by the sidebar XPC bridge.
public struct BreeSidebarHostClient: Sendable {
    /// Returns the latest host snapshot that should be sent to an extension.
    public var snapshot: @Sendable () async throws -> BreeSidebarSnapshot

    /// Dispatches a sidebar action from an extension into BREE.
    public var dispatch: @Sendable (BreeSidebarAction) async throws -> BreeSidebarActionResult

    /// Creates a host client from snapshot and action-dispatch closures.
    public init(
        snapshot: @escaping @Sendable () async throws -> BreeSidebarSnapshot,
        dispatch: @escaping @Sendable (BreeSidebarAction) async throws -> BreeSidebarActionResult
    ) {
        self.snapshot = snapshot
        self.dispatch = dispatch
    }
}
