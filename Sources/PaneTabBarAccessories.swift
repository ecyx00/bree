import Bonsplit
import SwiftUI

/// Minimal mode removes the title row, so its useful content (branch, other
/// projects' agent chips, right-sidebar toggle) lives in the trailing side of the
/// pane tab bar that touches the window's top-right corner. Bonsplit decides which
/// pane that is and asks this provider for views; it knows no app types.
@MainActor
enum PaneTabBarAccessories {
    static func install(on workspace: Workspace, tabManager: TabManager, fileExplorerState: FileExplorerState) {
        workspace.bonsplitController.paneTabBarAccessoryProvider = { [weak workspace, weak tabManager] _ in
            guard let workspace, let tabManager else { return nil }
            return PaneTabBarAccessory(
                leading: AnyView(Leading(workspace: workspace, tabManager: tabManager)),
                trailing: AnyView(Trailing(fileExplorerState: fileExplorerState))
            )
        }
    }

    private struct Leading: View {
        let workspace: Workspace
        let tabManager: TabManager

        var body: some View {
            HStack(spacing: 8) {
                TitlebarBranchLabel(workspace: workspace)
            }
            .titlebarInteractiveControl()
            .padding(.trailing, 4)
        }
    }

    /// Only while the right sidebar is closed; zero width otherwise.
    private struct Trailing: View {
        @ObservedObject var fileExplorerState: FileExplorerState

        var body: some View {
            HStack(spacing: 2) {
                TitlebarNotificationsBell()
                    .padding(.leading, 6)
                if !fileExplorerState.isVisible {
                    TitlebarRightSidebarToggle(window: nil)
                }
            }
        }
    }
}
