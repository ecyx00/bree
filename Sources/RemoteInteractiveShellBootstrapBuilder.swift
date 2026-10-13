import BreeFoundation
import Foundation

enum RemoteInteractiveShellBootstrapBuilder {
    static func script(
        remoteRelayPort: Int,
        shellFeatures: String,
        initialCommand: String? = nil,
        configuredRemoteCommand: String? = nil,
        terminfoSource: String? = nil,
        bundledZshIntegration: String? = nil,
        bundledBashIntegration: String? = nil,
        bundledFishIntegration: String? = nil,
        terminalProfile: WorkspaceRemoteTerminalProfile = .shell,
        protectsFromHangup: Bool = false
    ) -> String {
        let shellStateDir = shellStateDirForRemoteRelayPort(remoteRelayPort)
        let initialCommandBootstrap = RemoteInitialCommandBootstrap(
            command: initialCommand,
            protectsFromHangup: protectsFromHangup
        )
        let shellExec = shellExecCommand(shell: #""$BREE_LOGIN_SHELL""#, protectsFromHangup: protectsFromHangup)
        let zshExec = shellExecCommand(shell: #""${SHELL:-/bin/zsh}""#, protectsFromHangup: protectsFromHangup)
        let bashExec = shellExecCommand(shell: #""${SHELL:-/bin/bash}""#, protectsFromHangup: protectsFromHangup)
        let fishExec = shellExecCommand(shell: #""${SHELL:-/bin/fish}""#, protectsFromHangup: protectsFromHangup)
        let fallbackExec = shellExecCommand(shell: #""${SHELL:-/bin/sh}""#, protectsFromHangup: protectsFromHangup)
        let commonShellExportLines = commonShellLines(
            remoteRelayPort: remoteRelayPort,
            shellStateDir: shellStateDir,
            shellFeatures: shellFeatures,
            terminfoSource: terminfoSource
        )
        var zshShellLines = commonShellExportLines
        zshShellLines.append(
            #"if [ "${BREE_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${BREE_SHELL_INTEGRATION_DIR}/bree-zsh-integration.zsh" ]; then . "${BREE_SHELL_INTEGRATION_DIR}/bree-zsh-integration.zsh"; fi"#
        )
        var bashShellLines = commonShellExportLines
        bashShellLines.append(
            #"if [ "${BREE_SHELL_INTEGRATION:-1}" != "0" ] && [ -r "${BREE_SHELL_INTEGRATION_DIR}/bree-bash-integration.bash" ]; then . "${BREE_SHELL_INTEGRATION_DIR}/bree-bash-integration.bash"; fi"#
        )
        bashShellLines.append(contentsOf: initialCommandBootstrap.posixInteractiveShellLines)
        let zshBootstrap = RemoteRelayZshBootstrap(shellStateDir: shellStateDir)
        let relayWarmupLines = relayWarmupLines(remoteRelayPort: remoteRelayPort)
        // A captured/approved startup command is an explicit restore target;
        // it takes precedence over the host's default interactive program.
        // Launching the configured command with `-c` would bypass the shell
        // hooks that atomically claim and execute the startup command.
        let chainedRemoteCommand = terminalProfile.kind == .shell && !initialCommandBootstrap.hasCommand
            ? configuredRemoteCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let chainedRemoteCommandLaunch = chainedRemoteCommand.flatMap { command -> String? in
            guard !command.isEmpty else { return nil }
            // Match sshd's normal RemoteCommand execution through the account shell.
            return "\(shellExec) -c \(shellQuote(command))"
        }

        var outerLines: [String] = [
            "mkdir -p \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay\"",
            "bree_shell_dir=\"\(shellStateDir)\"",
            "mkdir -p \"$bree_shell_dir\"",
        ]
        outerLines.append(contentsOf: claudeWrapperInstallLines)
        outerLines.append(contentsOf: initialCommandBootstrap.preparationLines)
        if let bundledZshIntegration {
            outerLines += [
                "cat > \"$bree_shell_dir/bree-zsh-integration.zsh\" <<'BREEBREEZSH'",
                bundledZshIntegration,
                "BREEBREEZSH",
            ]
        }
        if let bundledBashIntegration {
            outerLines += [
                "cat > \"$bree_shell_dir/bree-bash-integration.bash\" <<'BREEBREEBASH'",
                bundledBashIntegration,
                "BREEBREEBASH",
            ]
        }
        if let bundledFishIntegration {
            outerLines += [
                "mkdir -p \"$bree_shell_dir/fish\"",
                "cat > \"$bree_shell_dir/fish/config.fish\" <<'BREEBREEFISH'",
                bundledFishIntegration,
                "BREEBREEFISH",
            ]
        }
        outerLines.append(contentsOf: commonShellExportLines + Self.remoteInitialWorkingDirectoryLines())
        outerLines += [
            "BREE_LOGIN_SHELL=\"${SHELL:-/bin/zsh}\"",
            protectsFromHangup
                ? "if [ -z \"${BREE_PERSISTENT_PTY_EXEC_HELPER:-}\" ] || [ ! -x \"$BREE_PERSISTENT_PTY_EXEC_HELPER\" ]; then exit 126; fi"
                : ":",
            "case \"${BREE_LOGIN_SHELL##*/}\" in",
            "  zsh)",
            "    cat > \"$bree_shell_dir/.zshenv\" <<'BREEZSHENV'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshEnvLines)
        outerLines += [
            "BREEZSHENV",
            "    cat > \"$bree_shell_dir/.zprofile\" <<'BREEZSHPROFILE'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshProfileLines)
        outerLines += [
            "BREEZSHPROFILE",
            "    cat > \"$bree_shell_dir/.zshrc\" <<'BREEZSHRC'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshRCLines(commonShellLines: zshShellLines))
        outerLines += [
            "BREEZSHRC",
            "    cat > \"$bree_shell_dir/.zlogin\" <<'BREEZSHLOGIN'",
        ]
        outerLines.append(contentsOf: zshBootstrap.zshLoginLines + initialCommandBootstrap.posixInteractiveShellLines)
        outerLines += [
            "BREEZSHLOGIN",
            "    chmod 600 \"$bree_shell_dir/.zshenv\" \"$bree_shell_dir/.zprofile\" \"$bree_shell_dir/.zshrc\" \"$bree_shell_dir/.zlogin\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            "    export BREE_REAL_ZDOTDIR=\"${ZDOTDIR:-$HOME}\"",
            "    export ZDOTDIR=\"$bree_shell_dir\"",
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: chainedRemoteCommandLaunch
                    ?? "\(shellExec) -il",
                tmuxShellCommand: "export BREE_REAL_ZDOTDIR=\"${BREE_REAL_ZDOTDIR:-${ZDOTDIR:-$HOME}}\"; export ZDOTDIR=\"\(shellStateDir)\"; \(zshExec) -il"
            ),
            "    ;;",
            "  bash)",
            "    cat > \"$bree_shell_dir/.bashrc\" <<'BREEBASHRC'",
        ]
        outerLines.append(contentsOf: [
            "if [ -f \"$HOME/.bash_profile\" ]; then",
            "  . \"$HOME/.bash_profile\"",
            "elif [ -f \"$HOME/.bash_login\" ]; then",
            "  . \"$HOME/.bash_login\"",
            "elif [ -f \"$HOME/.profile\" ]; then",
            "  . \"$HOME/.profile\"",
            "fi",
            "[ -f \"$HOME/.bashrc\" ] && . \"$HOME/.bashrc\"",
        ] + bashShellLines)
        outerLines += [
            "BREEBASHRC",
            "    chmod 600 \"$bree_shell_dir/.bashrc\" >/dev/null 2>&1 || true",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        outerLines += [
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: chainedRemoteCommandLaunch
                    ?? "\(shellExec) --rcfile \"$bree_shell_dir/.bashrc\" -i",
                // tmux stores `default-command` at the session level. Resolve
                // the relay directory from the session environment each time
                // a pane is created so reconnects cannot leave new panes
                // pointing at a deleted relay rcfile.
                tmuxShellCommand: "\(bashExec) --rcfile \"${BREE_SHELL_INTEGRATION_DIR:-\(shellStateDir)}/.bashrc\" -i"
            ),
            "    ;;",
            "  fish)",
        ]
        outerLines.append(contentsOf: relayWarmupLines.map { "    " + $0 })
        var fishInitCommands = ["source \"$BREE_FISH_INTEGRATION_FILE\""]
        if let initialCommand = initialCommandBootstrap.fishInteractiveShellCommand {
            fishInitCommands.append(initialCommand)
        }
        let fishInitCommand = shellQuote(fishInitCommands.joined(separator: "; "))
        outerLines += [
            "    export BREE_FISH_INTEGRATION_FILE=\"$bree_shell_dir/fish/config.fish\"",
            "    export BREE_FISH_USER_CONFIG_ALREADY_LOADED=1",
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "    ",
                directShellCommand: chainedRemoteCommandLaunch
                    ?? "\(shellExec) -il --init-command \(fishInitCommand)",
                tmuxShellCommand: "export BREE_FISH_INTEGRATION_FILE=\"\(shellStateDir)/fish/config.fish\"; export BREE_FISH_USER_CONFIG_ALREADY_LOADED=1; \(fishExec) -il --init-command \(fishInitCommand)"
            ),
            "    ;;",
            "  *)",
        ]
        outerLines.append(contentsOf: relayWarmupLines)
        outerLines.append(contentsOf: initialCommandBootstrap.fallbackShellLines)
        outerLines += [
            terminalLaunchLine(
                profile: terminalProfile,
                indentation: "",
                directShellCommand: chainedRemoteCommandLaunch
                    ?? "\(shellExec) -i",
                tmuxShellCommand: "\(fallbackExec) -i"
            ),
            ";;",
            "esac",
        ]

        return outerLines.joined(separator: "\n")
    }

    /// Persistent daemon PTYs outlive their transport; ordinary SSH and Mosh
    /// shells retain normal hangup handling when their transport goes away.
    static func shellExecCommand(shell: String, protectsFromHangup: Bool) -> String {
        if protectsFromHangup {
            return "exec \"$BREE_PERSISTENT_PTY_EXEC_HELPER\" --internal-persistent-pty-exec \(shell) \(shell)"
        }
        return "exec \(shell)"
    }

    private static func terminalLaunchLine(
        profile: WorkspaceRemoteTerminalProfile,
        indentation: String,
        directShellCommand: String,
        tmuxShellCommand: String
    ) -> String {
        guard let sessionName = profile.tmuxSessionName else {
            return indentation + directShellCommand
        }
        let command = RemoteTmuxSessionCommandBuilder(
            sessionName: sessionName,
            shellCommand: tmuxShellCommand
        ).remoteShellCommand
        return indentation + "exec " + command
    }

    static func shellFeatures(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let rawExisting = environment["GHOSTTY_SHELL_FEATURES"] ?? ""
        var seen: Set<String> = []
        var merged: [String] = []

        for token in rawExisting.split(separator: ",") {
            let feature = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !feature.isEmpty else { continue }
            if seen.insert(feature).inserted {
                merged.append(feature)
            }
        }

        for required in ["ssh-env", "ssh-terminfo"] {
            if seen.insert(required).inserted {
                merged.append(required)
            }
        }

        return merged.joined(separator: ",")
    }

    static func bundledShellIntegrationScript(
        named fileName: String,
        bundleResourceURL: URL? = Bundle.main.resourceURL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let bundleResourceURL else { return nil }
        let url = bundleResourceURL
            .appendingPathComponent("shell-integration", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let contents = String(data: data, encoding: .utf8) else {
            return nil
        }
        return contents
    }

    private static func commonShellLines(
        remoteRelayPort: Int,
        shellStateDir: String,
        shellFeatures: String,
        terminfoSource: String?
    ) -> [String] {
        let relaySocket = remoteRelayPort > 0 ? "127.0.0.1:\(remoteRelayPort)" : nil
        var lines = terminalSetupLines(terminfoSource: terminfoSource)
        lines.append(contentsOf: RemoteShellEnvironment.utf8LocaleSetupLines())
        lines.append(contentsOf: shellExportLines(shellFeatures: shellFeatures))
        lines.append("export PATH=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin:$PATH\"")
        lines.append("export BREE_BUNDLED_CLI_PATH=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree\"")
        lines.append("unset BREE_CODEX_WRAPPER_SHIM; if [ -x \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree-codex-wrapper\" ] && command -v bash >/dev/null 2>&1; then export BREE_CODEX_WRAPPER_SHIM=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree-codex-wrapper\"; fi")
        lines.append(
            "export BREE_PERSISTENT_PTY_EXEC_HELPER=\"${BREE_PERSISTENT_PTY_EXEC_HELPER:-$BREE_BUNDLED_CLI_PATH}\""
        )
        lines.append("export BREE_SHELL_INTEGRATION_DIR=\"\(shellStateDir)\"")
        if let relaySocket {
            lines.append("export BREE_SOCKET_PATH=\(relaySocket)")
        }
        // The assignment placeholders are replaced by `ssh-pty-attach` before
        // this script runs. Split the sentinel patterns so a missed replacement
        // does not export literal placeholder IDs into the remote shell.
        lines.append(contentsOf: [
            "bree_workspace_id='__BREE_WORKSPACE_ID__'",
            "case \"$bree_workspace_id\" in \"\"|'__BREE_''WORKSPACE_ID__') ;; *) export BREE_WORKSPACE_ID=\"$bree_workspace_id\"; export BREE_TAB_ID=\"$bree_workspace_id\" ;; esac",
            "bree_surface_id='__BREE_SURFACE_ID__'",
            "case \"$bree_surface_id\" in \"\"|'__BREE_''SURFACE_ID__') ;; *) export BREE_SURFACE_ID=\"$bree_surface_id\"; export BREE_PANEL_ID=\"$bree_surface_id\" ;; esac",
            "bree_terminal_lifecycle_id='__BREE_TERMINAL_LIFECYCLE_ID__'",
            "case \"$bree_terminal_lifecycle_id\" in \"\"|'__BREE_''TERMINAL_LIFECYCLE_ID__') ;; *) export BREE_TERMINAL_LIFECYCLE_ID=\"$bree_terminal_lifecycle_id\" ;; esac",
            "bree_ssh_attempt_id='__BREE_SSH_ATTEMPT_ID__'",
            "case \"$bree_ssh_attempt_id\" in \"\"|'__BREE_''SSH_ATTEMPT_ID__') ;; *) export BREE_SSH_ATTEMPT_ID=\"$bree_ssh_attempt_id\" ;; esac",
            "unset bree_workspace_id bree_surface_id bree_terminal_lifecycle_id bree_ssh_attempt_id",
            "hash -r >/dev/null 2>&1 || true",
            "rehash >/dev/null 2>&1 || true",
        ])
        return lines
    }

    static func terminalSetupLines(terminfoSource: String?) -> [String] {
        let trimmedTerminfoSource = terminfoSource?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedTerminfoSource, !trimmedTerminfoSource.isEmpty else {
            // Without a bundled terminfo to install we can only probe what the
            // remote already has and fall back to a universally-present entry.
            return [
                "bree_term='xterm-256color'",
                "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
                "  bree_term='xterm-ghostty'",
                "fi",
                "export TERM=\"$bree_term\"",
            ]
        }
        // Install the bundled xterm-ghostty terminfo *synchronously*, before
        // deciding TERM, so a full-screen TUI (e.g. Claude Code) never starts
        // against a TERM whose terminfo entry is missing or half-written.
        //
        // The previous design deferred `tic` to a background job and decided
        // TERM up front, so the first shell on a host without the entry got
        // xterm-256color while a later pass could select xterm-ghostty mid-write
        // and garble output (#6352). Here we compile into a private temp
        // directory on the same filesystem as ~/.terminfo, then move each
        // compiled entry into place with an atomic rename, so a concurrent reader
        // in another bree ssh session sharing $HOME never observes a partially
        // written database. The temp directory comes from `mktemp` when present,
        // otherwise a per-process `$$` directory (unique among live processes) so
        // the atomic-rename path applies even without `mktemp` — no branch ever
        // compiles terminfo directly into ~/.terminfo.
        return [
            "bree_term='xterm-256color'",
            "if command -v infocmp >/dev/null 2>&1 && infocmp xterm-ghostty >/dev/null 2>&1; then",
            "  bree_term='xterm-ghostty'",
            "elif command -v tic >/dev/null 2>&1; then",
            "  mkdir -p \"$HOME/.terminfo\" 2>/dev/null",
            "  bree_ti_tmp=$(mktemp -d \"$HOME/.terminfo.bree.XXXXXX\" 2>/dev/null) || bree_ti_tmp=''",
            "  if [ -z \"$bree_ti_tmp\" ]; then",
            "    bree_ti_tmp=\"$HOME/.terminfo.bree.$$\"",
            "    rm -rf \"$bree_ti_tmp\" 2>/dev/null",
            "    mkdir \"$bree_ti_tmp\" 2>/dev/null || bree_ti_tmp=''",
            "  fi",
            "  {",
            "    cat <<'BREEINFO'",
            trimmedTerminfoSource,
            "BREEINFO",
            "  } | {",
            "    if [ -n \"$bree_ti_tmp\" ] && tic -x -o \"$bree_ti_tmp\" - >/dev/null 2>&1; then",
            "      find \"$bree_ti_tmp\" -type f 2>/dev/null | while IFS= read -r bree_ti_file; do",
            "        bree_ti_rel=${bree_ti_file#\"$bree_ti_tmp\"/}",
            "        bree_ti_dest=\"$HOME/.terminfo/$bree_ti_rel\"",
            "        mkdir -p \"$(dirname \"$bree_ti_dest\")\" 2>/dev/null",
            "        mv -f \"$bree_ti_file\" \"$bree_ti_dest\" 2>/dev/null || cp -f \"$bree_ti_file\" \"$bree_ti_dest\" 2>/dev/null",
            "      done",
            "    fi",
            "  }",
            "  [ -n \"$bree_ti_tmp\" ] && rm -rf \"$bree_ti_tmp\" 2>/dev/null",
            "  if infocmp xterm-ghostty >/dev/null 2>&1; then",
            "    bree_term='xterm-ghostty'",
            "  fi",
            "  unset bree_ti_tmp bree_ti_file bree_ti_rel bree_ti_dest 2>/dev/null || true",
            "fi",
            "export TERM=\"$bree_term\"",
        ]
    }

    private static func shellExportLines(shellFeatures: String) -> [String] {
        let environment = ProcessInfo.processInfo.environment
        let colorTerm = normalizedEnvValue(environment["COLORTERM"]) ?? "truecolor"
        let termProgram = normalizedEnvValue(environment["TERM_PROGRAM"]) ?? "ghostty"
        let termProgramVersion = normalizedEnvValue(environment["TERM_PROGRAM_VERSION"])
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? ""
        let trimmedShellFeatures = shellFeatures.trimmingCharacters(in: .whitespacesAndNewlines)

        var exports: [String] = [
            "export COLORTERM=\(shellQuote(colorTerm))",
            "export TERM_PROGRAM=\(shellQuote(termProgram))",
        ]
        if !termProgramVersion.isEmpty {
            exports.append("export TERM_PROGRAM_VERSION=\(shellQuote(termProgramVersion))")
        }
        if !trimmedShellFeatures.isEmpty {
            exports.append("export GHOSTTY_SHELL_FEATURES=\(shellQuote(trimmedShellFeatures))")
        }
        return exports
    }

    private static func relayWarmupLines(remoteRelayPort: Int) -> [String] {
        guard remoteRelayPort > 0 else {
            return []
        }
        return [
            "bree_relay_cli=\"${BREE_BUNDLED_CLI_PATH:-$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree}\"",
            "if [ ! -x \"$bree_relay_cli\" ]; then bree_relay_cli=\"$(command -v bree 2>/dev/null || true)\"; fi",
            "bree_relay_tty=\"${BREE_BOOTSTRAP_TTY:-}\"",
            "if [ -z \"$bree_relay_tty\" ]; then bree_relay_tty=\"$(tty 2>/dev/null || true)\"; fi",
            "bree_relay_tty=\"${bree_relay_tty##*/}\"",
            "if [ -n \"$bree_relay_tty\" ] && [ \"$bree_relay_tty\" != \"not a tty\" ]; then",
            "  mkdir -p \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay\" >/dev/null 2>&1 || true",
            "  printf '%s' \"$bree_relay_tty\" > \"$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay/\(remoteRelayPort).tty\" 2>/dev/null || true",
            "fi",
            "if [ -n \"$bree_relay_cli\" ] && [ -n \"$BREE_WORKSPACE_ID\" ] && [ -n \"$BREE_TERMINAL_LIFECYCLE_ID\" ] && [ -n \"$BREE_SSH_ATTEMPT_ID\" ] && [ -n \"$bree_relay_tty\" ] && [ \"$bree_relay_tty\" != \"not a tty\" ]; then",
            "  bree_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$BREE_WORKSPACE_ID\\\",\\\"tty_name\\\":\\\"$bree_relay_tty\\\",\\\"terminal_lifecycle_id\\\":\\\"$BREE_TERMINAL_LIFECYCLE_ID\\\",\\\"attempt_id\\\":\\\"$BREE_SSH_ATTEMPT_ID\\\"}\"",
            "  bree_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$BREE_WORKSPACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  if [ -n \"$BREE_SURFACE_ID\" ]; then",
            "    bree_relay_report_tty=\"{\\\"workspace_id\\\":\\\"$BREE_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$BREE_SURFACE_ID\\\",\\\"tty_name\\\":\\\"$bree_relay_tty\\\",\\\"terminal_lifecycle_id\\\":\\\"$BREE_TERMINAL_LIFECYCLE_ID\\\",\\\"attempt_id\\\":\\\"$BREE_SSH_ATTEMPT_ID\\\"}\"",
            "    bree_relay_ports_kick=\"{\\\"workspace_id\\\":\\\"$BREE_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$BREE_SURFACE_ID\\\",\\\"reason\\\":\\\"command\\\"}\"",
            "  fi",
            "  \"$bree_relay_cli\" rpc surface.report_tty \"$bree_relay_report_tty\" >/dev/null 2>&1 || true",
            "  ( \"$bree_relay_cli\" rpc surface.ports_kick \"$bree_relay_ports_kick\" >/dev/null 2>&1 || true ) </dev/null >/dev/null 2>&1 &",
            "fi",
            "unset BREE_BOOTSTRAP_TTY bree_relay_cli bree_relay_tty bree_relay_report_tty bree_relay_ports_kick",
        ]
    }

    /// The shell integration's `claude` shim execs
    /// `$BREE_SHELL_INTEGRATION_DIR/bin/bree-claude-wrapper` when present. On a
    /// relay host that wrapper hands off to the remote CLI, which injects the
    /// relay hooks through `--settings`, so launchers that resolve `claude`
    /// from PATH (and set their own CLAUDE_CONFIG_DIR) still report status.
    /// An older remote CLI without the verb fails the local `--bree-probe`
    /// (no relay round trip), so the wrapper falls back to plain `claude`.
    static let claudeWrapperInstallLines: [String] = [
        "mkdir -p \"$bree_shell_dir/bin\"",
        "cat > \"$bree_shell_dir/bin/bree-claude-wrapper\" <<'BREECLAUDEWRAPPER'",
        "#!/bin/sh",
        "bree_cli=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree\"",
        "if [ -x \"$bree_cli\" ] && \"$bree_cli\" claude-wrapper --bree-probe >/dev/null 2>&1; then exec \"$bree_cli\" claude-wrapper \"$@\"; fi",
        "bree_path=",
        "bree_ifs=$IFS; IFS=:",
        "for bree_entry in $PATH; do case \"$bree_entry\" in *bree-cli-shims*) ;; *) bree_path=\"${bree_path:+$bree_path:}$bree_entry\" ;; esac; done",
        "IFS=$bree_ifs; PATH=$bree_path; export PATH",
        "exec claude \"$@\"",
        "BREECLAUDEWRAPPER",
        "chmod 700 \"$bree_shell_dir/bin/bree-claude-wrapper\"",
    ]

    private static func shellStateDirForRemoteRelayPort(_ remoteRelayPort: Int) -> String {
        "$HOME/\(BreeIdentity.remoteDotDirectoryName)/relay/\(max(remoteRelayPort, 0)).shell"
    }

    private static func normalizedEnvValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shellQuote(_ value: String) -> String {
        value.posixShellWord
    }
}
