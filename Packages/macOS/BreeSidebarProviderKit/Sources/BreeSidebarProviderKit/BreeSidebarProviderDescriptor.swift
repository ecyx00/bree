import Foundation

/// Stable metadata BREE uses to identify and present an in-process sidebar provider.
public struct BreeSidebarProviderDescriptor: Identifiable, Codable, Equatable, Sendable {
    /// Provider id for the built-in workspace sidebar.
    public static let defaultWorkspacesID = "bree.sidebar.default"

    /// Stable provider identifier persisted in user selection state.
    public var id: String
    /// Localized provider title shown in sidebar provider menus.
    public var title: BreeSidebarProviderLocalizedText
    /// Optional localized detail text shown under the provider title.
    public var subtitle: BreeSidebarProviderLocalizedText?
    /// SF Symbols name used for this provider in menus.
    public var systemImageName: String
    /// Whether the provider is supplied by BREE rather than a package example.
    public var isHostProvided: Bool

    /// Creates sidebar provider metadata.
    public init(
        id: String,
        title: BreeSidebarProviderLocalizedText,
        subtitle: BreeSidebarProviderLocalizedText? = nil,
        systemImageName: String,
        isHostProvided: Bool
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.systemImageName = systemImageName
        self.isHostProvided = isHostProvided
    }

    /// Descriptor for BREE's built-in workspace sidebar.
    public static let defaultWorkspaces = BreeSidebarProviderDescriptor(
        id: defaultWorkspacesID,
        title: BreeSidebarProviderLocalizedText(key: "sidebar.provider.default.title", defaultValue: "Default Workspaces"),
        subtitle: BreeSidebarProviderLocalizedText(key: "sidebar.provider.default.subtitle", defaultValue: "Bree"),
        systemImageName: "list.bullet",
        isHostProvided: true
    )
}
