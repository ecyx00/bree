import Foundation

/// Rendered section with tree metadata and concrete rows.
public struct BreeSidebarProviderSection: Identifiable, Codable, Equatable, Sendable {
    /// Stable section id.
    public var id: String
    /// Tree/list section metadata.
    public var treeSection: BreeSidebarProviderTreeSection
    /// Rows rendered in this section.
    public var rows: [BreeSidebarProviderRow]

    /// Creates a provider section.
    public init(
        id: String,
        treeSection: BreeSidebarProviderTreeSection,
        rows: [BreeSidebarProviderRow]
    ) {
        self.id = id
        self.treeSection = treeSection
        self.rows = rows
    }
}
