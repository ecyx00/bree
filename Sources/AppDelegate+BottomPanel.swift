import AppKit
import Foundation

extension AppDelegate {
    /// Records that the bottom panel owns keyboard focus in `window`.
    func noteBottomPanelKeyboardFocusIntent(in window: NSWindow?) {
        keyboardFocusCoordinator(for: window)?.noteBottomPanelInteraction()
    }

    /// Toggles the bottom panel of the selected workspace in the routed main window.
    @discardableResult
    func toggleBottomPanelInActiveMainWindow(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let workspace = context.tabManager.selectedWorkspace else {
            return false
        }
        workspace.toggleBottomPanel()
        return true
    }
}
