import Foundation

/// Current sidebar state delivered by BREE to a sidebar extension.
public struct BreeSidebarContext: Sendable {
    /// Latest workspace snapshot filtered to the permissions granted by the user.
    public let snapshot: BreeSidebarSnapshot

    /// Read scopes BREE granted for this snapshot.
    public let grantedReadScopes: Set<BreeExtensionScope>

    /// Host actions BREE will currently accept from this extension.
    public let grantedActionScopes: Set<BreeExtensionActionScope>

    /// Typed command channel back to BREE.
    public let host: BreeSidebarHost

    @MainActor
    public init(
        snapshot: BreeSidebarSnapshot,
        grantedReadScopes: Set<BreeExtensionScope>? = nil,
        grantedActionScopes: Set<BreeExtensionActionScope>? = nil,
        host: BreeSidebarHost
    ) {
        self.snapshot = snapshot
        self.grantedReadScopes = grantedReadScopes ?? snapshot.grantedReadScopes
        self.grantedActionScopes = grantedActionScopes ?? snapshot.grantedActionScopes
        self.host = host
    }
}
