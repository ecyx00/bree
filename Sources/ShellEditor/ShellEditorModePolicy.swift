import CmuxWorkspaces

/// Pure decision: should the docked shell editor own command input right now.
struct ShellEditorModePolicy: Equatable {
    var settingEnabled: Bool
    var shellState: PanelShellActivityState
    var alternateScreen: Bool
    /// The user toggled raw mode for this prompt.
    var rawMode: Bool
    /// The TextBox wins the dock slot.
    var textBoxActive: Bool
    /// Not remote, not tmux.
    var isLocal: Bool
    /// A command was submitted from the editor and the prompt has not come back
    /// (the shell has not reported `running` yet, or the command already ended).
    var awaitingPrompt: Bool
    /// The PTY foreground process is an agent CLI with its own input box
    /// (see `ShellEditorProcessProbe.agentCommands`): the editor hides and keys go to the terminal.
    var agentForeground: Bool = false

    /// Idle prompt: the editor composes a shell command.
    var isCommandInput: Bool {
        base && shellState == .promptIdle && !awaitingPrompt
    }

    /// A command runs on the main screen (or was just submitted and the
    /// shell has not reported it yet): the editor stays up and its text goes
    /// to the running program. The alternate screen still opts out.
    var isProgramInput: Bool {
        base && !agentForeground
            && (shellState == .commandRunning || (shellState == .promptIdle && awaitingPrompt))
    }

    /// The editor is visible and owns the keyboard.
    var isActive: Bool { isCommandInput || isProgramInput }

    private var base: Bool {
        settingEnabled && !alternateScreen && !rawMode && !textBoxActive && isLocal
    }
}
