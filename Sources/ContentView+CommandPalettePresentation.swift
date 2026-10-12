// Command execution policy shared by palette selection and focus restoration.
extension ContentView {
    static func commandPaletteShouldDismissBeforeRun(forCommandId commandId: String) -> Bool {
        switch commandId {
        case "palette.forkAgentConversationRight",
             "palette.forkAgentConversationLeft",
             "palette.forkAgentConversationTop",
             "palette.forkAgentConversationBottom",
             "palette.forkAgentConversationNewTab",
             "palette.forkAgentConversationNewWorkspace",
             "palette.layout.saveCurrent",
             "palette.swapWithSession",
             // The pop-up menu would close together with the palette otherwise.
             "palette.openPinnedFile",
             // Entering browser focus mode focuses the web view synchronously;
             // dismiss the palette first so its makeFirstResponder(nil) doesn't
             // clear that focus and leave focus mode active without key routing.
             "palette.browserFocusMode",
             // Pane focus moves the first responder synchronously; dismissing
             // afterwards would clear it with makeFirstResponder(nil).
             "palette.focusPaneLeft",
             "palette.focusPaneRight",
             "palette.focusPaneUp",
             "palette.focusPaneDown",
             "palette.focusPreviousPane",
             "palette.focusNextPane":
            return true
        default:
            return false
        }
    }
}
