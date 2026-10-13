extension ShortcutAction {
    /// Which group this action belongs to in the settings pane.
    public var group: Group {
        switch self {
        case .openSettings, .reloadConfiguration, .showHideAllWindows, .globalSearch,
             .newWindow, .closeWindow, .toggleFullScreen, .quit:
            return .app
        case .toggleSidebar, .newTab, .newBrowserWorkspace, .saveLayoutTemplate, .openFolder, .reopenPreviousSession, .goToWorkspace,
             .commandPalette, .agentInbox, .commandPaletteNext, .commandPalettePrevious,
             .showNotifications, .jumpToUnread, .toggleUnread, .markOldestUnreadAndJumpNext,
             .markAllNotificationsRead, .clearAllNotifications,
             .focusRightSidebar, .switchRightSidebarToFiles,
             .switchRightSidebarToSessions, .switchRightSidebarToActivity, .switchRightSidebarToArchitecture,
             .triggerFlash, .reopenClosedWorkspace,
             .focusLeftSidebar, .focusTerminal, .focusRightSidebarRegion,
             .cycleFocusRegionForward, .cycleFocusRegionBackward,
             .toggleQuickView, .toggleArchitecture, .toggleWiki, .showKeyboardShortcuts, .showBoard:
            return .workspace
        case .nextSurface, .prevSurface, .moveSurfaceLeft, .moveSurfaceRight,
             .moveSurfaceToPreviousPane, .moveSurfaceToNextPane,
             .moveSurfaceToPaneLeft, .moveSurfaceToPaneRight,
             .moveSurfaceToPaneUp, .moveSurfaceToPaneDown,
             .selectSurfaceByNumber,
             .nextSidebarTab, .prevSidebarTab,
             .nextSidebarTabInGroup, .prevSidebarTabInGroup,
             .moveWorkspaceUp, .moveWorkspaceDown,
             .focusHistoryBack, .focusHistoryForward, .focusHistoryLast, .selectWorkspaceByNumber,
             .renameTab, .renameWorkspace, .editWorkspaceDescription,
             .toggleChecklistItemComplete,
             .closeTab, .closeOtherTabsInPane, .closeWorkspace,
             .newWorkspaceGroup, .groupSelectedWorkspaces,
             .toggleFocusedWorkspaceGroupCollapsed, .reopenClosedBrowserPanel,
             .newSurface, .toggleTerminalCopyMode, .focusTextBoxInput,
             .cycleTextBoxSubmitAction, .attachTextBoxFile, .sendCtrlFToTerminal, .pasteLastScreenshot, .sizeTerminalToMyWindow,
             .clearScreenKeepScrollback, .toggleShellEditor:
            return .navigation
        case .focusLeft, .focusRight, .focusUp, .focusDown,
             .focusPreviousPane, .focusNextPane, .splitRight, .splitDown, .newPaneAutoLayout,
             .toggleSplitZoom, .increaseWorkspaceTerminalFontSize,
             .decreaseWorkspaceTerminalFontSize, .resetWorkspaceTerminalFontSize,
             .equalizeSplits, .resizePaneLeft, .resizePaneRight,
             .resizePaneUp, .resizePaneDown, .splitBrowserRight, .splitBrowserDown,
             .toggleRightSidebar, .toggleBottomPanel, .fileExplorerOpenSelection, .fileExplorerOpenSelectionFinderAlias,
             .fileExplorerToggleHiddenFiles:
            return .panes
        case .openDiffViewer, .saveFilePreview, .toggleFileEditorWordWrap, .openBrowser, .focusBrowserAddressBar,
             .browserBack, .browserForward, .browserReload, .browserHardReload,
             .browserZoomIn, .browserZoomOut, .browserZoomReset,
             .markdownZoomIn, .markdownZoomOut, .markdownZoomReset,
             .find, .findInDirectory, .findNext, .findPrevious,
             .hideFind, .useSelectionForFind, .toggleBrowserDeveloperTools,
             .showBrowserJavaScriptConsole, .toggleBrowserFocusMode,
             .toggleBrowserDesignMode, .toggleReactGrab,
             .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom, .diffViewerScrollToTop,
             .diffViewerOpenFileSearch, .diffViewerNextFile, .diffViewerPreviousFile,
             .diffViewerNextHunk, .diffViewerPreviousHunk, .diffViewerToggleViewed:
            return .browser
        }
    }

    /// Logical grouping used for sectioning the shortcuts pane.
    public enum Group: String, CaseIterable, Sendable, Hashable {
        /// Application-wide actions.
        case app
        /// Workspace lifecycle and notification actions.
        case workspace
        /// Workspace and surface navigation actions.
        case navigation
        /// Pane layout and focus actions.
        case panes
        /// Browser, viewer, and find actions.
        case browser

        /// The English section title used by shortcut catalog consumers.
        public var title: String {
            switch self {
            case .app: return "App"
            case .workspace: return "Workspace"
            case .navigation: return "Navigation"
            case .panes: return "Panes"
            case .browser: return "Browser & Find"
            }
        }
    }
}
