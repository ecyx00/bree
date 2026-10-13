public import Foundation

/// The managed bree context identity exported to a spawned terminal process.
///
/// These values become the `BREE_WORKSPACE_ID` / `BREE_SURFACE_ID` /
/// `BREE_TERMINAL_LIFECYCLE_ID` / `BREE_SOCKET_PATH` (and legacy tab/panel
/// alias) environment variables.
public struct TerminalSurfaceBreeContextEnvironment: Equatable, Sendable {
    /// The owning workspace id (exported as `BREE_WORKSPACE_ID` / `BREE_TAB_ID`).
    public let workspaceId: UUID

    /// The surface id (exported as `BREE_SURFACE_ID` / `BREE_PANEL_ID`).
    public let surfaceId: UUID

    /// The process-generation id exported as `BREE_TERMINAL_LIFECYCLE_ID`.
    public let terminalLifecycleId: UUID

    /// The control socket path (exported as `BREE_SOCKET_PATH`).
    public let socketPath: String

    /// Creates the managed context identity.
    ///
    /// - Parameters:
    ///   - workspaceId: The owning workspace id.
    ///   - surfaceId: The surface id.
    ///   - terminalLifecycleId: The terminal process-generation id.
    ///   - socketPath: The control socket path.
    public init(
        workspaceId: UUID,
        surfaceId: UUID,
        terminalLifecycleId: UUID,
        socketPath: String
    ) {
        self.workspaceId = workspaceId
        self.surfaceId = surfaceId
        self.terminalLifecycleId = terminalLifecycleId
        self.socketPath = socketPath
    }
}
