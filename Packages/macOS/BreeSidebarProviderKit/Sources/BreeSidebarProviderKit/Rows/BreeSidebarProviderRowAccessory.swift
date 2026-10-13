import Foundation

/// Accessory control displayed at the trailing edge of a provider row.
public struct BreeSidebarProviderRowAccessory: Codable, Equatable, Sendable {
    /// Accessory behavior.
    public var kind: BreeSidebarProviderRowAccessoryKind
    /// SF Symbols name for the accessory icon.
    public var systemImageName: String
    /// Default popover tab when the accessory opens workspace details.
    public var defaultTab: BreeSidebarProviderWorkspacePopoverTab

    /// Creates a row accessory.
    public init(
        kind: BreeSidebarProviderRowAccessoryKind,
        systemImageName: String,
        defaultTab: BreeSidebarProviderWorkspacePopoverTab
    ) {
        self.kind = kind
        self.systemImageName = systemImageName
        self.defaultTab = defaultTab
    }

    /// Standard workspace inspector accessory.
    public static let inspector = BreeSidebarProviderRowAccessory(
        kind: .workspaceInspector,
        systemImageName: "ellipsis.circle",
        defaultTab: .notes
    )
}
