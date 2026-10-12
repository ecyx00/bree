import AppKit
import Bonsplit
import CmuxPanes

enum GhosttyGotoSplitRoute {
    case direction(NavigationDirection)
    case previous
    case next
}


extension AppDelegate {
    /// Moves pane focus in the main workspace area. The focus shortcuts and
    /// the command palette both end here, so they share one mutation path.
    ///
    /// - Returns: Whether a pane focus move was attempted.
    @discardableResult
    static func moveMainAreaPaneFocus(
        _ route: GhosttyGotoSplitRoute,
        tabManager: TabManager?,
        window: NSWindow?
    ) -> Bool {
        cmuxRememberFindSelectionBeforePanelFocusMove(tabManager: tabManager, window: window)
        switch route {
        case .direction(let direction):
            tabManager?.movePaneFocus(direction: direction)
            return tabManager != nil
        case .previous:
            return tabManager?.cyclePaneFocus(forward: false) ?? false
        case .next:
            return tabManager?.cyclePaneFocus(forward: true) ?? false
        }
    }

    /// Runs a pane focus move from a non-keyboard entrypoint (command palette).
    ///
    /// - Returns: Whether the move was handled.
    @discardableResult
    func performPaneFocusShortcut(
        _ route: GhosttyGotoSplitRoute,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        return AppDelegate.moveMainAreaPaneFocus(
            route,
            tabManager: activeTabManagerForCommands(preferredWindow: targetWindow),
            window: targetWindow
        )
    }

    /// Focuses the TextBox composer from a menu or command entrypoint. The
    /// terminal panel owns the same focus toggle as the keyboard shortcut:
    /// the first invocation reveals/focuses TextBox and the next returns focus
    /// to the terminal.
    @discardableResult
    func performFocusTextBoxInputShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        return activeTabManagerForCommands(preferredWindow: targetWindow)?
            .focusFocusedTerminalTextBoxInputOrTerminal() ?? false
    }

    /// Toggles terminal copy mode from a non-keyboard entrypoint (command
    /// palette), matching the `toggleTerminalCopyMode` shortcut.
    ///
    /// - Returns: Whether a focused terminal toggled copy mode.
    @discardableResult
    func performToggleTerminalCopyModeShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        return activeTabManagerForCommands(preferredWindow: targetWindow)?
            .toggleFocusedTerminalCopyMode() ?? false
    }


    func matchesLegacyNextSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: false, option: false, control: true)
        )
    }

    func matchesLegacyPreviousSurfaceShortcut(event: NSEvent) -> Bool {
        matchTabShortcut(
            event: event,
            shortcut: StoredShortcut(key: "\t", command: false, shift: true, option: false, control: true)
        )
    }

    func ghosttyGotoSplitShortcut(for direction: NavigationDirection) -> StoredShortcut? {
        switch direction {
        case .left: ghosttyGotoSplitLeftShortcut
        case .right: ghosttyGotoSplitRightShortcut
        case .up: ghosttyGotoSplitUpShortcut
        case .down: ghosttyGotoSplitDownShortcut
        }
    }

    func ghosttyGotoSplitShortcut(for route: GhosttyGotoSplitRoute) -> StoredShortcut? {
        switch route {
        case let .direction(direction):
            ghosttyGotoSplitShortcut(for: direction)
        case .previous:
            ghosttyGotoSplitPreviousShortcut
        case .next:
            ghosttyGotoSplitNextShortcut
        }
    }

    /// Ghostty's imported `goto_split` bindings are compatibility fallbacks, not
    /// peers of cmux's live shortcut configuration. Any configured cmux action
    /// that currently owns the stroke wins. Keeping this arbitration in one
    /// place prevents cached Ghostty bindings from shadowing later handlers
    /// after a Settings rebind.
    func matchesGhosttyGotoSplitFallback(
        event: NSEvent,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        guard event.type == .keyDown,
              let shortcut = ghosttyGotoSplitShortcut(for: route),
              matchesRawGhosttyGotoSplitShortcut(event: event, shortcut: shortcut, route: route) else {
            return false
        }

        return !KeyboardShortcutSettings.Action.allCases.contains { action in
            liveConfiguredShortcut(action, owns: event)
        }
    }

    private func matchesRawGhosttyGotoSplitShortcut(
        event: NSEvent,
        shortcut: StoredShortcut,
        route: GhosttyGotoSplitRoute
    ) -> Bool {
        switch route {
        case let .direction(direction):
            let directionalKey = directionalArrowKey(for: direction)
            return matchDirectionalShortcut(
                event: event,
                shortcut: shortcut,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        case .previous, .next:
            guard !shortcut.hasChord else { return false }
            return matchShortcutStroke(event: event, stroke: shortcut.firstStroke)
        }
    }

    private func liveConfiguredShortcut(
        _ action: KeyboardShortcutSettings.Action,
        owns event: NSEvent
    ) -> Bool {
        if action.usesNumberedDigitMatching {
            return routableNumberedConfiguredShortcutDigit(event: event, action: action) != nil
        }

        let directionalKey: (glyph: String, keyCode: UInt16)? = switch action {
        case .focusLeft: directionalArrowKey(for: .left)
        case .focusRight: directionalArrowKey(for: .right)
        case .focusUp: directionalArrowKey(for: .up)
        case .focusDown: directionalArrowKey(for: .down)
        default: nil
        }
        if let directionalKey {
            return matchConfiguredDirectionalShortcut(
                event: event,
                action: action,
                arrowGlyph: directionalKey.glyph,
                arrowKeyCode: directionalKey.keyCode
            )
        }
        return matchConfiguredShortcut(event: event, action: action)
    }

    private func directionalArrowKey(
        for direction: NavigationDirection
    ) -> (glyph: String, keyCode: UInt16) {
        switch direction {
        case .left: ("←", 123)
        case .right: ("→", 124)
        case .up: ("↑", 126)
        case .down: ("↓", 125)
        }
    }
}
