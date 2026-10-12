import AppKit
import Foundation

/// Implemented by the terminal panel that docks a `ShellEditorDockView`.
@MainActor protocol ShellEditorHost: AnyObject {
    var shellEditorWorkingDirectory: String? { get }   // shell cwd for completion/history
    var shellEditorPanelID: UUID { get }                // for per-panel history/draft
    func shellEditorSubmit(_ command: String)           // send the command to the shell
    func shellEditorSendControl(_ key: ShellEditorControlKey) // forwarded when buffer empty
    func shellEditorFocusTerminal()                     // give focus back to the terminal (raw)
    func shellEditorRegisterView(_ view: ShellEditorTextView?) // mounted text view, for focus routing
    func shellEditorViewDidBecomeFirstResponder()       // user or code focused the editor
    func shellEditorCopyTerminalSelection()             // Cmd+C with no editor selection copies the grid's
    var shellEditorProgramInputActive: Bool { get }     // a command runs: the buffer goes to the program
    var shellEditorInputIsMasked: Bool { get }          // PTY ECHO is off (password prompt)
    func shellEditorSubmitProgramInput(_ text: String)  // buffer + Enter to the PTY, never recorded
    func shellEditorForwardKey(_ event: NSEvent, isDown: Bool) // key straight to the program
    @discardableResult func shellEditorFocusEditor(requester: String) -> Bool
}

enum ShellEditorControlKey: Sendable { case interrupt /*^C*/, eof /*^D*/, suspend /*^Z*/, clearScreen /*^L*/ }
