import Foundation

@_spi(BreeHostTransport)
/// Result returned by BREE for a sidebar host action request.
public struct BreeSidebarActionResult: Codable, Equatable, Sendable {
    /// Whether BREE accepted and applied the action.
    public var accepted: Bool

    /// Optional host-supplied result or rejection message.
    public var message: String?

    /// Structured reason when the action was rejected.
    public var rejectionReason: BreeSidebarActionRejectionReason?

    /// Creates an action result.
    public init(
        accepted: Bool,
        message: String? = nil,
        rejectionReason: BreeSidebarActionRejectionReason? = nil
    ) {
        self.accepted = accepted
        self.message = message
        self.rejectionReason = accepted ? nil : rejectionReason
    }

    /// Successful action result.
    public static let accepted = BreeSidebarActionResult(accepted: true)

    /// Creates a rejected action result with a displayable message.
    public static func rejected(
        _ message: String,
        reason: BreeSidebarActionRejectionReason = .rejected
    ) -> BreeSidebarActionResult {
        BreeSidebarActionResult(accepted: false, message: message, rejectionReason: reason)
    }

    /// Rejected action result used when the caller cancels an in-flight request.
    public static let cancelled = BreeSidebarActionResult(
        accepted: false,
        message: "Extension action was cancelled",
        rejectionReason: .cancelled
    )
}

@_spi(BreeHostTransport)
/// Machine-readable reason BREE rejected a sidebar action.
public enum BreeSidebarActionRejectionReason: String, Codable, Equatable, Sendable {
    /// Generic host rejection.
    case rejected

    /// The caller cancelled the action before the host completed it.
    case cancelled
}

/// Error thrown by typed `BreeSidebarHost` action helpers.
public enum BreeSidebarActionError: Error, Equatable, Sendable {
    /// BREE rejected the action with a displayable message.
    case rejected(String)

    /// The caller cancelled the action before completion.
    case cancelled
}
