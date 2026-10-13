internal import Foundation

/// Builds the shared shell retry state machine for persistent SSH PTY attachment.
///
/// Both app-restored terminals and CLI-created attach commands use this builder
/// so retry limits, backoff, authentication phases, and exit-status handling
/// cannot drift between entrypoints.
public struct SSHPTYAttachRetryScriptBuilder: Sendable {
    /// Creates a persistent SSH PTY retry script builder.
    public init() {}

    /// Builds the shared launch acknowledgement retry functions.
    ///
    /// The caller defines ``<prefix>_register_attempt`` to invoke the local
    /// lifecycle RPC. A timeout is returned as the dedicated launch timeout
    /// status after three acknowledgement attempts; other failures retain
    /// their original status so stale lifecycle rejections remain terminal.
    ///
    /// - Parameter functionPrefix: The shell function prefix, such as
    ///   `bree_ssh` or `bree_ssh_attach`.
    /// - Returns: Shell lines for the bounded registration loop.
    public func launchRegistrationRetryLines(functionPrefix: String) -> [String] {
        [
            "\(functionPrefix)_registration_timed_out=0",
            "\(functionPrefix)_begin_attempt() { \(functionPrefix)_registration_timed_out=0; BREE_SSH_ATTEMPT_ID=$(/usr/bin/uuidgen | /usr/bin/tr '[:upper:]' '[:lower:]') || return 1; export BREE_SSH_ATTEMPT_ID; \(functionPrefix)_attempt_registration_retry=0; while :; do \(functionPrefix)_register_attempt; \(functionPrefix)_attempt_registration_status=$?; if [ \"$\(functionPrefix)_attempt_registration_status\" -eq 0 ]; then return 0; fi; \(functionPrefix)_attempt_registration_retry=$((\(functionPrefix)_attempt_registration_retry + 1)); if [ \"$\(functionPrefix)_attempt_registration_retry\" -ge 3 ]; then if [ \"$\(functionPrefix)_attempt_registration_status\" -eq \(SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue) ]; then \(functionPrefix)_registration_timed_out=1; fi; return \"$\(functionPrefix)_attempt_registration_status\"; fi; /bin/sleep 0.1; done; }",
        ]
    }

    /// Builds shell lines that retry PTY attachment and optional foreground authentication.
    ///
    /// The surrounding script supplies `bree_ssh_attach_foreground_auth` when
    /// `reauthenticates` is true and installs `bree_ssh_attach_signal_exit`
    /// before these lines execute.
    ///
    /// - Parameters:
    ///   - command: Shell command that performs one PTY attachment attempt.
    ///   - reauthenticates: Whether status 255 requires foreground authentication before reattaching.
    ///   - initialAuthentication: Whether the wrapper owns the initial foreground authentication
    ///     phase before its first attach. Compatibility callers that authenticate outside the
    ///     generated loop can disable this while retaining reauthentication after a later loss.
    /// - Returns: macOS `/bin/sh` lines implementing the shared retry state machine.
    public func lines(
        command: String,
        reauthenticates: Bool,
        initialAuthentication: Bool = true
    ) -> [String] {
        let reauthenticate = reauthenticates ? "bree_ssh_attach_reauth_required=1" : ":"
        let authPolicy = SSHForegroundAuthenticationRetryPolicy()
        let authenticationResult = authPolicy.persistentAuthenticationResultShellLine(
            variablePrefix: "bree_ssh_attach",
            terminalFailureCommand: "exit \"$bree_ssh_attach_status\""
        )
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .attach)
        let initialReauthentication = reauthenticates && initialAuthentication ? 1 : 0
        let noProgressPolicy = SSHPTYAttachExitCode.noProgressShellPolicy()
        let retryStatusFormat = String(
            localized: "cli.sshPtyAttach.retryStatus",
            defaultValue: "[Bree] SSH disconnected (%s); retry %s in %ss; input discarded."
        ).remoteCommandShellQuoted
        let hostUnreachableReason = String(
            localized: "cli.sshPtyAttach.retryReason.hostUnreachable",
            defaultValue: "host unreachable"
        ).remoteCommandShellQuoted
        let controlMasterReason = String(
            localized: "cli.sshPtyAttach.retryReason.controlMasterUnavailable",
            defaultValue: "SSH authentication/control unavailable"
        ).remoteCommandShellQuoted
        let daemonNotReadyReason = String(
            localized: "cli.sshPtyAttach.retryReason.daemonNotReady",
            defaultValue: "remote service is starting"
        ).remoteCommandShellQuoted
        let bridgeClosedReason = String(
            localized: "cli.sshPtyAttach.retryReason.bridgeClosed",
            defaultValue: "connection interrupted"
        ).remoteCommandShellQuoted
        let noProgressReason = String(
            localized: "cli.sshPtyAttach.retryReason.noProgress",
            defaultValue: "remote service made no progress"
        ).remoteCommandShellQuoted
        let launchAcknowledgementTimeoutReason = String(
            localized: "cli.sshPtyAttach.retryReason.launchAcknowledgementTimeout",
            defaultValue: "Bree did not acknowledge the SSH launch"
        ).remoteCommandShellQuoted
        let launchAcknowledgementTimeoutLimitFormat = String(
            localized: "cli.sshPtyAttach.launchAcknowledgementTimeoutLimitReached",
            defaultValue: "[Bree] SSH pane could not contact Bree to start the remote session after %s attempts; reconnect to try again."
        ).remoteCommandShellQuoted
        let reconnectedFormat = String(
            localized: "cli.sshPtyAttach.reconnected",
            defaultValue: "[Bree] remote PTY reconnected (attempt %s/%s)."
        ).remoteCommandShellQuoted
        let retryWithoutReauthenticationStatus =
            SSHPTYAttachExitCode.retryableWithoutReauthentication.rawValue
        let hostUnreachableStatus = SSHPTYAttachExitCode.hostUnreachable.rawValue
        let controlMasterUnavailableStatus = SSHPTYAttachExitCode.controlMasterUnavailable.rawValue
        let daemonNotReadyStatus = SSHPTYAttachExitCode.daemonNotReady.rawValue
        let authenticationRequiredStatus = SSHPTYAttachExitCode.authenticationRequired.rawValue
        let noProgressStatus = SSHPTYAttachExitCode.bridgeClosedWithoutProgress.rawValue
        let sessionRunningStatus = SSHPTYAttachExitCode.bridgeClosedSessionRunning.rawValue
        let transientStatus = SSHPTYAttachExitCode.retryableTransient.rawValue
        let launchAcknowledgementTimeoutStatus = SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue
        let terminalModeReset = SSHTerminalModeResetSequence().shellPrintfFormat.remoteCommandShellQuoted
        // Persisted launchers may predate the retry policy.  A missing or
        // malformed limit must fail closed to the same finite supervisor used
        // by newly generated SSH startup scripts; a well-formed larger budget
        // is honored up to the shared ceiling.
        let reconnectLimitLines = SSHReconnectBudget().limitNormalizationShellLines(
            variable: "bree_ssh_attach_reconnect_limit"
        )
        var lines = [
            "bree_ssh_attach_restore_terminal() { bree_ssh_attach_flush_status=0; if [ \"${bree_ssh_attach_input_paused:-0}\" = 1 ] && [ -n \"${bree_ssh_attach_cli:-}\" ]; then \"$bree_ssh_attach_cli\" __ssh-pty-flush-input <&0 >/dev/null 2>&1; bree_ssh_attach_flush_status=$?; fi; bree_ssh_attach_restore_status=0; if [ -n \"${bree_ssh_attach_terminal_state:-}\" ]; then /bin/stty \"$bree_ssh_attach_terminal_state\" <&0 2>/dev/null; bree_ssh_attach_restore_status=$?; fi; bree_ssh_attach_input_paused=0; if [ \"$bree_ssh_attach_flush_status\" -ne 0 ] || [ \"$bree_ssh_attach_restore_status\" -ne 0 ]; then bree_ssh_attach_terminal_control_failed=1; fi; }",
        ]
        lines.append(contentsOf: reconnectLimitLines)
        lines.append(contentsOf: [
            "bree_ssh_attach_reconnect_delay=\"${BREE_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$bree_ssh_attach_reconnect_delay\" in ''|*[!0-9]*|0*) bree_ssh_attach_reconnect_delay=2 ;; esac",
            "bree_ssh_attach_reconnect_max_delay=\"${BREE_SSH_RECONNECT_MAX_DELAY_SECONDS:-30}\"",
            "case \"$bree_ssh_attach_reconnect_max_delay\" in ''|*[!0-9]*|0*) bree_ssh_attach_reconnect_max_delay=30 ;; esac",
            "if [ \"$bree_ssh_attach_reconnect_delay\" -gt \"$bree_ssh_attach_reconnect_max_delay\" ]; then bree_ssh_attach_reconnect_delay=\"$bree_ssh_attach_reconnect_max_delay\"; fi",
            "bree_ssh_attach_reconnect_initial_delay=\"$bree_ssh_attach_reconnect_delay\"",
            "bree_ssh_attach_retry_reason=\(bridgeClosedReason)",
            "bree_ssh_attach_suppress_replay=0",
        ])
        lines.append(contentsOf: noProgressPolicy.configurationLines)
        lines.append(contentsOf: [
            "bree_ssh_attach_no_progress_retry=0",
            "bree_ssh_attach_retry=0",
            "bree_ssh_attach_auth_retry=0",
            "bree_ssh_attach_auth_retry_limit=\(authPolicy.maximumConsecutiveTransientFailures)",
            "bree_ssh_attach_auth_succeeded=0",
            "bree_ssh_attach_reauth_required=\(initialReauthentication)",
            "bree_ssh_attach_auth_launching=0",
            "bree_ssh_attach_auth_event_token=",
            "BREE_SSH_PTY_ATTACH_MANAGED_RECONNECT=1",
            "export BREE_SSH_PTY_ATTACH_MANAGED_RECONNECT",
        ])
        lines.append(contentsOf: backoffBuilder.stateInitializationLines)
        // Host/daemon phases defer foreground auth after a known successful
        // authentication; explicit auth/control failures still take the auth
        // path, preventing credentialed sessions from silently wedging.
        lines.append(contentsOf: [
            "bree_ssh_attach_generate_auth_event_token() {",
            "  bree_ssh_attach_auth_event_token=",
            "  if [ -x /usr/bin/uuidgen ]; then bree_ssh_attach_auth_event_token=$(/usr/bin/uuidgen 2>/dev/null | /usr/bin/tr '[:upper:]' '[:lower:]' || true); fi",
            "  case \"$bree_ssh_attach_auth_event_token\" in ''|*[!A-Za-z0-9_-]*) bree_ssh_attach_auth_event_token= ;; esac",
            "  if [ -z \"$bree_ssh_attach_auth_event_token\" ] && [ -r /dev/urandom ] && [ -x /usr/bin/od ] && [ -x /usr/bin/tr ]; then bree_ssh_attach_auth_event_token=$(/usr/bin/od -An -N16 -tx1 /dev/urandom 2>/dev/null | /usr/bin/tr -d '[:space:]' || true); fi",
            "  case \"$bree_ssh_attach_auth_event_token\" in ''|*[!A-Za-z0-9_-]*) bree_ssh_attach_auth_event_token= ;; esac",
            "}",
            "while :; do",
            "  if [ \"$bree_ssh_attach_reauth_required\" -eq 1 ]; then",
            "    bree_ssh_attach_auth_launching=1",
            "    bree_ssh_attach_generate_auth_event_token",
            "    BREE_SSH_AUTH_EVENT_TOKEN=\"$bree_ssh_attach_auth_event_token\"; export BREE_SSH_AUTH_EVENT_TOKEN",
            "    ( bree_ssh_attach_foreground_auth ) <&0 &",
            "    bree_ssh_attach_auth_pid=$!",
            "    bree_ssh_attach_auth_launching=0",
            "    if [ -n \"${bree_ssh_attach_pending_signal:-}\" ]; then bree_ssh_attach_signal_exit \"$bree_ssh_attach_pending_signal\" \"${bree_ssh_attach_pending_signal_name:-TERM}\"; fi",
            "    wait \"$bree_ssh_attach_auth_pid\"; bree_ssh_attach_status=$?; bree_ssh_attach_auth_pid=; bree_ssh_attach_auth_event_token=; unset BREE_SSH_AUTH_EVENT_TOKEN",
            "    \(authenticationResult)",
            "    case \"$bree_ssh_attach_status\" in 254) bree_ssh_attach_retry_reason=\(hostUnreachableReason) ;; 252) bree_ssh_attach_retry_reason=\(controlMasterReason) ;; esac",
            "  fi",
            "  if [ \"$bree_ssh_attach_reauth_required\" -eq 0 ]; then",
            "  if [ \"$bree_ssh_attach_retry\" -lt \"$bree_ssh_attach_reconnect_limit\" ]; then bree_ssh_attach_can_retry=1; else bree_ssh_attach_can_retry=0; fi",
            "  if [ -t 2 ]; then printf '\\r\\033[2K' >&2 || true; fi",
            "  BREE_SSH_PTY_ATTACH_MANAGED_RECONNECT=1",
            "  BREE_SSH_PTY_ATTACH_SUPPRESS_REPLAY=\"$bree_ssh_attach_suppress_replay\"",
            "  BREE_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY=\"$bree_ssh_attach_can_retry\"",
            "  BREE_SSH_PTY_ATTACH_NO_PROGRESS_RETRY=\"$bree_ssh_attach_no_progress_retry\"",
            "  BREE_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT=\"$bree_ssh_attach_no_progress_limit\"",
            "  export BREE_SSH_PTY_ATTACH_MANAGED_RECONNECT BREE_SSH_PTY_ATTACH_SUPPRESS_REPLAY BREE_SSH_PTY_ATTACH_WRAPPER_CAN_RETRY BREE_SSH_PTY_ATTACH_NO_PROGRESS_RETRY BREE_SSH_PTY_ATTACH_NO_PROGRESS_LIMIT",
            "  \(command)",
            "  bree_ssh_attach_status=$?",
            "  if [ \"$bree_ssh_attach_status\" -ne 0 ] && [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi",
            "  if [ \"$bree_ssh_attach_status\" -eq \(launchAcknowledgementTimeoutStatus) ] && [ \"${bree_ssh_attach_registration_timed_out:-0}\" -ne 1 ]; then exit \"$bree_ssh_attach_status\"; fi",
            "  if [ \"$bree_ssh_attach_status\" -eq 0 ] && [ \"$bree_ssh_attach_retry\" -gt 0 ] && [ -t 2 ]; then printf '\\n\\033[32m%s\\033[0m\\n' \"$(printf \(reconnectedFormat) \"$bree_ssh_attach_retry\" \"$bree_ssh_attach_reconnect_limit\")\" >&2 || true; fi",
            "  case \"$bree_ssh_attach_status\" in",
            "    \(hostUnreachableStatus)) bree_ssh_attach_retry_reason=\(hostUnreachableReason); bree_ssh_attach_no_progress_retry=0; if [ \"$bree_ssh_attach_auth_succeeded\" -eq 0 ]; then \(reauthenticate); fi ;;",
            "    \(controlMasterUnavailableStatus)) bree_ssh_attach_retry_reason=\(controlMasterReason); bree_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    \(daemonNotReadyStatus)) bree_ssh_attach_retry_reason=\(daemonNotReadyReason); bree_ssh_attach_no_progress_retry=0; if [ \"$bree_ssh_attach_auth_succeeded\" -eq 0 ]; then \(reauthenticate); fi ;;",
            "    \(authenticationRequiredStatus)) bree_ssh_attach_retry_reason=\(controlMasterReason); bree_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    \(noProgressStatus)) bree_ssh_attach_retry_reason=\(noProgressReason); bree_ssh_attach_no_progress_retry=$((bree_ssh_attach_no_progress_retry + 1)); bree_ssh_attach_reconnect_delay=\"$bree_ssh_attach_reconnect_initial_delay\"; \(noProgressPolicy.limitReachedCommand) ;;",
            "    \(retryWithoutReauthenticationStatus)) bree_ssh_attach_retry_reason=\(daemonNotReadyReason); bree_ssh_attach_no_progress_retry=0 ;;",
            "    \(sessionRunningStatus)) bree_ssh_attach_retry_reason=\(bridgeClosedReason); bree_ssh_attach_no_progress_retry=0; bree_ssh_attach_reconnect_delay=\"$bree_ssh_attach_reconnect_initial_delay\" ;;",
            "    \(transientStatus)) bree_ssh_attach_retry_reason=\(bridgeClosedReason); bree_ssh_attach_no_progress_retry=0; \(reauthenticate) ;;",
            "    \(launchAcknowledgementTimeoutStatus)) bree_ssh_attach_retry_reason=\(launchAcknowledgementTimeoutReason); bree_ssh_attach_no_progress_retry=0 ;;",
            "    *) exit \"$bree_ssh_attach_status\" ;;",
            "  esac",
            "  fi",
            "  if [ \"$bree_ssh_attach_retry\" -ge \"$bree_ssh_attach_reconnect_limit\" ]; then if [ \"$bree_ssh_attach_status\" -eq \(launchAcknowledgementTimeoutStatus) ]; then printf '\\n\\033[31m%s\\033[0m\\n' \"$(printf \(launchAcknowledgementTimeoutLimitFormat) \"$bree_ssh_attach_reconnect_limit\")\" >&2 || true; fi; exit \"$bree_ssh_attach_status\"; fi",
            "  bree_ssh_attach_retry=$((bree_ssh_attach_retry + 1))",
            "  if [ \"$bree_ssh_attach_retry\" -gt 0 ]; then bree_ssh_attach_suppress_replay=1; fi",
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  if [ -t 2 ]; then printf '\\033[33m%s\\033[0m' \"$(printf \(retryStatusFormat) \"$bree_ssh_attach_retry_reason\" \"$bree_ssh_attach_retry\" \"$bree_ssh_attach_reconnect_delay\")\" >&2 || true; fi",
        ])
        lines.append(contentsOf: backoffBuilder.waitLines)
        lines.append(contentsOf: [
            "  if [ \"$bree_ssh_attach_reconnect_delay\" -lt \"$bree_ssh_attach_reconnect_max_delay\" ]; then bree_ssh_attach_reconnect_delay=$((bree_ssh_attach_reconnect_delay * 2)); if [ \"$bree_ssh_attach_reconnect_delay\" -gt \"$bree_ssh_attach_reconnect_max_delay\" ]; then bree_ssh_attach_reconnect_delay=\"$bree_ssh_attach_reconnect_max_delay\"; fi; fi",
            "done",
        ])
        return lines
    }
}
