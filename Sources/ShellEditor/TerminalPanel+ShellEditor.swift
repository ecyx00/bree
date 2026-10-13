import AppKit
import BreeTerminal
import BreeWorkspaces
import Foundation

// Stored state lives on TerminalPanel (see the hook patch):
//   @Published var shellEditorActive = false
//   @Published var shellEditorFocusRequest = 0
//   var shellEditorRawMode = false
//   var shellEditorAwaitingPrompt = false

extension TerminalPanel: ShellEditorHost {
    static let shellEditorDefaultsKey = "terminal.shellEditor"
    /// Private sequence the shell integrations bind to "clear the line".
    private static let shellEditorKillBuffer = "\u{1B}[9980~"

    /// Re-evaluates the mode policy. Call on every input it reads: shell state,
    /// TextBox visibility, the setting, prompt return. Activation bumps the
    /// focus request. A running command keeps the editor up in program input
    /// mode (text goes to the program); alt screen and agent CLIs opt out. The
    /// alternate screen has no push signal (checked: only the pull
    /// `isAlternateScreenActive`), so it is read here, which runs on every
    /// shell state change and COMMAND_FINISHED, and only when everything else
    /// says "active" (the read serializes the viewport). A full-screen app
    /// first flips the shell state to commandRunning, which deactivates.
    func shellEditorRecompute() {
        let enabled = UserDefaults.standard.object(forKey: Self.shellEditorDefaultsKey) as? Bool ?? true
        var policy = ShellEditorModePolicy(
            settingEnabled: enabled,
            shellState: shellActivity.state,
            alternateScreen: false,
            rawMode: shellEditorRawMode,
            textBoxActive: isTextBoxActive,
            isLocal: !TerminalRemoteMachineClassification.runsOnAnotherMachine(
                surfaceID: id,
                workspaceID: workspaceId
            ),
            awaitingPrompt: shellEditorAwaitingPrompt,
            agentForeground: shellEditorAgentForeground
        )
        // The alt-screen read serializes the viewport: only for a visible panel
        // (the poll re-reads once it becomes visible).
        if policy.isActive, shellEditorPanelIsVisible { policy.alternateScreen = surface.isAlternateScreenActive() }
        let next = policy.isActive
        let program = next && policy.isProgramInput
        if policy.settingEnabled, !shellEditorAgentForeground, policy.shellState == .commandRunning || policy.awaitingPrompt {
            shellEditorStartProgramPoll()
        }
        if program != shellEditorProgramInput {
            shellEditorProgramInput = program
            if !program { shellEditorSetMasked(false) }
            shellEditorTextView?.programModeDidChange(entering: program)
        }
#if DEBUG
        let snapshot = "setting=\(policy.settingEnabled) state=\(policy.shellState.rawValue) alt=\(policy.alternateScreen) raw=\(policy.rawMode) textBox=\(policy.textBoxActive) local=\(policy.isLocal) awaiting=\(policy.awaitingPrompt) -> active=\(next)"
        if snapshot != shellEditorLastPolicyLog {
            shellEditorLastPolicyLog = snapshot
            breeDebugLog("shellEditor.policy panel=\(id.uuidString.prefix(8)) \(snapshot)")
        }
#endif
        guard next != shellEditorActive else { return }
        shellEditorActive = next
        if next {
            shellEditorWantsFocus = true
            if shellEditorIsFocusedPanelInKeyWindow { shellEditorFocusRequest &+= 1 }
        } else if shellEditorOwnsResponder(shellEditorTextView?.window?.firstResponder) {
            // The editor leaves; hand the keyboard back to the terminal.
            shellEditorFocusTerminal()
        }
    }

    // MARK: Focus (mirrors the TextBox: the editor is the panel's focus target)

    /// The editor is active and should keep first responder against the
    /// panel/workspace focus reconcilers.
    /// While active the editor owns keyboard input; only raw mode (which
    /// deactivates it) or a running command / alt screen opts out.
    var shellEditorHoldsFocusIntent: Bool {
        shellEditorActive && !isTextBoxActive
    }

    /// This panel is the focused panel of its workspace in the key window:
    /// the only case where the editor may claim focus without a user action.
    var shellEditorIsFocusedPanelInKeyWindow: Bool {
        guard hostedView.window?.isKeyWindow == true,
              let workspace = AppDelegate.shared?.workspaceFor(tabId: surface.tabId) else { return false }
        return workspace.focusedPanelId == id
    }

    func shellEditorOwnsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder, let textView = shellEditorTextView else { return false }
        if responder === textView { return true }
        return (responder as? NSView)?.isDescendant(of: textView) == true
    }

    func shellEditorRegisterView(_ view: ShellEditorTextView?) {
        if let view { shellEditorTextView = view } else { shellEditorTextView = nil }
    }

    @discardableResult
    func shellEditorFocusEditor(requester: String) -> Bool {
        guard shellEditorActive, let textView = shellEditorTextView, let window = textView.window else {
#if DEBUG
            breeDebugLog("shellEditor.focus requester=\(requester) result=unmounted active=\(shellEditorActive)")
#endif
            return false
        }
        let ok = window.firstResponder === textView || window.makeFirstResponder(textView)
        if ok {
            shellEditorWantsFocus = true
            surface.setFocus(false)
            hostedView.setActive(false)
        }
#if DEBUG
        breeDebugLog("shellEditor.focus requester=\(requester) result=\(ok) firstResponder=\(String(describing: window.firstResponder))")
#endif
        return ok
    }

    func shellEditorViewDidBecomeFirstResponder() {
        // A deliberate click or key focus: own focus.
        shellEditorWantsFocus = true
        hostedView.surfaceView.terminalCompletion.dismiss()  // no orphan grid popup behind the editor
        surface.setFocus(false)
        hostedView.setActive(false)
    }

    /// The terminal grid took first responder (a click in the grid, Esc from
    /// the editor, raw mode). The editor stops claiming focus for this prompt.
    func shellEditorTerminalDidBecomeFocused() {
        // Active editor owns the keyboard: a grid focus (click, drag-select) never releases it.
        guard shellEditorWantsFocus, !shellEditorHoldsFocusIntent else { return }
        if shellEditorPointerRedirect {
#if DEBUG
            breeDebugLog("shellEditor.focus requester=terminalDidBecomeFocused result=keptEditor reason=pointerRedirect")
#endif
            return
        }
#if DEBUG
        breeDebugLog("shellEditor.focus requester=terminalDidBecomeFocused result=editorReleased active=\(shellEditorActive)")
#endif
        shellEditorWantsFocus = false
    }

    /// Called from `updateShellActivityState` after the state is stored.
    func shellEditorShellStateDidChange(_ state: PanelShellActivityState) {
        // Raw mode lasts until the command finishes (COMMAND_FINISHED), so a
        // raw session that starts a command keeps its keys.
        if state == .promptIdle {
            shellEditorAwaitingPrompt = false
        }
        // Every state change re-probes the foreground group.
        shellEditorAgentForeground = false
        shellEditorForegroundCache = nil
        shellEditorRecompute()
    }

    /// Ghostty COMMAND_FINISHED: the in-band signal that the prompt is back.
    func shellEditorCommandFinished() {
        shellEditorAgentForeground = false
        shellEditorForegroundCache = nil
        shellEditorRawMode = false
        shellEditorAwaitingPrompt = false
        shellEditorRecompute()
    }

    /// The Toggle Shell Editor action: editor to raw terminal and back.
    @discardableResult
    func toggleShellEditorRawMode() -> Bool {
        guard shellActivity.state == .promptIdle || shellActivity.state == .commandRunning else { return false }
        shellEditorRawMode.toggle()
        shellEditorRecompute()
        if shellEditorRawMode { shellEditorFocusTerminal() }
        // At the idle prompt the clean-grid shell hides the terminal cursor for
        // the editor's caret; raw mode needs it back (and hidden again on
        // return). Written to the pty slave so it reaches the emulator as
        // output: no zle widget, completion-bridge readiness or typed-input
        // path in between (the earlier ESC[9981~ input route depended on all three).
        if shellActivity.state == .promptIdle, let device = surface.controllingTTYDeviceIdentifier {
            let raw = shellEditorRawMode
            let sequence = raw ? "\u{1B}[?25h" : "\u{1B}[?25l"
            let ok = ShellEditorProcessProbe.writeOutput(sequence, device: device)
#if DEBUG
            breeDebugLog("shellEditor.rawCursor raw=\(raw) written=\(ok) emu=\(surface.debugCursorState())")
#endif
            // The editor strip leaving (or returning) resizes the grid, and the shell redraws
            // its prompt on SIGWINCH; anything in that redraw that touches cursor visibility
            // would undo the write above. Assert the state once more after the redraw settled.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.shellEditorRawMode == raw,
                      self.shellActivity.state == .promptIdle else { return }
                let again = ShellEditorProcessProbe.writeOutput(sequence, device: device)
#if DEBUG
                breeDebugLog("shellEditor.rawCursor.settle raw=\(raw) written=\(again) emu=\(self.surface.debugCursorState())")
#endif
            }
        }
        return true
    }

    // MARK: ShellEditorHost

    var shellEditorWorkingDirectory: String? {
        let raw = directory.isEmpty ? (requestedWorkingDirectory ?? "") : directory
        if raw.isEmpty { return nil }
        if raw.hasPrefix("file://") { return URL(string: raw)?.path }
        return raw
    }

    var shellEditorPanelID: UUID { id }

    func shellEditorSubmit(_ command: String) {
        // An empty Enter only redraws the prompt; nothing to wait for.
        let isEmpty = command.trimmingCharacters(in: .newlines).isEmpty
        if !isEmpty { shellEditorAwaitingPrompt = true }
        shellEditorRecompute()
        // Clear anything typed ahead on the shell's own line, like Warp does
        // (kill buffer, bracketed paste, newline).
        if TerminalCompletionShellBridge.shared.isReady(panel: id) {
            hostedView.surfaceView.terminalCompletionSendRaw(Self.shellEditorKillBuffer)
        }
        let text = command.trimmingCharacters(in: .newlines)
        if !text.isEmpty { _ = surface.sendText(text) }
        _ = surface.sendNamedKey("return")
        // Focus stays in the editor: it continues as the program input box.
    }

    var shellEditorProgramInputActive: Bool { shellEditorProgramInput }
    var shellEditorInputIsMasked: Bool { shellEditorInputMasked }

    /// Buffer submitted while a command runs. Several lines go in as a paste
    /// (Ghostty wraps it in bracketed paste only when the program enabled
    /// that mode, otherwise newlines become CR, i.e. typed). One line is sent
    /// as typed text. Never recorded in history.
    func shellEditorSubmitProgramInput(_ text: String) {
        if text.contains("\n") {
            _ = surface.sendText(text)
        } else if !text.isEmpty {
            _ = surface.sendInput(text)
        }
        _ = surface.sendNamedKey("return")
    }

    /// Forwards a key the editor does not own to the grid unchanged.
    func shellEditorForwardKey(_ event: NSEvent, isDown: Bool) {
        shellEditorForwardingKey = true
        defer { shellEditorForwardingKey = false }
        if isDown { hostedView.surfaceView.keyDown(with: event) } else { hostedView.surfaceView.keyUp(with: event) }
    }

    func shellEditorSetMasked(_ masked: Bool) {
        guard masked != shellEditorInputMasked else { return }
        shellEditorInputMasked = masked
        shellEditorTextView?.maskDidChange()
    }

    // MARK: Program input polling

    /// No push signal exists for the alternate screen, the PTY's ECHO bit or
    /// the foreground process, so while a command runs a task re-reads them:
    /// a tick for termios and the foreground group (syscalls on a GCD queue)
    /// and the policy (alt-screen read, main actor, visible panels only).
    /// Idle-CPU budget: 150 ms for the first 2 s after the command starts,
    /// then 1 s. Polling stops entirely while an agent CLI is the foreground
    /// group; the next state change or COMMAND_FINISHED re-probes.
    func shellEditorStartProgramPoll() {
        guard shellEditorProgramPoll == nil else { return }
        let started = ProcessInfo.processInfo.systemUptime
        shellEditorProgramPoll = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled {
                let fast = ProcessInfo.processInfo.systemUptime - started < 2
                try? await Task.sleep(nanoseconds: fast ? 150_000_000 : 1_000_000_000)
                guard let self else { return }
                guard self.shellActivity.state == .commandRunning || self.shellEditorAwaitingPrompt else {
                    self.shellEditorProgramPoll = nil
                    return
                }
                if self.hostedView.window == nil { continue }
                await self.shellEditorProbeTTY()
                if self.shellEditorAgentForeground {
                    self.shellEditorProgramPoll = nil
                    return
                }
                if !fast || tick % 3 == 0 { self.shellEditorRecompute() }
                tick += 1
            }
        }
    }

    /// The panel is on screen (window visible, view not hidden).
    var shellEditorPanelIsVisible: Bool {
        hostedView.window?.isVisible == true && !hostedView.isHiddenOrHasHiddenAncestor
    }

    private func shellEditorProbeTTY() async {
        guard let device = surface.controllingTTYDeviceIdentifier else {
#if DEBUG
            breeDebugLog("shellEditor.probe device=nil")
#endif
            return
        }
        let cache = shellEditorForegroundCache
        let group = Int32(truncatingIfNeeded: surface.foregroundProcessID() ?? 0)
        let result = await ShellEditorProcessProbe.probe(device: device, group: group, cached: cache)
        guard shellActivity.state == .commandRunning || shellEditorAwaitingPrompt else { return }
        shellEditorForegroundCache = result.pgid.map { (pgid: $0, agent: result.agent) }
        if result.agent != shellEditorAgentForeground {
            shellEditorAgentForeground = result.agent
            shellEditorRecompute()
        }
        if shellEditorProgramInput { shellEditorSetMasked(result.passwordPrompt) }
    }

    func shellEditorSendControl(_ key: ShellEditorControlKey) {
        let name: String
        switch key {
        case .interrupt: name = "ctrl-c"
        case .eof: name = "ctrl-d"
        case .suspend: name = "ctrl-z"
        case .clearScreen: name = "ctrl-l"
        }
        _ = surface.sendNamedKey(name)
    }

    func shellEditorCopyTerminalSelection() {
        hostedView.surfaceView.copy(nil)
    }

    func shellEditorFocusTerminal() {
        shellEditorWantsFocus = false
        hostedView.setActive(true)
        surface.setFocus(true)
        surface.hostedView.ensureFocus(for: surface.tabId, surfaceId: surface.id)
    }
}

/// PTY inspection for the program input mode. Everything here is blocking
/// syscalls: call from a GCD queue only (`probe` does).
enum ShellEditorProcessProbe {
    /// Agent CLIs with their own input box. The editor hides (keys go to the
    /// terminal) while one of these is the PTY foreground process group.
    /// Matched against the basename of each group member's executable path and
    /// of argv[0] / argv[1] (node-launched scripts).
    static let agentCommands: Set<String> = ["claude", "codex"]

    struct Result: Sendable {
        var passwordPrompt = false
        var agent = false
        var pgid: Int32?
    }

    /// ECHO off while still canonical = a line-mode secret prompt (sudo, ssh,
    /// `read -s`). Raw TUIs and REPLs clear ICANON too, so they are not masked.
    static func isPasswordPrompt(lflag: tcflag_t) -> Bool {
        lflag & tcflag_t(ECHO) == 0 && lflag & tcflag_t(ICANON) != 0
    }

    static func isAgent(names: [String]) -> Bool {
        names.contains { agentCommands.contains(($0 as NSString).lastPathComponent.lowercased()) }
    }

    /// Writes `text` to the pty slave of `device`, so the terminal emulator receives it as program
    /// output (cursor visibility and the like). Never the controlling terminal; false on failure.
    @discardableResult
    static func writeOutput(_ text: String, device: Int64) -> Bool {
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(dev_t(device), S_IFCHR, &buffer, Int32(buffer.count)) != nil else { return false }
        let fd = open("/dev/" + String(cString: buffer), O_WRONLY | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    static func probe(device: Int64, group: Int32, cached: (pgid: Int32, agent: Bool)?) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: probeSync(device: device, group: group, cached: cached))
            }
        }
    }

    private static func probeSync(device: Int64, group: Int32, cached: (pgid: Int32, agent: Bool)?) -> Result {
        var buffer = [CChar](repeating: 0, count: 64)
        guard let name = devname_r(dev_t(device), S_IFCHR, &buffer, Int32(buffer.count)) else {
#if DEBUG
            breeDebugLog("shellEditor.probe devname_r failed dev=\(device)")
#endif
            return Result()
        }
        // The slave side, read-only, never the controlling terminal.
        let fd = open("/dev/" + String(cString: name), O_RDONLY | O_NONBLOCK | O_NOCTTY)
        guard fd >= 0 else {
#if DEBUG
            breeDebugLog("shellEditor.probe open failed errno=\(errno)")
#endif
            return Result()
        }
        defer { close(fd) }
        var result = Result()
        var term = termios()
        if tcgetattr(fd, &term) == 0 { result.passwordPrompt = isPasswordPrompt(lflag: term.c_lflag) }
        // The group comes from libghostty (tcgetpgrp on the master side): on
        // macOS tcgetpgrp on the slave fails with ENOTTY for any process that
        // does not have it as controlling terminal, which is always the case here.
        guard group > 0 else { return result }
        result.pgid = group
        // Only a positive result is cached: a group probed between fork and exec
        // still carries the shell's name and would stay "not an agent" forever.
        if let cached, cached.pgid == group, cached.agent {
            result.agent = true
        } else {
            let found = names(ofGroup: group)
            result.agent = isAgent(names: found)
#if DEBUG
            breeDebugLog("shellEditor.probe pgid=\(group) agent=\(result.agent) names=\(found)")
#endif
        }
        return result
    }

    /// Executable path, argv[0] and argv[1] of every process in the group.
    private static func names(ofGroup group: Int32) -> [String] {
        var pids = [pid_t](repeating: 0, count: 64)
        // proc_listpgrppids returns a pid count on current macOS, not bytes (the old
        // code divided it by 4 and saw an empty group); proc_listpids returns bytes.
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        var out: [String] = []
        for pid in pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where pid > 0 {
            var path = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &path, UInt32(path.count)) > 0 { out.append(String(cString: path)) }
            out += arguments(of: pid).prefix(2)
        }
        return out
    }

    /// argv via KERN_PROCARGS2: argc (Int32), exec path, NUL padding, then argv strings.
    private static func arguments(of pid: pid_t) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var data = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &data, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        let argc = data.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, data[index] != 0 { index += 1 }   // exec path
        while index < size, data[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while index < size, args.count < argc {
            let start = index
            while index < size, data[index] != 0 { index += 1 }
            args.append(String(decoding: data[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }
}

extension GhosttyNSView {
    /// The panel whose editor is active and owns the keyboard intent, if this grid belongs to one.
    var shellEditorPanelHoldingFocus: TerminalPanel? {
        guard let terminalSurface,
              let panel = AppDelegate.shared?.workspaceFor(tabId: terminalSurface.tabId)?.panels[terminalSurface.id] as? TerminalPanel,
              panel.shellEditorHoldsFocusIntent
        else { return nil }
        return panel
    }

    /// A key reached the grid while the editor is active: hand it to the editor.
    func redirectKeyToShellEditor(_ event: NSEvent) -> Bool {
        guard !event.modifierFlags.contains(.command), let panel = shellEditorPanelHoldingFocus,
              !panel.shellEditorForwardingKey,
              panel.shellEditorFocusEditor(requester: "gridKeyDown"),
              let editor = panel.shellEditorTextView else { return false }
#if DEBUG
        breeDebugLog("shellEditor.focus redirect=keyDown code=\(event.keyCode)")
#endif
        editor.keyDown(with: event)
        return true
    }

    /// The editor is forwarding this key to the grid on purpose.
    var shellEditorIsForwardingKey: Bool {
        guard let terminalSurface,
              let panel = AppDelegate.shared?.workspaceFor(tabId: terminalSurface.tabId)?.panels[terminalSurface.id] as? TerminalPanel
        else { return false }
        return panel.shellEditorForwardingKey
    }
}
