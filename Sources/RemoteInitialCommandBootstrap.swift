import Foundation

/// Stages a remote workspace command for one execution by the first interactive shell.
struct RemoteInitialCommandBootstrap {
    private let encodedCommand: String?
    private let protectsFromHangup: Bool
    /// Embedded in the persisted bootstrap so reattaches reuse it while later workspaces do not.
    private let stateKey = UUID().uuidString.lowercased()

    init(command: String?, protectsFromHangup: Bool = false) {
        self.protectsFromHangup = protectsFromHangup
        guard let command,
              !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            encodedCommand = nil
            return
        }
        encodedCommand = Data(command.utf8).base64EncodedString()
    }

    /// Whether an explicit startup command will be claimed by the interactive shell.
    var hasCommand: Bool {
        encodedCommand != nil
    }

    /// Stages the command without evaluating any of its contents in the local shell.
    var preparationLines: [String] {
        guard let encodedCommand else { return [] }
        return [
            "unset BREE_INITIAL_COMMAND_FILE",
            "bree_initial_command_started=\"$bree_shell_dir/.initial-command.started.\(stateKey)\"",
            "if [ ! -d \"$bree_initial_command_started\" ]; then",
            "  bree_initial_command_file=\"$bree_shell_dir/.initial-command.payload.\(stateKey).$$\"",
            "  bree_initial_command_tmp=\"$bree_initial_command_file.tmp\"",
            "  if (umask 077; printf %s '\(encodedCommand)' > \"$bree_initial_command_tmp\") && mv -f -- \"$bree_initial_command_tmp\" \"$bree_initial_command_file\"; then",
            "    chmod 600 \"$bree_initial_command_file\" >/dev/null 2>&1 || true",
            "    export BREE_INITIAL_COMMAND_FILE=\"$bree_initial_command_file\"",
            "  else",
            "    rm -f -- \"$bree_initial_command_tmp\" \"$bree_initial_command_file\" 2>/dev/null || true",
            "  fi",
            "  unset bree_initial_command_file bree_initial_command_tmp",
            "fi",
            "unset bree_initial_command_started",
        ]
    }

    /// Decodes, atomically claims, and runs the command after zsh or bash startup files load.
    var posixInteractiveShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        return [
            "bree_initial_command_file=\"${BREE_INITIAL_COMMAND_FILE:-}\"",
            "bree_initial_command_started=\"$BREE_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset bree_initial_command_b64 bree_initial_command bree_initial_command_decode_status bree_initial_command_file_status",
            "if [ -r \"$bree_initial_command_file\" ]; then",
            "  bree_initial_command_b64=$(cat -- \"$bree_initial_command_file\" 2>/dev/null)",
            "  bree_initial_command_file_status=$?",
            "else",
            "  bree_initial_command_file_status=1",
            "fi",
            "unset BREE_INITIAL_COMMAND_FILE",
            "if [ -n \"$bree_initial_command_file\" ]; then rm -f -- \"$bree_initial_command_file\" 2>/dev/null || true; fi",
            "if [ \"$bree_initial_command_file_status\" -eq 0 ] && [ -n \"$bree_initial_command_b64\" ]; then",
            "  bree_initial_command=$(printf %s \"$bree_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$bree_initial_command_b64\" | base64 -D 2>/dev/null)",
            "  bree_initial_command_decode_status=$?",
            "  if [ \"$bree_initial_command_decode_status\" -eq 0 ] && mkdir \"$bree_initial_command_started\" 2>/dev/null; then eval \"$bree_initial_command\"; fi",
            "fi",
            "unset bree_initial_command_b64 bree_initial_command bree_initial_command_decode_status bree_initial_command_file_status bree_initial_command_file bree_initial_command_started",
        ]
    }

    /// Decodes, atomically claims, and runs the command from fish's initialization hook.
    var fishInteractiveShellCommand: String? {
        guard encodedCommand != nil else { return nil }
        return [
            "set -l bree_initial_command_file \"$BREE_INITIAL_COMMAND_FILE\"",
            "set -l bree_initial_command_started \"$BREE_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "set -l bree_initial_command_b64",
            "set -l bree_initial_command_file_status 1",
            "if test -r \"$bree_initial_command_file\"",
            "set bree_initial_command_b64 (command cat -- \"$bree_initial_command_file\" 2>/dev/null)",
            "set bree_initial_command_file_status $status",
            "end",
            "set -e BREE_INITIAL_COMMAND_FILE",
            "if test -n \"$bree_initial_command_file\"; command rm -f -- \"$bree_initial_command_file\" >/dev/null 2>&1; or true; end",
            "if test \"$bree_initial_command_file_status\" -eq 0; and test -n \"$bree_initial_command_b64\"",
            "set -l bree_initial_command_decode_flag",
            "if printf %s \"$bree_initial_command_b64\" | base64 -d >/dev/null 2>&1",
            "set bree_initial_command_decode_flag -d",
            "else if printf %s \"$bree_initial_command_b64\" | base64 -D >/dev/null 2>&1",
            "set bree_initial_command_decode_flag -D",
            "end",
            "if test -n \"$bree_initial_command_decode_flag\"",
            "set -l bree_initial_command (printf %s \"$bree_initial_command_b64\" | base64 \"$bree_initial_command_decode_flag\" 2>/dev/null | string collect)",
            "if command mkdir \"$bree_initial_command_started\" 2>/dev/null; eval \"$bree_initial_command\"; end",
            "end",
            "end",
        ].joined(separator: "; ")
    }

    /// Runs the command through shell-specific adapters, with a POSIX wrapper for unknown shells.
    var fallbackShellLines: [String] {
        guard encodedCommand != nil else { return [] }
        let shellExec = RemoteInteractiveShellBootstrapBuilder.shellExecCommand(
            shell: #""$BREE_LOGIN_SHELL""#,
            protectsFromHangup: protectsFromHangup
        )
        let fallbackExec = RemoteInteractiveShellBootstrapBuilder.shellExecCommand(
            shell: "/bin/sh",
            protectsFromHangup: protectsFromHangup
        )
        return [
            "bree_initial_command_file=\"${BREE_INITIAL_COMMAND_FILE:-}\"",
            "bree_initial_command_started=\"$BREE_SHELL_INTEGRATION_DIR/.initial-command.started.\(stateKey)\"",
            "unset bree_initial_command_b64 bree_initial_command bree_initial_command_decode_status bree_initial_command_file_status",
            "if [ -r \"$bree_initial_command_file\" ]; then",
            "  bree_initial_command_b64=$(cat -- \"$bree_initial_command_file\" 2>/dev/null)",
            "  bree_initial_command_file_status=$?",
            "else",
            "  bree_initial_command_file_status=1",
            "fi",
            "unset BREE_INITIAL_COMMAND_FILE",
            "if [ -n \"$bree_initial_command_file\" ]; then rm -f -- \"$bree_initial_command_file\" 2>/dev/null || true; fi",
            "if [ \"$bree_initial_command_file_status\" -eq 0 ] && [ -n \"$bree_initial_command_b64\" ]; then",
            "  bree_initial_command=$(printf %s \"$bree_initial_command_b64\" | base64 -d 2>/dev/null || printf %s \"$bree_initial_command_b64\" | base64 -D 2>/dev/null)",
            "  bree_initial_command_decode_status=$?",
            "  if [ \"$bree_initial_command_decode_status\" -eq 0 ]; then",
            "    case \"${BREE_LOGIN_SHELL##*/}\" in",
            "      csh|tcsh) if mkdir \"$bree_initial_command_started\" 2>/dev/null; then \(shellExec) -i -c 'eval \"$argv[2]\"; exec \"$argv[1]\" -i' \"$BREE_LOGIN_SHELL\" \"$bree_initial_command\"; fi ;;",
            "      sh|dash|ksh|mksh|ash|yash|posh) if mkdir \"$bree_initial_command_started\" 2>/dev/null; then \(shellExec) -i -c 'eval \"$1\"; exec \"$0\" -i' \"$BREE_LOGIN_SHELL\" \"$bree_initial_command\"; fi ;;",
            // Nushell src/command.rs: --execute runs then stays interactive; --commands exits.
            "      nu|nushell) if mkdir \"$bree_initial_command_started\" 2>/dev/null; then \(shellExec) --execute \"$bree_initial_command\"; fi ;;",
            "      pwsh|powershell) if mkdir \"$bree_initial_command_started\" 2>/dev/null; then \(shellExec) -NoExit -Command \"$bree_initial_command\"; fi ;;",
            "      *) if mkdir \"$bree_initial_command_started\" 2>/dev/null; then \(fallbackExec) -c 'eval \"$1\"; exec \"$2\" -i' bree-initial-command \"$bree_initial_command\" \"$BREE_LOGIN_SHELL\"; fi ;;",
            "    esac",
            "  fi",
            "fi",
            "unset bree_initial_command_b64 bree_initial_command bree_initial_command_decode_status bree_initial_command_file_status bree_initial_command_file bree_initial_command_started",
        ]
    }
}
