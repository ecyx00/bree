import AppKit
import BreePanes
import BreeSettings

extension AppDelegate {
    func performEqualizeSplitsShortcut() {
        guard let tabManager, let workspace = tabManager.selectedWorkspace else {
#if DEBUG
            breeDebugLog("shortcut.action name=equalizeSplits result=noWorkspace")
#endif
            return
        }
#if DEBUG
        breeDebugLog("shortcut.action name=equalizeSplits workspaceId=\(workspace.id)")
#endif
        if shouldSuppressSplitShortcutForTransientTerminalFocusState(tabManager: tabManager) {
            return
        }
        let didEqualize = tabManager.equalizeSplits(tabId: workspace.id)
#if DEBUG
        if !didEqualize {
            breeDebugLog("shortcut.action name=equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
        }
#endif
    }

    /// New Pane (Auto Layout), bree-tui's Alt-n: adds a terminal pane and
    /// retiles the workspace in Zellij's default layout. Shortcut and
    /// command palette both call this method.
    @discardableResult
    func performAutoLayoutPaneShortcut(preferredWindow: NSWindow? = nil) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let terminalContext = focusedTerminalShortcutContext(preferredWindow: targetWindow)
        let routedManager = synchronizeActiveMainWindowContext(preferredWindow: targetWindow) ?? tabManager
        let didCreate: Bool
        if let terminalContext {
            didCreate = terminalContext.tabManager.createAutoLayoutPaneOutcome(
                tabId: terminalContext.workspaceId,
                surfaceId: terminalContext.panelId
            ).isAccepted
        } else {
            didCreate = routedManager?.createAutoLayoutPaneOutcome().isAccepted ?? false
        }
#if DEBUG
        breeDebugLog("shortcut.action name=newPaneAutoLayout result=\(didCreate ? 1 : 0)")
#endif
        return didCreate
    }

    /// Runs one pane-resize step against the focused split tree. Menu actions,
    /// command-palette commands, and key events all call this method so the
    /// focused Dock and main workspace share the same mutation path.
    @discardableResult
    func performResizePaneShortcut(
        direction: ResizeDirection,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        let targetWindow = preferredWindow ?? shortcutRoutingActiveWindow
        let dock: DockSplitStore?
        switch direction {
        case .left:
            dock = focusedDockStoreForShortcut(action: .resizePaneLeft, preferredWindow: targetWindow)
        case .right:
            dock = focusedDockStoreForShortcut(action: .resizePaneRight, preferredWindow: targetWindow)
        case .up:
            dock = focusedDockStoreForShortcut(action: .resizePaneUp, preferredWindow: targetWindow)
        case .down:
            dock = focusedDockStoreForShortcut(action: .resizePaneDown, preferredWindow: targetWindow)
        }

        if let dock {
            dock.noteKeyboardFocusIntent(window: targetWindow)
            let didResize = dock.performShortcutCommand(.resizePane(direction))
            if !didResize { NSSound.beep() }
#if DEBUG
            breeDebugLog(
                "shortcut.action name=resizePane direction=\(direction) amount=\(PaneResizeStepSettings(defaults: .standard).currentPixels()) "
                    + "result=\(didResize ? 1 : 0) scope=dock"
            )
#endif
            return true
        }

        let manager = activeTabManagerForCommands(preferredWindow: targetWindow)
        let didResize = manager?.resizeFocusedPane(
            direction: direction,
            amount: PaneResizeStepSettings(defaults: .standard).currentPixels()
        ) ?? false
#if DEBUG
        breeDebugLog(
            "shortcut.action name=resizePane direction=\(direction) amount=\(PaneResizeStepSettings(defaults: .standard).currentPixels()) "
                + "result=\(didResize ? 1 : 0) scope=workspace"
        )
#endif
        return didResize
    }

    func handlePaneSizingShortcut(event: NSEvent, equalize: Bool) -> Bool {
        if matchConfiguredShortcut(event: event, action: .newPaneAutoLayout) {
            // A focused Dock has no auto layout; it gets its ordinary split right.
            if routeSplitToFocusedDock(
                kind: .terminal,
                direction: .right,
                action: .newPaneAutoLayout,
                preferredWindow: event.window
            ) {
                return true
            }
            if shouldSuppressSplitShortcutForTransientTerminalFocusState(direction: .right) {
                return true
            }
            _ = performAutoLayoutPaneShortcut(preferredWindow: event.window ?? shortcutRoutingActiveWindow)
            return true
        }
        if equalize {
            if performFocusedDockShortcut(
                .equalizeSplits,
                action: .equalizeSplits,
                event: event
            ) {
                return true
            }
            performEqualizeSplitsShortcut()
            return true
        }

        let paneResizeActions: [(KeyboardShortcutSettings.Action, ResizeDirection)] = [
            (.resizePaneLeft, .left),
            (.resizePaneRight, .right),
            (.resizePaneUp, .up),
            (.resizePaneDown, .down),
        ]
        for (action, direction) in paneResizeActions {
            guard matchConfiguredShortcut(event: event, action: action) else { continue }
            let handledByDock: Bool = switch action {
            case .resizePaneLeft:
                performFocusedDockShortcut(.resizePane(.left), action: .resizePaneLeft, event: event)
            case .resizePaneRight:
                performFocusedDockShortcut(.resizePane(.right), action: .resizePaneRight, event: event)
            case .resizePaneUp:
                performFocusedDockShortcut(.resizePane(.up), action: .resizePaneUp, event: event)
            case .resizePaneDown:
                performFocusedDockShortcut(.resizePane(.down), action: .resizePaneDown, event: event)
            default:
                false
            }
            if handledByDock { return true }
            _ = performResizePaneShortcut(
                direction: direction,
                preferredWindow: event.window ?? shortcutRoutingActiveWindow
            )
            return true
        }

        return false
    }
}
