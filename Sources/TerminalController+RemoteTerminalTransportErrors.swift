import BreeCore
import BreeControlSocket
import BreeFoundation
import Foundation

extension TerminalController {
    func remoteTerminalProfileConfiguration(
        _ params: [String: Any]
    ) -> (profile: WorkspaceRemoteTerminalProfile, error: ControlCallResult?) {
        guard let profile = WorkspaceRemoteTerminalProfile(
            remoteConfigurationValue: v2RawString(params, "terminal_profile"),
            tmuxSessionName: v2RawString(params, "terminal_tmux_session")
        ) else {
            return (.shell, invalidRemoteTerminalProfileResult())
        }
        return (profile, nil)
    }

    func remoteTransportConfiguration(
        _ params: [String: Any]
    ) -> (
        terminal: WorkspaceRemoteTerminalTransport,
        error: ControlCallResult?
    ) {
        guard let terminal = WorkspaceRemoteTerminalTransport(
            remoteConfigurationValue: v2RawString(params, "terminal_transport")
        ) else {
            return (.ssh, invalidRemoteTerminalTransportResult())
        }
        return (terminal, nil)
    }

    func invalidRemoteTerminalTransportResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalTransport.invalid",
                defaultValue: "The remote terminal transport must be SSH or Mosh."
            ),
            data: nil
        )
    }

    func invalidRemoteTerminalProfileResult() -> ControlCallResult {
        .err(
            code: "invalid_params",
            message: String(
                localized: "socket.workspace.remote.terminalProfile.invalid",
                defaultValue: "The remote terminal must open a shell or a valid named tmux session."
            ),
            data: nil
        )
    }
}
