import Foundation

/// Coarse group a palette command belongs to. Declaration order is the order
/// of the section headers shown for an empty query.
public enum CommandPaletteCategory: Int, CaseIterable, Sendable {
    case workspace
    case pane
    case agent
    case view
    case learn
    case app

    /// Derives the category from a stable command identifier.
    public init(commandId id: String) {
        if let override = Self.overrides[id] {
            self = override
        } else if id.hasPrefix("palette.forkAgent") || id.hasPrefix("palette.currentWork")
            || ["palette.showNotifications", "palette.jumpUnread", "palette.toggleUnread",
                "palette.markOldestUnreadAndJumpNext"].contains(id) {
            self = .agent
        } else if id == "palette.browseSidebarTemplates" {
            self = .learn
        } else if id.hasPrefix("switcher.") || id.contains("Workspace") || id == "palette.findWork"
            || id == "palette.openFolder" || id == "palette.openFolderInVSCodeInline"
            || id == "palette.reopenPreviousSession" {
            // `palette.moveTabToNewWorkspace` and browser workspace commands are
            // workspace-level too; browser tab/split commands fall through to pane.
            self = .workspace
        } else if [
            "palette.toggleSidebar", "palette.toggleBottomPanel", "palette.toggleFileExplorerHiddenFiles",
            "palette.showImagesAsGrid", "palette.toggleMatchTerminalBackground", "palette.enableMinimalMode",
            "palette.disableMinimalMode", "palette.toggleFullScreen",
        ].contains(id) {
            self = .view
        } else if id.hasPrefix("palette.terminal") || id.hasPrefix("palette.browser")
            || id.contains("Tab") || id.contains("Split") || id.contains("Diff")
            || id.contains("Process") || id == "palette.findInDirectory" || id == "palette.toggleFullWidthTab"
            || id == "palette.equalizeSplits" {
            self = .pane
        } else {
            self = .app
        }
    }

    /// Explicit categories where what the command does differs from the id rule below.
    private static let overrides: [String: CommandPaletteCategory] = [
        "palette.increaseWorkspaceTerminalFontSize": .view,
        "palette.decreaseWorkspaceTerminalFontSize": .view,
        "palette.resetWorkspaceTerminalFontSize": .view,
        "palette.browserZoomIn": .view,
        "palette.browserZoomOut": .view,
        "palette.browserZoomReset": .view,
        "palette.toggleSplitZoom": .view,
        "palette.toggleTerminalCopyMode": .pane,
        "palette.copyPaneLink": .pane,
        "palette.copySurfaceLink": .pane,
        "palette.copyWorkspaceLink": .workspace,
        "palette.toggleFocusedWorkspaceGroupCollapsed": .workspace,
    ]
}
