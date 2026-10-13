import BreeFoundation
import SwiftUI

/// Git branch of the selected workspace, shown after the workspace name in the window title row.
/// Machine text (branch) is SF Mono, secondary colour. Renders nothing without a branch.
struct TitlebarBranchLabel: View {
    let workspace: Workspace?

    var body: some View {
        if let workspace {
            Inner(workspace: workspace)
        }
    }

    private struct Inner: View {
        @ObservedObject var workspace: Workspace
        @Environment(\.breePalette) private var palette

        var body: some View {
            if let branch = workspace.gitBranch?.branch, !branch.isEmpty {
                Text(branch)
                    .breeFont(.mono)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Far-right row-1 control that opens the right sidebar. Shown only while the sidebar is closed:
/// when it is open, the same glyph in the panel header closes it (one control per job).
struct TitlebarRightSidebarToggle: View {
    @Environment(\.breePalette) private var palette
    let window: NSWindow?
    @State private var isHovering = false

    var body: some View {
        let shortcut = KeyboardShortcutSettings.Action.toggleRightSidebar
        let title = String(localized: "rightSidebar.toggle.tooltip", defaultValue: "Toggle right sidebar")
        Button {
            _ = AppDelegate.shared?.toggleRightSidebarInActiveMainWindow(preferredWindow: window)
        } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(palette.textSecondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovering ? palette.hoverFill : Color.clear))
                .accessibilityLabel(title)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .safeHelp(shortcut.tooltip(title))
        .accessibilityLabel(title)
        .accessibilityIdentifier("Titlebar.rightSidebarToggle")
        .titlebarInteractiveControl()
    }
}
