public import Foundation

/// The exact notification owner targeted by a focused unread command.
///
public enum FocusedNotificationTarget: Sendable, Equatable {
    /// A surface in a workspace, or the workspace itself when `surfaceId` is nil.
    case workspace(tabId: UUID, surfaceId: UUID?)
}
