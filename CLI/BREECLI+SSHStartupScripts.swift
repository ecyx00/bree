import BreeFoundation
import Foundation

extension BREECLI {
    func buildSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        passwordCredential: String? = nil,
        controlPathPreflightShellFunction: String? = nil,
        reconnectLimitDefault: Int = 20,
        launchScripts: SSHStartupLaunchScripts
    ) throws -> String {
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            passwordCredential: passwordCredential,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            oneTimeCommand: nil,
            reconnectLimitDefault: reconnectLimitDefault
        )
        return try writeSSHStartupScript(script, remoteRelayPort: remoteRelayPort, launchScripts: launchScripts)
    }

    func buildReusableSSHStartupCommand(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool = false,
        passwordCredential: String? = nil,
        controlPathPreflightShellFunction: String? = nil,
        oneTimeCommand: String? = nil,
        reconnectLimitDefault: Int = 20
    ) -> String {
        // Reusable commands are persisted in workspace metadata and can be emitted over the socket API.
        // Short-lived credentials must stay in the one-shot launcher path only.
        let script = buildSSHStartupScriptBody(
            sshCommand: sshCommand,
            shellFeatures: shellFeatures,
            remoteRelayPort: remoteRelayPort,
            isShellSnippet: isShellSnippet,
            passwordCredential: nil,
            controlPathPreflightShellFunction: controlPathPreflightShellFunction,
            oneTimeCommand: oneTimeCommand,
            reconnectLimitDefault: reconnectLimitDefault
        )
        return reusableShellStartupCommand(
            scriptBody: script,
            tempPrefix: "bree-ssh-startup"
        )
    }

    func sshAskpassExecShellScript(passwordCredential: String) -> String {
        let passwordB64 = Data(passwordCredential.utf8).base64EncodedString()
        return [
            "set -e",
            "bree_ssh_askpass_dir=$(mktemp -d \"${TMPDIR:-/tmp}/bree-ssh-askpass.XXXXXX\")",
            "bree_ssh_askpass_file=\"$bree_ssh_askpass_dir/password\"",
            "bree_ssh_askpass_script=\"$bree_ssh_askpass_dir/askpass\"",
            "bree_ssh_expect_script=\"$bree_ssh_askpass_dir/ssh-password.exp\"",
            "cleanup() { rm -rf \"$bree_ssh_askpass_dir\"; }",
            "trap cleanup EXIT HUP INT TERM",
            "printf %s \(shellQuote(passwordB64)) | base64 -d > \"$bree_ssh_askpass_file\" 2>/dev/null || printf %s \(shellQuote(passwordB64)) | base64 -D > \"$bree_ssh_askpass_file\"",
            "chmod 600 \"$bree_ssh_askpass_file\"",
            "if command -v expect >/dev/null 2>&1; then",
            "  cat > \"$bree_ssh_expect_script\" <<'BREE_EXPECT'",
            "set timeout 12",
            "set password_file $env(BREE_SSH_ASKPASS_FILE)",
            "set fh [open $password_file r]",
            "set password [read $fh]",
            "close $fh",
            "set password [string trimright $password \"\\r\\n\"]",
            "set bree_interactive_stdin [expr {[catch {exec /bin/sh -c {test -t 0}}] == 0}]",
            "log_user 0",
            "spawn {*}$argv",
            "proc bree_rejected_password {} {",
            "  puts stderr {\\n[Bree] SSH credential was rejected; reconnecting.}",
            "  catch {close}",
            "  catch {wait}",
            "  exit 255",
            "}",
            "proc bree_relay_session {} {",
            "  global bree_interactive_stdin",
            "  set timeout -1",
            "  log_user 1",
            "  if {$bree_interactive_stdin} {",
            "    interact",
            "    set status [wait]",
            "    exit [lindex $status 3]",
            "  }",
            "  expect { eof { set status [wait]; exit [lindex $status 3] } }",
            "}",
            "proc bree_wait_after_password {} {",
            "  set timeout 2",
            "  expect {",
            "    -re \"(?i)permission denied\" { bree_rejected_password }",
            "    -re \"(?i)password:\" { bree_rejected_password }",
            "    timeout {",
            "      set bree_buffer \"\"",
            "      catch { set bree_buffer $expect_out(buffer) }",
            "      if {[regexp -nocase {(password:|permission denied)} $bree_buffer]} { bree_rejected_password }",
            "      if {[string length $bree_buffer] > 0} { send_user -- $bree_buffer }",
            "      bree_relay_session",
            "    }",
            // A session that authenticates and ends inside this window still
            // owes the user its output: flush what expect buffered before exiting.
            "    eof {",
            "      catch { send_user -- $expect_out(buffer) }",
            "      set status [wait]",
            "      exit [lindex $status 3]",
            "    }",
            "  }",
            "}",
            "expect {",
            "  -re \"(?i)password:\" {",
            "    send -- \"$password\\r\"",
            "    bree_wait_after_password",
            "  }",
            "  timeout {",
            "    puts stderr {\\n[Bree] SSH credential prompt timed out; reconnecting.}",
            "    exit 255",
            "  }",
            "  eof { set status [wait]; exit [lindex $status 3] }",
            "}",
            "set status [wait]",
            "exit [lindex $status 3]",
            "BREE_EXPECT",
            "  chmod 700 \"$bree_ssh_expect_script\"",
            "  export BREE_SSH_ASKPASS_FILE=\"$bree_ssh_askpass_file\"",
            "  set +e",
            "  expect \"$bree_ssh_expect_script\" \"$@\"",
            "  bree_ssh_status=$?",
            "  exit \"$bree_ssh_status\"",
            "fi",
            "printf '%s\\n' '#!/bin/sh' 'cat \"$BREE_SSH_ASKPASS_FILE\"' > \"$bree_ssh_askpass_script\"",
            "chmod 700 \"$bree_ssh_askpass_script\"",
            "export BREE_SSH_ASKPASS_FILE=\"$bree_ssh_askpass_file\"",
            "export SSH_ASKPASS=\"$bree_ssh_askpass_script\"",
            "export SSH_ASKPASS_REQUIRE=force",
            "export DISPLAY=\"${DISPLAY:-bree}\"",
            "set +e",
            "\"$@\"",
            "bree_ssh_status=$?",
            "exit \"$bree_ssh_status\"",
        ].joined(separator: "\n")
    }
    func sshAskpassExecShellScript(passwordFilePath: String, cleanupDirectory: String) -> String {
        [
            "set -e",
            "bree_ssh_askpass_dir=\(shellQuote(cleanupDirectory))",
            "bree_ssh_askpass_file=\(shellQuote(passwordFilePath))",
            "bree_ssh_askpass_script=\"$bree_ssh_askpass_dir/askpass\"",
            "bree_ssh_expect_script=\"$bree_ssh_askpass_dir/ssh-password.exp\"",
            "cleanup() { rm -rf \"$bree_ssh_askpass_dir\"; }",
            "trap cleanup EXIT HUP INT TERM",
            "chmod 600 \"$bree_ssh_askpass_file\"",
            "if command -v expect >/dev/null 2>&1; then",
            "  cat > \"$bree_ssh_expect_script\" <<'BREE_EXPECT'",
            "set timeout 12",
            "set password_file $env(BREE_SSH_ASKPASS_FILE)",
            "set fh [open $password_file r]",
            "set password [read $fh]",
            "close $fh",
            "set password [string trimright $password \"\\r\\n\"]",
            "set bree_interactive_stdin [expr {[catch {exec /bin/sh -c {test -t 0}}] == 0}]",
            "log_user 0",
            "spawn {*}$argv",
            "proc bree_rejected_password {} {",
            "  puts stderr {\\n[Bree] SSH credential was rejected; reconnecting.}",
            "  catch {close}",
            "  catch {wait}",
            "  exit 255",
            "}",
            "proc bree_relay_session {} {",
            "  global bree_interactive_stdin",
            "  set timeout -1",
            "  log_user 1",
            "  if {$bree_interactive_stdin} {",
            "    interact",
            "    set status [wait]",
            "    exit [lindex $status 3]",
            "  }",
            "  expect { eof { set status [wait]; exit [lindex $status 3] } }",
            "}",
            "proc bree_wait_after_password {} {",
            "  set timeout 2",
            "  expect {",
            "    -re \"(?i)permission denied\" { bree_rejected_password }",
            "    -re \"(?i)password:\" { bree_rejected_password }",
            "    timeout {",
            "      set bree_buffer \"\"",
            "      catch { set bree_buffer $expect_out(buffer) }",
            "      if {[regexp -nocase {(password:|permission denied)} $bree_buffer]} { bree_rejected_password }",
            "      if {[string length $bree_buffer] > 0} { send_user -- $bree_buffer }",
            "      bree_relay_session",
            "    }",
            // A session that authenticates and ends inside this window still
            // owes the user its output: flush what expect buffered before exiting.
            "    eof {",
            "      catch { send_user -- $expect_out(buffer) }",
            "      set status [wait]",
            "      exit [lindex $status 3]",
            "    }",
            "  }",
            "}",
            "expect {",
            "  -re \"(?i)password:\" {",
            "    send -- \"$password\\r\"",
            "    bree_wait_after_password",
            "  }",
            "  timeout {",
            "    puts stderr {\\n[Bree] SSH credential prompt timed out; reconnecting.}",
            "    exit 255",
            "  }",
            "  eof { set status [wait]; exit [lindex $status 3] }",
            "}",
            "set status [wait]",
            "exit [lindex $status 3]",
            "BREE_EXPECT",
            "  chmod 700 \"$bree_ssh_expect_script\"",
            "  export BREE_SSH_ASKPASS_FILE=\"$bree_ssh_askpass_file\"",
            "  set +e",
            "  expect \"$bree_ssh_expect_script\" \"$@\"",
            "  bree_ssh_status=$?",
            "  exit \"$bree_ssh_status\"",
            "fi",
            "printf '%s\\n' '#!/bin/sh' 'cat \"$BREE_SSH_ASKPASS_FILE\"' > \"$bree_ssh_askpass_script\"",
            "chmod 700 \"$bree_ssh_askpass_script\"",
            "export BREE_SSH_ASKPASS_FILE=\"$bree_ssh_askpass_file\"",
            "export SSH_ASKPASS=\"$bree_ssh_askpass_script\"",
            "export SSH_ASKPASS_REQUIRE=force",
            "export DISPLAY=\"${DISPLAY:-bree}\"",
            "set +e",
            "\"$@\"",
            "bree_ssh_status=$?",
            "exit \"$bree_ssh_status\"",
        ].joined(separator: "\n")
    }
    private func buildSSHStartupScriptBody(
        sshCommand: String,
        shellFeatures: String,
        remoteRelayPort: Int,
        isShellSnippet: Bool,
        passwordCredential: String?,
        controlPathPreflightShellFunction: String?,
        oneTimeCommand: String?,
        reconnectLimitDefault: Int
    ) -> String {
        let trimmedFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)
        let shellFeaturesBootstrap: String = trimmedFeatures.isEmpty
            ? ""
            : "export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedFeatures))"
        let lifecycleCleanup = buildSSHSessionEndShellCommand(remoteRelayPort: remoteRelayPort)
        let lifecycleLaunching = remoteRelayPort > 0
            ? buildSSHTerminalSessionLaunchingShellCommand()
            : ":"
        let trimmedControlPathPreflight = controlPathPreflightShellFunction?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOneTimeCommand = oneTimeCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasOneTimeCommand = trimmedOneTimeCommand?.isEmpty == false
        let authRetryPolicy = SSHForegroundAuthenticationRetryPolicy()
        let authenticationResult = authRetryPolicy.persistentAuthenticationResultShellLine(
            variablePrefix: "bree_ssh",
            terminalFailureCommand: "break"
        )
        let backoffBuilder = SSHRetryBackoffScriptBuilder(context: .startup)
        let terminalModeReset = shellQuote(SSHTerminalModeResetSequence().shellPrintfFormat)
        let reconnectNote = shellQuote(sshAutoReconnectNoteFormat())
        let terminalExitPrompt = shellQuote(sshTerminalExitPromptFormat())
        let reconnectRecoveredNote = shellQuote(sshAutoReconnectRecoveredNoteFormat())
        let launchAcknowledgementTimeoutNote = shellQuote(String(
            localized: "cli.sshPtyAttach.launchAcknowledgementTimeoutRetry",
            defaultValue: "[Bree] Bree did not acknowledge the SSH launch; retrying %s in %ss.",
            bundle: CLIExecutableLocator.enclosingAppBundle() ?? .main
        ))
        let terminalExitPromptCommand = [
            shellQuote(resolvedExecutableURL()?.path ?? (args.first ?? "bree")),
            "__ssh-terminal-exit-prompt",
        ].joined(separator: " ")
        var scriptLines: [String] = []
        if !shellFeaturesBootstrap.isEmpty {
            scriptLines.append(shellFeaturesBootstrap)
        }
        if let passwordCredential, !passwordCredential.isEmpty {
            let passwordB64 = Data(passwordCredential.utf8).base64EncodedString()
            scriptLines += [
                "bree_ssh_askpass_dir=$(mktemp -d \"${TMPDIR:-/tmp}/bree-ssh-askpass.XXXXXX\") || exit 1",
                "bree_ssh_askpass_file=\"$bree_ssh_askpass_dir/password\"",
                "bree_ssh_askpass_script=\"$bree_ssh_askpass_dir/askpass\"",
                "printf %s \(shellQuote(passwordB64)) | base64 -d > \"$bree_ssh_askpass_file\" 2>/dev/null || printf %s \(shellQuote(passwordB64)) | base64 -D > \"$bree_ssh_askpass_file\" || exit 1",
                "chmod 600 \"$bree_ssh_askpass_file\"",
                "printf '%s\\n' '#!/bin/sh' 'cat \"$BREE_SSH_ASKPASS_FILE\"' > \"$bree_ssh_askpass_script\"",
                "chmod 700 \"$bree_ssh_askpass_script\"",
                "export BREE_SSH_ASKPASS_FILE=\"$bree_ssh_askpass_file\"",
                "export SSH_ASKPASS=\"$bree_ssh_askpass_script\"",
                "export SSH_ASKPASS_REQUIRE=force",
                "export DISPLAY=\"${DISPLAY:-bree}\"",
                "bree_ssh_cleanup_password() { rm -rf \"$bree_ssh_askpass_dir\" 2>/dev/null || true; }",
            ]
        } else {
            scriptLines.append("bree_ssh_cleanup_password() { :; }")
        }
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty {
            scriptLines.append(trimmedControlPathPreflight)
        }
        if let trimmedOneTimeCommand, !trimmedOneTimeCommand.isEmpty {
            scriptLines += ["bree_ssh_foreground_auth() {", trimmedOneTimeCommand, "}"]
            scriptLines.append(authRetryPolicy.processTreeTerminationShellFunction())
        }
        let reconnectConfiguration = [
            "bree_ssh_reconnect_limit=\"${BREE_SSH_RECONNECT_LIMIT:-\(max(0, reconnectLimitDefault))}\"",
            "case \"$bree_ssh_reconnect_limit\" in ''|*[!0-9]*) bree_ssh_reconnect_limit=20 ;; esac",
            "bree_ssh_reconnect_delay=\"${BREE_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "case \"$bree_ssh_reconnect_delay\" in ''|*[!0-9]*) bree_ssh_reconnect_delay=2 ;; esac",
            "if [ \"$bree_ssh_reconnect_delay\" -lt 1 ]; then bree_ssh_reconnect_delay=2; fi",
        ]
        scriptLines += [
            "rm -f -- \"$0\" 2>/dev/null || true",
            "BREE_SSH_SESSION_ENDED=0",
            "BREE_SSH_STARTUP_PID=$$",
            "export BREE_SSH_STARTUP_PID",
        ]
        scriptLines += reconnectConfiguration
        scriptLines += [
            "bree_ssh_retry=0",
            "bree_ssh_auth_retry_limit=\(authRetryPolicy.maximumConsecutiveTransientFailures); bree_ssh_auth_retry=0",
            "bree_ssh_auth_succeeded=0",
            // Initial transient foreground-auth failures are a reconnect phase, so boot-time outages share this loop.
            "bree_ssh_reauth_required=\(hasOneTimeCommand ? 1 : 0)",
            "BREE_SSH_CHILD_PID=; BREE_SSH_AUTH_PID=; BREE_SSH_PENDING_SIGNAL=; BREE_SSH_PENDING_SIGNAL_NAME=",
        ]
        scriptLines += backoffBuilder.stateInitializationLines
        scriptLines += [
            "bree_ssh_note() { if [ -t 2 ]; then printf \"$@\" >&2 || true; fi; }",
            "bree_ssh_reset_terminal_modes() { if [ -t 2 ]; then printf \(terminalModeReset) >&2 || true; fi; }",
            "bree_ssh_register_attempt() { \(lifecycleLaunching); }",
        ] + SSHPTYAttachRetryScriptBuilder().launchRegistrationRetryLines(functionPrefix: "bree_ssh") + [
            "bree_ssh_session_end() { if [ \"${BREE_SSH_SESSION_ENDED:-0}\" = 1 ]; then return; fi; BREE_SSH_SESSION_ENDED=1; bree_ssh_cleanup_password; \(lifecycleCleanup); }",
            "bree_ssh_retire_for_signal() { bree_ssh_signal_status=\"$1\"; BREE_SSH_SESSION_ENDED=1; bree_ssh_cleanup_password; trap - EXIT HUP INT TERM; exit \"$bree_ssh_signal_status\"; }",
            "bree_ssh_signal_exit() { bree_ssh_signal_status=\"$1\"; bree_ssh_signal_name=\"$2\"; if [ -n \"${BREE_SSH_AUTH_PID:-}\" ]; then bree_ssh_terminate_auth_process_tree \"$BREE_SSH_AUTH_PID\" \"$BREE_SSH_STARTUP_PID\"; wait \"$BREE_SSH_AUTH_PID\" 2>/dev/null || true; BREE_SSH_AUTH_PID=; \(backoffBuilder.signalHandlerBranches) elif [ -z \"${BREE_SSH_CHILD_PID:-}\" ]; then BREE_SSH_PENDING_SIGNAL=\"$bree_ssh_signal_status\"; BREE_SSH_PENDING_SIGNAL_NAME=\"$bree_ssh_signal_name\"; return; fi; bree_ssh_retire_for_signal \"$bree_ssh_signal_status\"; }",
            "trap 'bree_ssh_session_end' EXIT",
            "trap 'bree_ssh_signal_exit 129 HUP' HUP",
            "trap 'bree_ssh_signal_exit 130 INT' INT",
            "trap 'bree_ssh_signal_exit 143 TERM' TERM",
        ]
        scriptLines += [
            "while :; do",
            "  if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_retire_for_signal \"$BREE_SSH_PENDING_SIGNAL\"; fi",
        ]
        if hasOneTimeCommand {
            scriptLines.append("  if [ \"$bree_ssh_reauth_required\" -eq 1 ]; then")
            scriptLines += ["    ( bree_ssh_foreground_auth ) <&0 &", "    BREE_SSH_AUTH_PID=$!; if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_signal_exit \"$BREE_SSH_PENDING_SIGNAL\" \"${BREE_SSH_PENDING_SIGNAL_NAME:-TERM}\"; fi; wait \"$BREE_SSH_AUTH_PID\"; bree_ssh_status=$?; BREE_SSH_AUTH_PID=; case \"$bree_ssh_status\" in 129|130|143) bree_ssh_retire_for_signal \"$bree_ssh_status\" ;; esac; if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_session_end; trap - EXIT HUP INT TERM; exit \"$BREE_SSH_PENDING_SIGNAL\"; fi", "    \(authenticationResult)", "  fi", "  if [ \"$bree_ssh_reauth_required\" -eq 0 ]; then"]
        }
        if let trimmedControlPathPreflight, !trimmedControlPathPreflight.isEmpty,
           !hasOneTimeCommand {
            scriptLines.append("  bree_ssh_preflight_control_path")
        }
        scriptLines += [
            "  bree_ssh_begin_attempt",
            "  bree_ssh_registration_status=$?",
            "  if [ \"$bree_ssh_registration_status\" -ne 0 ] && [ \"$bree_ssh_registration_status\" -ne \(SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue) ]; then exit \"$bree_ssh_registration_status\"; fi",
            "  if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_retire_for_signal \"$BREE_SSH_PENDING_SIGNAL\"; fi",
        ]
        if isShellSnippet {
            scriptLines += [
                "  if [ \"$bree_ssh_registration_status\" -eq 0 ]; then",
                "    (",
                "      \(sshCommand)",
                "    ) <&0 &",
                "  fi",
            ]
        } else {
            scriptLines += [
                "  if [ \"$bree_ssh_registration_status\" -eq 0 ]; then",
                "    command \(sshCommand) <&0 &",
                "  fi",
            ]
        }
        scriptLines += [
            "  BREE_SSH_CHILD_PID=",
            "  if [ \"$bree_ssh_registration_status\" -eq 0 ]; then BREE_SSH_CHILD_PID=$!; fi",
            "  if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_signal_exit \"$BREE_SSH_PENDING_SIGNAL\"; fi",
            "  if [ \"$bree_ssh_registration_status\" -eq 0 ]; then wait \"$BREE_SSH_CHILD_PID\"; bree_ssh_status=$?; else bree_ssh_status=\"$bree_ssh_registration_status\"; fi",
            "  BREE_SSH_CHILD_PID=",
            "  if [ \"$bree_ssh_status\" -eq \(SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue) ] && [ \"$bree_ssh_registration_status\" -eq 0 ]; then break; fi",
            "  if [ \"$bree_ssh_status\" -eq 0 ]; then if [ \"$bree_ssh_retry\" -gt 0 ]; then bree_ssh_note \"$(printf \(reconnectRecoveredNote) \"$bree_ssh_retry\" \"$bree_ssh_reconnect_limit\")\"; fi; break; fi",
            "  bree_ssh_reset_terminal_modes",
            "  case \"$bree_ssh_status\" in 255|\(SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue)) ;; *) break ;; esac",
        ]
        if hasOneTimeCommand {
            scriptLines += ["  if [ \"$bree_ssh_status\" -eq 255 ]; then bree_ssh_reauth_required=1; fi", "  fi"]
        }
        let retryLimitCondition =
            "  if [ \"$bree_ssh_retry\" -ge \"$bree_ssh_reconnect_limit\" ]; then break; fi"
        scriptLines.append(retryLimitCondition)
        scriptLines += [
            "  bree_ssh_retry=$((bree_ssh_retry + 1))",
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  if [ \"$bree_ssh_status\" -eq \(SSHPTYAttachExitCode.launchAcknowledgementTimedOut.rawValue) ]; then bree_ssh_note \(launchAcknowledgementTimeoutNote) \"$bree_ssh_retry\" \"$bree_ssh_reconnect_delay\"; else bree_ssh_note \(reconnectNote) \"$bree_ssh_status\" \"$bree_ssh_retry\" \"$bree_ssh_reconnect_limit\"; fi",
        ]
        scriptLines += backoffBuilder.waitLines
        scriptLines += [
            "  if [ -n \"${BREE_SSH_PENDING_SIGNAL:-}\" ]; then bree_ssh_session_end; trap - EXIT HUP INT TERM; exit \"$BREE_SSH_PENDING_SIGNAL\"; fi",
            "done",
            "trap - EXIT HUP INT TERM",
            "bree_ssh_session_end",
            "if [ \"$bree_ssh_status\" -ne 0 ]; then",
            "  \(backoffBuilder.terminalInputModeResetLine)",
            "  bree_ssh_prompt_tty_state=$(/bin/stty -g <&0 2>/dev/null || true)",
            "  bree_ssh_prompt_restore_tty() { if [ -n \"${bree_ssh_prompt_tty_state:-}\" ]; then /bin/stty \"$bree_ssh_prompt_tty_state\" <&0 2>/dev/null || true; bree_ssh_prompt_tty_state=; fi; }",
            "  bree_ssh_prompt_signal_exit() { bree_ssh_prompt_signal_status=\"$1\"; bree_ssh_prompt_restore_tty; trap - EXIT HUP INT TERM; exit \"$bree_ssh_prompt_signal_status\"; }",
            "  trap 'bree_ssh_prompt_restore_tty' EXIT",
            "  trap 'bree_ssh_prompt_signal_exit 129' HUP",
            "  trap 'bree_ssh_prompt_signal_exit 130' INT",
            "  trap 'bree_ssh_prompt_signal_exit 143' TERM",
            "  printf \(terminalExitPrompt) \"$bree_ssh_status\" >&2 || true",
            "  if [ -t 0 ]; then \(terminalExitPromptCommand) <&0; else exec \(terminalExitPromptCommand) <&0; fi",
            "  bree_ssh_prompt_restore_tty",
            "  trap - EXIT HUP INT TERM",
            "fi",
            "exit $bree_ssh_status",
        ]
        return scriptLines.joined(separator: "\n")
    }
    private func writeSSHStartupScript(
        _ scriptBody: String,
        remoteRelayPort: Int,
        launchScripts: SSHStartupLaunchScripts
    ) throws -> String {
        let scriptURL = try launchScripts.write(scriptBody: scriptBody, remoteRelayPort: remoteRelayPort)
        return shellQuote(scriptURL.path)
    }
    private func reusableShellStartupCommand(
        scriptBody: String,
        tempPrefix: String
    ) -> String {
        let fullScript = "#!/bin/sh\n\(scriptBody)\n"
        let encodedScript = Data(fullScript.utf8).base64EncodedString()
        let encodedLiteral = shellQuote(encodedScript)
        let wrapper = [
            "bree_tmp=$(mktemp \"${TMPDIR:-/tmp}/\(tempPrefix).XXXXXX\") || exit 1",
            "bree_cleanup() { rm -f -- \"$bree_tmp\" 2>/dev/null || true; }",
            "trap 'bree_cleanup' EXIT HUP INT TERM",
            // Choose the decoder before writing the payload. Repeating the large
            // bootstrap for a fallback can push the launcher past macOS ARG_MAX.
            "if base64 -d </dev/null >/dev/null 2>&1; then bree_decode_flag=-d; else bree_decode_flag=-D; fi",
            "(printf %s \(encodedLiteral) | base64 \"$bree_decode_flag\") > \"$bree_tmp\" || exit 1",
            "chmod 700 \"$bree_tmp\" >/dev/null 2>&1 || true",
            "/bin/sh \"$bree_tmp\"",
            "bree_status=$?",
            "trap - EXIT HUP INT TERM",
            "bree_cleanup",
            "unset bree_tmp bree_decode_flag",
            "unset -f bree_cleanup 2>/dev/null || true",
            "exit $bree_status",
        ].joined(separator: "\n")
        return "/bin/sh -c \(shellQuote(wrapper))"
    }
    private func buildSSHSessionEndShellCommand(remoteRelayPort: Int) -> String {
        [
            "if [ -n \"${BREE_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${BREE_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${BREE_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${BREE_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${BREE_SURFACE_ID:-}\" ]; then",
            "\"${BREE_BUNDLED_CLI_PATH}\" --socket \"${BREE_SOCKET_PATH}\" ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${BREE_WORKSPACE_ID}\" --surface \"${BREE_SURFACE_ID}\" --terminal-lifecycle-id \"${BREE_TERMINAL_LIFECYCLE_ID:-}\" --session-id \"${BREE_SSH_PTY_SESSION_ID:-}\" --lifecycle-id \"${BREE_SSH_PTY_LIFECYCLE_ID:-}\" >/dev/null 2>&1 || true;",
            "elif command -v bree >/dev/null 2>&1",
            "&& [ -n \"${BREE_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${BREE_SURFACE_ID:-}\" ]; then",
            "bree ssh-session-end --relay-port \(remoteRelayPort) --workspace \"${BREE_WORKSPACE_ID}\" --surface \"${BREE_SURFACE_ID}\" --terminal-lifecycle-id \"${BREE_TERMINAL_LIFECYCLE_ID:-}\" --session-id \"${BREE_SSH_PTY_SESSION_ID:-}\" --lifecycle-id \"${BREE_SSH_PTY_LIFECYCLE_ID:-}\" >/dev/null 2>&1 || true;",
            "fi",
        ].joined(separator: " ")
    }

    private func buildSSHTerminalSessionLaunchingShellCommand() -> String {
        let arguments =
            "rpc workspace.remote.terminal_session_launching " +
            "\"{\\\"workspace_id\\\":\\\"${BREE_WORKSPACE_ID}\\\"," +
            "\\\"surface_id\\\":\\\"${BREE_SURFACE_ID}\\\"," +
            "\\\"terminal_lifecycle_id\\\":\\\"${BREE_TERMINAL_LIFECYCLE_ID}\\\"," +
            "\\\"attempt_id\\\":\\\"${BREE_SSH_ATTEMPT_ID}\\\"}\""
        return [
            "if [ -n \"${BREE_BUNDLED_CLI_PATH:-}\" ]",
            "&& [ -x \"${BREE_BUNDLED_CLI_PATH}\" ]",
            "&& [ -n \"${BREE_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${BREE_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${BREE_SURFACE_ID:-}\" ]; then",
            "BREE_CLI_RESPONSE_TIMEOUT_SEC=2 \"${BREE_BUNDLED_CLI_PATH}\" --socket \"${BREE_SOCKET_PATH}\" \(arguments) >/dev/null 2>&1;",
            "elif command -v bree >/dev/null 2>&1",
            "&& [ -n \"${BREE_SOCKET_PATH:-}\" ]",
            "&& [ -n \"${BREE_WORKSPACE_ID:-}\" ]",
            "&& [ -n \"${BREE_SURFACE_ID:-}\" ]; then",
            "BREE_CLI_RESPONSE_TIMEOUT_SEC=2 bree --socket \"${BREE_SOCKET_PATH}\" \(arguments) >/dev/null 2>&1;",
            "else",
            "false;",
            "fi",
        ].joined(separator: " ")
    }
}
