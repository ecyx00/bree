import AppKit

extension Notification.Name {
    /// Something a pane tab bar button reflects changed (Files open, Architecture open).
    static let surfaceTabBarDynamicStateDidChange = Notification.Name("bree.surfaceTabBarDynamicStateDidChange")
}

extension Workspace {
    /// Whether a built-in tab bar button should read as "on" right now.
    func surfaceTabBarButtonIsActive(_ button: BreeSurfaceTabBarButton) -> Bool {
        guard case .builtIn(let action) = button.action else { return false }
        switch action {
        case .toggleFiles:
            return owningTabManager
                .flatMap { AppDelegate.shared?.mainWindowContext(for: $0) }?
                .fileExplorerState?.isVisible ?? false
        case .toggleArchitecture:
            return ArchitectureWindowController.shared.isShowing(for: self)
        case .toggleWiki:
            return WikiPopoverController.shared.isShowing(for: self)
        case .showBoard:
            return BoardPopoverController.shared.isShowing(in: owningTabManager.flatMap { AppDelegate.shared?.mainWindowContext(for: $0) }?.window)
        default:
            return false
        }
    }
}
