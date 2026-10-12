import AppKit
import Foundation

/// Open/close entry points for the workspace's bottom panel (the Dock engine
/// hosted under the main split). State lives on `DockSplitStore`; the store is
/// created lazily, so closed workspaces never pay for it.
extension Workspace {
    var isBottomPanelOpen: Bool { _dockSplit?.isBottomPanelOpen == true }

    func toggleBottomPanel() {
        setBottomPanelOpen(!isBottomPanelOpen)
    }

    /// Opens or hides the panel. Opening creates one terminal in the workspace
    /// cwd when the panel is empty and moves focus into it. Hiding keeps every
    /// terminal alive and returns focus to the main area.
    @discardableResult
    func setBottomPanelOpen(_ open: Bool, focus: Bool = true, seedTerminal: Bool = true) -> Bool {
        if open {
            guard let store = dockSplit else { return false }
            if seedTerminal {
                guard store.ensureBottomPanelContent() else { return false }
            } else {
                store.prepareForBottomPanel()
            }
            store.wantsBottomPanelFocusOnAppear = focus
            store.isBottomPanelOpen = true
            objectWillChange.send()
            return true
        }
        guard let store = _dockSplit, store.isBottomPanelOpen else { return false }
        store.wantsBottomPanelFocusOnAppear = false
        store.isBottomPanelOpen = false
        objectWillChange.send()
        if let panelId = focusedPanelId {
            AppDelegate.shared?.noteMainPanelKeyboardFocusIntent(
                workspaceId: id,
                panelId: panelId,
                in: NSApp.keyWindow ?? NSApp.mainWindow
            )
            focusPanel(panelId)
        }
        return true
    }
}
