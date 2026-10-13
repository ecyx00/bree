import Foundation

/// Presentation command a provider can request from the BREE sidebar host.
public enum BreeSidebarProviderPresentationRequest: Codable, Equatable, Sendable {
    /// Open the workspace popover on a preferred tab.
    case openWorkspacePopover(workspaceId: UUID, preferredTab: BreeSidebarProviderWorkspacePopoverTab)
    /// Open a detached workspace window on a preferred tab.
    case openWorkspaceWindow(workspaceId: UUID, preferredTab: BreeSidebarProviderWorkspacePopoverTab)
    /// Ask BREE to open a URL.
    case openURL(String)
}
