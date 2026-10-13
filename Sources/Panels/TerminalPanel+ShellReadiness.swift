import BreeWorkspaces

extension TerminalPanel {
    func updateShellActivityState(_ state: PanelShellActivityState) {
        // A returning prompt ends a CLI-reported recovery. A pending container
        // admission owns its own presentation and clears it when it resolves.
        if state == .promptIdle, shellActivity.state == .commandRunning,
           !surface.isAwaitingStartupRestoreAdmission {
            restoreRecovery.state = nil
        }
        let stateChanged = shellActivity.state != state
        if stateChanged {
            shellActivity.state = state
        }
        if state == .promptIdle || state == .commandRunning {
            hostedView.liftStartupVeil(reason: state == .promptIdle ? "prompt" : "command")
        }
        // A repeated report must not restart the probe ladder mid-session.
        if stateChanged {
            TerminalPromptDetectionGateController.shared.shellStateChanged(surface: surface, state: state)
        }
        textBoxState.updateShellActivityState(state)
        shellEditorShellStateDidChange(state)
        if state == .promptIdle {
            surface.shellDidBecomeReadyForStartupInput()
        }
    }
}
