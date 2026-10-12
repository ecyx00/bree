import Bonsplit
import SwiftUI

/// Minimal mode removes the title row, so its useful content (other
/// projects' agent chips, right-sidebar toggle) lives in the trailing side of the
/// pane tab bar that touches the window's top-right corner. Bonsplit decides which
/// pane that is and asks this provider for views; it knows no app types.
@MainActor
enum PaneTabBarAccessories {
    static func install(on workspace: Workspace, tabManager: TabManager, fileExplorerState: FileExplorerState) {
        workspace.bonsplitController.paneTabBarAccessoryProvider = { _ in
            PaneTabBarAccessory(trailing: AnyView(Trailing(fileExplorerState: fileExplorerState)))
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
