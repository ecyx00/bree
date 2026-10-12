import CmuxCommandPalette
import CmuxSettings

extension KeyboardShortcutSettings.Action {
    var allowsBareFirstStroke: Bool {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .diffViewerNextFile,
             .diffViewerPreviousFile,
             .diffViewerNextHunk,
             .diffViewerPreviousHunk,
             .diffViewerToggleViewed,
             .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias:
            return true
        default:
            return false
        }
    }

    var isBrowserContentShortcut: Bool {
        switch self {
        case .diffViewerScrollDown,
             .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown,
             .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs,
             .diffViewerScrollUpEmacs,
             .diffViewerScrollToBottom,
             .diffViewerScrollToTop,
             .diffViewerOpenFileSearch,
             .diffViewerNextFile,
             .diffViewerPreviousFile,
             .diffViewerNextHunk,
             .diffViewerPreviousHunk,
             .diffViewerToggleViewed:
            return true
        default:
            return false
        }
    }

    enum ShortcutContext: Equatable {
        case application
        case commandPaletteVisible
        case nonBrowserPanel
        case outsideBrowserPanel
        case browserPanel
        case viewerPanel
        case browserOrFilePreviewTextEditor
        case filePreviewTextEditor
        case markdownPanel
        case rightSidebarFocus

        var isAlwaysAvailable: Bool { self == .application }

        var forwardsMenuEquivalentToFocusedTerminal: Bool {
            switch self {
            case .browserPanel, .browserOrFilePreviewTextEditor:
                return true
            default:
                return false
            }
        }

        /// Evaluates this built-in scope against the current focused content.
        func isAvailable(
            focusedBrowserPanel: Bool,
            focusedMarkdownPanel: Bool,
            focusedFilePreviewTextEditor: Bool = false,
            rightSidebarFocused: Bool
        ) -> Bool {
            switch self {
            case .application: return true
            case .commandPaletteVisible: return false
            case .nonBrowserPanel: return !focusedBrowserPanel && !rightSidebarFocused
            case .outsideBrowserPanel: return !focusedBrowserPanel
            case .browserPanel: return focusedBrowserPanel
            case .viewerPanel: return focusedBrowserPanel || focusedMarkdownPanel
            case .browserOrFilePreviewTextEditor: return focusedBrowserPanel || focusedFilePreviewTextEditor
            case .filePreviewTextEditor: return focusedFilePreviewTextEditor
            case .markdownPanel: return focusedMarkdownPanel
            case .rightSidebarFocus: return rightSidebarFocused
            }
        }

        /// Projects the event’s responder snapshot into this shortcut scope.
        func isAvailable(_ context: ShortcutEventFocusContext) -> Bool {
            return isAvailable(
                focusedBrowserPanel: context.browserPanel != nil,
                focusedMarkdownPanel: context.markdownPanel != nil,
                focusedFilePreviewTextEditor: self == .filePreviewTextEditor
                    ? context.fileEditorFocused
                    : context.filePreviewTextEditorFocused,
                rightSidebarFocused: context.rightSidebarFocused
            )
        }

        /// Evaluates command availability against the palette’s captured panel context.
        func isAvailable(commandPaletteContext context: CommandPaletteContextSnapshot) -> Bool {
            if self == .commandPaletteVisible {
                return true
            }
            return isAvailable(
                focusedBrowserPanel: context.bool(CommandPaletteContextKeys.panelIsBrowser),
                focusedMarkdownPanel: context.bool(CommandPaletteContextKeys.panelIsMarkdown),
                focusedFilePreviewTextEditor: context.bool(CommandPaletteContextKeys.panelIsFilePreviewTextEditor),
                rightSidebarFocused: false
            )
        }

        /// The settings predicate equivalent to this built-in focus scope.
        var defaultWhenClause: ShortcutWhenClause {
            switch self {
            case .application: return .always
            case .commandPaletteVisible: return .key(ShortcutContextKnownKey.commandPaletteVisible.rawValue)
            case .nonBrowserPanel: return .and(.not(.atom(.browserFocus)), .not(.atom(.sidebarFocus)))
            case .outsideBrowserPanel: return .not(.atom(.browserFocus))
            case .browserPanel: return .atom(.browserFocus)
            case .viewerPanel: return .or(.atom(.browserFocus), .atom(.markdownFocus))
            case .browserOrFilePreviewTextEditor:
                return .or(.atom(.browserFocus), .atom(.filePreviewTextEditorFocus))
            case .filePreviewTextEditor:
                return .atom(.filePreviewTextEditorFocus)
            case .markdownPanel: return .atom(.markdownFocus)
            case .rightSidebarFocus: return .atom(.sidebarFocus)
            }
        }

        /// Reports whether two built-in shortcut scopes can be active together.
        func overlaps(_ other: ShortcutContext) -> Bool {
            if self == .application || other == .application || self == other {
                return true
            }
            if self == .outsideBrowserPanel || other == .outsideBrowserPanel {
                let paired = self == .outsideBrowserPanel ? other : self
                return paired != .browserPanel
            }
            if (self == .markdownPanel && other == .nonBrowserPanel)
                || (self == .nonBrowserPanel && other == .markdownPanel) {
                return true
            }
            if self == .viewerPanel || other == .viewerPanel {
                let paired = self == .viewerPanel ? other : self
                switch paired {
                case .browserPanel, .browserOrFilePreviewTextEditor, .markdownPanel, .nonBrowserPanel:
                    return true
                default:
                    return false
                }
            }
            if self == .browserOrFilePreviewTextEditor || other == .browserOrFilePreviewTextEditor {
                let paired = self == .browserOrFilePreviewTextEditor ? other : self
                switch paired {
                case .browserPanel, .nonBrowserPanel, .filePreviewTextEditor:
                    return true
                default:
                    return false
                }
            }
            if self == .filePreviewTextEditor || other == .filePreviewTextEditor {
                let paired = self == .filePreviewTextEditor ? other : self
                switch paired {
                case .nonBrowserPanel, .filePreviewTextEditor:
                    return true
                default:
                    return false
                }
            }
            return false
        }
    }

    var hasPriorityShortcutRouting: Bool {
        switch self {
        case .switchRightSidebarToFiles,
             .switchRightSidebarToSessions, .switchRightSidebarToActivity, .switchRightSidebarToArchitecture,
             .commandPaletteNext, .commandPalettePrevious:
            return true
        default:
            return false
        }
    }

    /// The built-in focus scope used when no configured when clause overrides it.
    var shortcutContext: ShortcutContext {
        switch self {
        case .diffViewerScrollDown, .diffViewerScrollUp,
             .diffViewerScrollHalfPageDown, .diffViewerScrollHalfPageUp,
             .diffViewerScrollDownEmacs, .diffViewerScrollUpEmacs, .diffViewerScrollToBottom,
             .diffViewerScrollToTop:
            return .viewerPanel
        case .diffViewerOpenFileSearch, .diffViewerNextFile, .diffViewerPreviousFile,
             .diffViewerNextHunk, .diffViewerPreviousHunk, .diffViewerToggleViewed:
            return .browserPanel
        case .commandPaletteNext, .commandPalettePrevious:
            return .commandPaletteVisible
        case .switchRightSidebarToFiles, .switchRightSidebarToSessions,
             .switchRightSidebarToActivity, .switchRightSidebarToArchitecture, .fileExplorerOpenSelection,
             .fileExplorerOpenSelectionFinderAlias, .fileExplorerToggleHiddenFiles:
            return .rightSidebarFocus
        case .renameTab, .renameWorkspace, .sendCtrlFToTerminal, .pasteLastScreenshot, .sizeTerminalToMyWindow, .clearScreenKeepScrollback, .toggleShellEditor:
            return .nonBrowserPanel
        case .focusHistoryBack, .focusHistoryForward:
            return .outsideBrowserPanel
        case .browserBack, .browserForward, .browserReload, .browserHardReload,
             .toggleBrowserDeveloperTools, .showBrowserJavaScriptConsole, .toggleBrowserFocusMode,
             .toggleBrowserDesignMode:
            return .browserPanel
        case .browserZoomIn, .browserZoomOut, .browserZoomReset:
            return .browserOrFilePreviewTextEditor
        case .toggleFileEditorWordWrap:
            return .filePreviewTextEditor
        case .markdownZoomIn, .markdownZoomOut, .markdownZoomReset:
            return .markdownPanel
        case .saveLayoutTemplate:
            return .application
        default:
            return .application
        }
    }
}
