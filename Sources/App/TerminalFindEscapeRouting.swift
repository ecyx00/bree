import AppKit
import BreeTerminal

@MainActor
func breeCloseFocusedTerminalFindForEscape(event: NSEvent, appDelegate: AppDelegate) -> Bool {
    guard breeFindEventIsPlainEscape(event) else { return false }

    let shortcutWindow = event.window
        ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
        ?? NSApp.keyWindow
        ?? NSApp.mainWindow
    if shortcutWindow?.firstResponder is TextBoxInputTextView {
        return false
    }
    let terminalFindFieldOwnsResponder = breeFindTextFieldOwner(for: shortcutWindow?.firstResponder)?
        .identifier?.rawValue == "TerminalFindSearchTextField"
    let targetTabManager = appDelegate.synchronizeActiveMainWindowContext(preferredWindow: shortcutWindow)

    guard let panel = (targetTabManager ?? appDelegate.tabManager)?.selectedTerminalPanel,
          panel.searchState != nil,
          !shortcutResponderHasMarkedText(shortcutWindow?.firstResponder),
          terminalFindFieldOwnsResponder || appDelegate.allowsTerminalKeyboardFocus(
              workspaceId: panel.workspaceId,
              panelId: panel.id,
              in: shortcutWindow
          ) else {
        return false
    }

#if DEBUG
    breeDebugLog("find.escape.close terminal panel=\(panel.id.uuidString.prefix(5))")
#endif
    panel.hostedView.beginFindEscapeSuppression()
    panel.surface.closeSearchFromExplicitInput()
    panel.hostedView.moveFocus()
    return true
}
