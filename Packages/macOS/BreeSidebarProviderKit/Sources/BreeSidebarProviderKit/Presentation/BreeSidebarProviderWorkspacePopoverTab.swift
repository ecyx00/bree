import Foundation

/// Tabs available when BREE opens a workspace popover for a provider row.
public enum BreeSidebarProviderWorkspacePopoverTab: String, Codable, CaseIterable, Equatable, Sendable {
    /// Notes tab.
    case notes
    /// Browser previews tab.
    case browser
}
