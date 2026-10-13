import Foundation

/// Row rendered inside a provider section.
public struct BreeSidebarProviderRow: Identifiable, Codable, Equatable, Sendable {
    /// Stable row id.
    public var id: UUID
    /// Primary row title.
    public var title: String
    /// Workspace represented by the row.
    public var workspaceId: UUID
    /// Optional trailing accessory.
    public var accessory: BreeSidebarProviderRowAccessory?
    /// Optional subtitle.
    public var subtitle: BreeSidebarProviderText?
    /// Optional trailing text.
    public var trailingText: BreeSidebarProviderText?
    /// Optional leading icon.
    public var leadingIcon: BreeSidebarProviderIcon?

    /// Creates a provider row.
    public init(
        id: UUID,
        title: String,
        workspaceId: UUID,
        accessory: BreeSidebarProviderRowAccessory?,
        subtitle: BreeSidebarProviderText? = nil,
        trailingText: BreeSidebarProviderText? = nil,
        leadingIcon: BreeSidebarProviderIcon? = nil
    ) {
        self.id = id
        self.title = title
        self.workspaceId = workspaceId
        self.accessory = accessory
        self.subtitle = subtitle
        self.trailingText = trailingText
        self.leadingIcon = leadingIcon
    }
}
