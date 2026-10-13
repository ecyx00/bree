import AppKit
import BreeSettingsUI

/// Keyboard-first navigation: focus regions, Quick View toggle, Architecture
/// toggle and the shortcut cheat sheet. Kept out of AppDelegate.swift on purpose.
extension AppDelegate {
    /// Matches the keyboard-navigation actions against `event`. Returns true when
    /// the event was consumed. `preferredWindow` is the main window resolved by the
    /// caller (nil from Quick View, which falls back to the active main window).
    func handleKeyboardNavigationShortcut(event: NSEvent, preferredWindow: NSWindow?) -> Bool {
        guard !KeyboardShortcutRecorderActivity.isAnyRecorderActive,
              !RecorderHostButton.isActivelyRecording else { return false }
        if matchConfiguredShortcut(event: event, action: .focusLeftSidebar) {
            _ = focusRegionInActiveMainWindow(.leftSidebar, preferredWindow: preferredWindow)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .focusTerminal) {
            _ = focusRegionInActiveMainWindow(.terminal, preferredWindow: preferredWindow)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .focusRightSidebarRegion) {
            if !focusRegionInActiveMainWindow(.rightSidebar, preferredWindow: preferredWindow) { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .cycleFocusRegionForward) {
            _ = cycleFocusRegionInActiveMainWindow(forward: true, preferredWindow: preferredWindow)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .cycleFocusRegionBackward) {
            _ = cycleFocusRegionInActiveMainWindow(forward: false, preferredWindow: preferredWindow)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .toggleQuickView) {
            _ = toggleQuickViewFromShortcut(preferredWindow: preferredWindow)
            return true
        }
        if matchConfiguredShortcut(event: event, action: .toggleArchitecture) {
            if !toggleArchitectureFromShortcut(preferredWindow: preferredWindow) { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .toggleWiki) {
            if !toggleWikiFromShortcut(preferredWindow: preferredWindow) { NSSound.beep() }
            return true
        }
        if matchConfiguredShortcut(event: event, action: .showKeyboardShortcuts) {
            KeyboardShortcutsCheatSheetController.shared.toggle()
            return true
        }
        if matchConfiguredShortcut(event: event, action: .showBoard) {
            if !toggleBoardFromShortcut(preferredWindow: preferredWindow) { NSSound.beep() }
            return true
        }
        return false
    }

    @discardableResult
    func focusRegionInActiveMainWindow(_ region: KeyboardFocusRegion, preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        let coordinator = context.keyboardFocusCoordinator
        if region != .quickView, let window = resolvedWindow(for: context) {
            mainWindowVisibilityController.focusForInWindowCommand(window, reason: .focusMainWindow)
        }
        switch region {
        case .leftSidebar:
            if isLeftSidebarListShown(in: context), coordinator.isRegionAvailable(.leftSidebar) {
                return coordinator.focusLeftSidebar()
            }
            // Hidden sidebar (or another sidebar page): reveal the workspace list, then
            // focus once it is mounted.
            context.sidebarState.setVisible(true)
            if !isLeftSidebarListShown(in: context) { context.sidebarSelectionState.selection = .tabs }
            DispatchQueue.main.async { _ = coordinator.focusLeftSidebar() }
            return true
        default:
            return coordinator.focusRegion(region)
        }
    }

    /// Whether the left sidebar is visible and showing the workspace list.
    func isLeftSidebarListShown(in context: MainWindowContext) -> Bool {
        guard context.sidebarState.isVisible else { return false }
        if case .tabs = context.sidebarSelectionState.selection { return true }
        return false
    }

    @discardableResult
    func cycleFocusRegionInActiveMainWindow(forward: Bool, preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        let coordinator = context.keyboardFocusCoordinator
        let current: KeyboardFocusRegion = QuickViewWindowController.keyWindow != nil
            ? .quickView
            : coordinator.currentFocusRegion()
        let target = KeyboardFocusRegion.next(
            after: current,
            forward: forward,
            isAvailable: { [self] region in
                if region == .leftSidebar, !isLeftSidebarListShown(in: context) { return false }
                return coordinator.isRegionAvailable(region)
            }
        )
        guard target != current else { return false }
        return focusRegionInActiveMainWindow(target, preferredWindow: preferredWindow)
    }

    /// Quick View toggle: close it when it has focus, focus it when open, else open
    /// the file selected in Files.
    @discardableResult
    func toggleQuickViewFromShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        if QuickViewWindowController.focusOrCloseVisibleWindow() { return true }
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              let selection = context.keyboardFocusCoordinator.selectedFileForQuickView(),
              let workspace = selection.workspaceId.flatMap({ workspaceFor(tabId: $0) })
                ?? context.tabManager.selectedWorkspace,
              !workspace.isRemoteWorkspace else {
            NSSound.beep()
            return false
        }
        QuickViewResource.file(path: selection.path).open(from: workspace)
        return true
    }

    /// Routes through the built-in action handler, the same path as the surface tab bar button.
    @discardableResult
    func toggleArchitectureFromShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        return executeConfiguredBreeAction(
            .builtIn(.toggleArchitecture),
            context: context,
            preferredWindow: resolvedWindow(for: context)
        )
    }

    /// Routes through the built-in action handler, the same path as the surface tab bar button.
    @discardableResult
    func toggleBoardFromShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        return executeConfiguredBreeAction(
            .builtIn(.showBoard),
            context: context,
            preferredWindow: resolvedWindow(for: context)
        )
    }

    /// Routes through the built-in action handler, the same path as the surface tab bar button.
    @discardableResult
    func toggleWikiFromShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow) else { return false }
        return executeConfiguredBreeAction(
            .builtIn(.toggleWiki),
            context: context,
            preferredWindow: resolvedWindow(for: context)
        )
    }
}

extension AppDelegate {
    /// Cmd+Shift+U and its menu item: blocked agent panes first, then the latest unread.
    func jumpToTopBlockedOrLatestUnread() {
        if !AttentionStore.shared.jumpToTopBlocked() {
            jumpToLatestUnread()
        }
    }
}
