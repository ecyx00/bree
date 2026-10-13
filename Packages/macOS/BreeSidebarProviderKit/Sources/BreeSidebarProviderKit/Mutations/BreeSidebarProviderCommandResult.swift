import Foundation

/// Result returned after BREE handles a provider mutation.
public struct BreeSidebarProviderCommandResult: Codable, Equatable, Sendable {
    /// Whether BREE accepted and completed the command.
    public var ok: Bool

    /// Creates a command result.
    public init(ok: Bool) {
        self.ok = ok
    }
}
