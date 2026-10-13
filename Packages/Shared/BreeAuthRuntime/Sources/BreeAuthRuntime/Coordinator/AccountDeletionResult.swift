import Foundation

/// Result returned after the backend accepted account deletion.
public enum AccountDeletionResult: Equatable, Sendable {
    /// Stack and bree cleanup completed.
    case completed
    /// Stack account deletion completed, but the backend reported follow-up bree cleanup needs support attention.
    case completedWithIncompleteServerCleanup
}
