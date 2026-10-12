import AppKit
import Bonsplit
import CmuxPanes

extension KeyboardShortcutSettings.Action {
    /// Selects whether an action resolves through the Dock, responder, or main workspace.
    var dockShortcutRoutingDisposition:
        DockShortcutRoutingDisposition {
        switch self {
        case .triggerFlash,
             .nextSurface, .prevSurface,
             .moveSurfaceLeft, .moveSurfaceRight,
             .moveSurfaceToPreviousPane, .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft, .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp, .moveSurfaceToPaneDown,
             .selectSurfaceByNumber,
             .focusHistoryBack, .focusHistoryForward, .focusHistoryLast,
             .renameTab,
             .closeTab, .closeOtherTabsInPane,
             .reopenClosedBrowserPanel,
             .newSurface,
             .toggleTerminalCopyMode,
             .focusTextBoxInput, .attachTextBoxFile,
             .sendCtrlFToTerminal,
             .pasteLastScreenshot,
             .clearScreenKeepScrollback,
             .focusLeft, .focusRight, .focusUp, .focusDown,
             .focusPreviousPane, .focusNextPane,
             .splitRight, .splitDown, .newPaneAutoLayout, .toggleSplitZoom,
             .resizePaneLeft, .resizePaneRight, .resizePaneUp, .resizePaneDown,
             .equalizeSplits,
             .splitBrowserRight, .splitBrowserDown,
             .openBrowser, .focusBrowserAddressBar,
             .find, .findNext, .findPrevious, .hideFind,
             .useSelectionForFind,
             .toggleReactGrab:
            .dockScoped

        case .commandPaletteNext, .commandPalettePrevious,
             .toggleChecklistItemComplete,
             .cycleTextBoxSubmitAction,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias,
             .fileExplorerToggleHiddenFiles,
             .saveFilePreview,
             .toggleFileEditorWordWrap,
             .browserBack, .browserForward,
             .browserReload, .browserHardReload,
             .browserZoomIn, .browserZoomOut, .browserZoomReset,
             .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole,
             .toggleBrowserFocusMode,
             .toggleBrowserDesignMode,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .diffViewerNextFile, .diffViewerPreviousFile,
             .diffViewerNextHunk, .diffViewerPreviousHunk, .diffViewerToggleViewed:
            .focusResolved

        case .openSettings, .reloadConfiguration,
             .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit,
             .toggleSidebar, .newTab, .newBrowserWorkspace,
             .saveLayoutTemplate, .openFolder,
             .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .agentInbox,
             .showNotifications, .jumpToUnread, .toggleUnread,
             .markOldestUnreadAndJumpNext,
             .markAllNotificationsRead, .clearAllNotifications,
             .focusRightSidebar,
             .focusLeftSidebar, .focusTerminal, .focusRightSidebarRegion,
             .cycleFocusRegionForward, .cycleFocusRegionBackward,
             .toggleQuickView, .toggleArchitecture, .toggleWiki, .showKeyboardShortcuts,
             .switchRightSidebarToFiles,
             .switchRightSidebarToSessions,
             .switchRightSidebarToActivity,
             .switchRightSidebarToArchitecture,
             .nextSidebarTab, .prevSidebarTab,
             .nextSidebarTabInGroup, .prevSidebarTabInGroup,
             .moveWorkspaceUp, .moveWorkspaceDown,
             .selectWorkspaceByNumber,
             .renameWorkspace, .editWorkspaceDescription,
             .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed,
             .reopenClosedWorkspace,
             .sizeTerminalToMyWindow,
             .toggleShellEditor,
             .increaseWorkspaceTerminalFontSize,
             .decreaseWorkspaceTerminalFontSize,
             .resetWorkspaceTerminalFontSize,
             .toggleRightSidebar,
             .toggleBottomPanel,
             .findInDirectory,
             .openDiffViewer:
            .mainContainer
        }
    }
}

/// Routes "create a surface" keyboard shortcuts (New Browser, New Terminal,
/// Split Right/Down) into the panel when the panel currently owns keyboard focus.
///
/// Without this, every creation shortcut targets the main content `tabManager`,
/// so pressing e.g. Cmd+Shift+L while a Dock pane is focused spawned a browser in
/// the main split tree instead of the Dock. Mirrors the existing focus-gated
/// routing in `closeFocusedDockPanelForCommand` (`Workspace+DockBrowserLookup.swift`):
/// the gate is the focus coordinator's `.bottomPanel` intent, and the Dock is
/// the selected workspace's bottom panel.
extension AppDelegate {
    /// The Dock store that should receive a creation/split shortcut when the Dock
    /// owns keyboard focus in `preferredWindow`, else `nil` (caller falls through
    /// to the main-area path).
    func focusedDockStoreForShortcut(preferredWindow: NSWindow?) -> DockSplitStore? {
        guard let context = preferredRegisteredMainWindowContext(preferredWindow: preferredWindow),
              case .bottomPanel = context.keyboardFocusCoordinator.intent,
              let dock = context.tabManager.selectedWorkspace?._dockSplit,
              dock.isBottomPanelOpen else {
            return nil
        }
        return dock
    }

    func focusedDockStoreForShortcut(
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> DockSplitStore? {
        guard case .dockScoped =
            action.dockShortcutRoutingDisposition else {
            assertionFailure(
                "Non-Dock-scoped shortcut requested the Dock gate: " +
                    action.rawValue
            )
            return nil
        }
        return focusedDockStoreForShortcut(
            preferredWindow: preferredWindow
        )
    }

    /// Creates a New Terminal / New Browser surface in the focused Dock pane.
    /// Returns the created Dock panel id when handled, or `nil` to fall through to
    /// the main-area creation path.
    @discardableResult
    func routeCreateToFocusedDock(
        _ kind: DockSurfaceKind,
        focusAddressBar: Bool,
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> UUID? {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return nil
        }
        guard let store = focusedDockStoreForShortcut(
                  action: action,
                  preferredWindow: preferredWindow
              ),
              let pane = store.resolvePane(requestedPaneID: nil),
              let panelId = store.newSurfaceFromDockAffordance(
                  kind: kind,
                  inPane: pane,
                  window: preferredWindow
              ) else {
            return nil
        }
        if focusAddressBar, kind == .browser, let browser = store.browserPanel(for: panelId) {
            focusBrowserAddressBar(in: browser)
        }
        return panelId
    }

    /// Splits the focused Dock pane (terminal or browser). Returns `true` when
    /// handled, or `false` to fall through to the main-area split path. Reuses the
    /// main area's `SplitDirection` → orientation/insert mapping so Dock splits
    /// match the main split affordances (Cmd+D = side-by-side, Cmd+Shift+D = stacked).
    @discardableResult
    func routeSplitToFocusedDock(
        kind: DockSurfaceKind,
        direction: SplitDirection,
        action: KeyboardShortcutSettings.Action,
        preferredWindow: NSWindow?
    ) -> Bool {
        if kind == .browser, !BrowserAvailabilitySettings.isEnabled() {
            return false
        }
        guard let store = focusedDockStoreForShortcut(
            action: action,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        store.noteKeyboardFocusIntent(window: preferredWindow)
        guard let panelId = store.newSplit(
            kind: kind,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst,
            sourcePanelId: store.focusedPanelId,
            focus: false
        ) else {
            return false
        }
        store.focusPanelFromDockInteraction(
            panelId,
            window: preferredWindow
        )
        if kind == .browser,
           let browser = store.browserPanel(for: panelId) {
            _ = focusBrowserAddressBar(in: browser)
        }
        return true
    }

    /// Executes a semantic surface/focus command when the Dock owns keyboard
    /// focus. Callers invoke this from the command's existing dispatcher
    /// position so configured and compatibility shortcuts keep the same
    /// conflict precedence as the main area.
    func performFocusedDockShortcut(
        _ command: DockShortcutCommand,
        action: KeyboardShortcutSettings.Action,
        event: NSEvent
    ) -> Bool {
        guard let store = focusedDockStoreForShortcut(
            action: action,
            preferredWindow: event.window
        ) else {
            return false
        }
        if command.isFocusHistoryNavigation, !store.focusHistoryIncludesPanesAndTabs {
            return false
        }
        if !store.performShortcutCommand(command) { NSSound.beep() }
        return true
    }

}
