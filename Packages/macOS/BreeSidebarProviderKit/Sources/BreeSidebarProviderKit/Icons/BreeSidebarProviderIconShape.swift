import Foundation

/// Shape used behind a provider row icon.
public enum BreeSidebarProviderIconShape: String, Codable, Equatable, Sendable {
    /// Circular icon background.
    case circle
    /// Rounded-rectangle icon background.
    case roundedRectangle = "rounded-rectangle"
}
