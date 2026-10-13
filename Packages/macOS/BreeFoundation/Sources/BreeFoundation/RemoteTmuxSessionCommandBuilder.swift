internal import Foundation

/// Builds a terminal-attached tmux session launcher with shell integration.
///
/// A new session receives the supplied shell command for both its first pane
/// and future windows. Before attaching an existing session, its bree workspace
/// environment is rebound to the current relay without changing user options
/// or already-running commands.
public struct RemoteTmuxSessionCommandBuilder: Sendable {
    private let sessionName: String
    private let shellCommand: String

    /// Creates a named tmux session launcher.
    ///
    /// - Parameters:
    ///   - sessionName: Validated exact tmux session name.
    ///   - shellCommand: Shell command used for panes in a newly created session.
    public init(sessionName: String, shellCommand: String) {
        self.sessionName = sessionName
        self.shellCommand = shellCommand
    }

    /// A shell-quoted command that creates or attaches to the named session.
    public var remoteShellCommand: String {
        let resolver = RemoteExecutableCommandBuilder(
            executableName: "tmux",
            notFoundSentinel: RemoteTmuxCommandBuilder.notFoundSentinel
        )
        var scriptLines = [
            "bree_session_name=$1",
            "bree_shell_command=$2",
            "bree_session_target=\"=$bree_session_name\"",
            "bree_tmux=\"$(\(resolver.resolutionProbeShellCommand))\" || exit $?",
            "if \"$bree_tmux\" has-session -t \"$bree_session_target\" 2>/dev/null; then",
        ]
        scriptLines.append(contentsOf: Self.workspaceEnvironmentRebindingLines.map { "  " + $0 })
        scriptLines += [
            "  exec \"$bree_tmux\" attach-session -t \"$bree_session_target\"",
            "fi",
            "if \"$bree_tmux\" new-session -d \(Self.newSessionEnvironmentArguments) -s \"$bree_session_name\" \"$bree_shell_command\"; then",
        ]
        scriptLines.append(contentsOf: Self.workspaceEnvironmentRebindingLines.map { "  " + $0 })
        scriptLines += [
            "  \"$bree_tmux\" set-option -t \"$bree_session_target:\" default-command \"$bree_shell_command\" >/dev/null || exit $?",
            "fi",
            "exec \"$bree_tmux\" attach-session -t \"$bree_session_target\"",
        ]
        let script = scriptLines.joined(separator: "\n")
        return ([
            "/bin/sh",
            "-c",
            script,
            "bree-remote-tmux-session",
            sessionName,
            shellCommand,
        ])
        .map(\.remoteCommandShellQuoted)
        .joined(separator: " ")
    }

    private static let workspaceEnvironmentKeys = [
        "BREE_BUNDLED_CLI_PATH",
        "BREE_PERSISTENT_PTY_EXEC_HELPER",
        "BREE_SHELL_INTEGRATION",
        "BREE_SHELL_INTEGRATION_DIR",
        "BREE_SOCKET_PATH",
        "BREE_SSH_ATTEMPT_ID",
        "BREE_TAB_ID",
        "BREE_TERMINAL_LIFECYCLE_ID",
        "BREE_WORKSPACE_ID",
    ]

    private static let surfaceEnvironmentKeys = [
        "BREE_PANEL_ID",
        "BREE_SURFACE_ID",
    ]

    private static let transientEnvironmentKeys = [
        "BREE_INITIAL_COMMAND_FILE",
    ]

    private static var workspaceEnvironmentRebindingLines: [String] {
        workspaceEnvironmentKeys.map { key in
            "if [ \"${\(key)+x}\" = x ]; then \"$bree_tmux\" set-environment -t \"$bree_session_target\" \(key) \"$\(key)\" >/dev/null || exit $?; else \"$bree_tmux\" set-environment -t \"$bree_session_target\" -u \(key) >/dev/null || exit $?; fi"
        } + transientEnvironmentClearingLines + surfaceEnvironmentClearingLines
    }

    private static var newSessionEnvironmentArguments: String {
        let workspaceArguments = workspaceEnvironmentKeys.map { key in
            "-e \"\(key)=${\(key)-}\""
        }
        let transientArguments = transientEnvironmentKeys.map { key in
            "-e \"\(key)=${\(key)-}\""
        }
        let surfaceArguments = surfaceEnvironmentKeys.map { key in
            "-e \"\(key)=\""
        }
        return (workspaceArguments + transientArguments + surfaceArguments).joined(separator: " ")
    }

    private static var transientEnvironmentClearingLines: [String] {
        transientEnvironmentKeys.map { key in
            "\"$bree_tmux\" set-environment -t \"$bree_session_target\" -u \(key) >/dev/null || exit $?"
        }
    }

    private static var surfaceEnvironmentClearingLines: [String] {
        surfaceEnvironmentKeys.map { key in
            "\"$bree_tmux\" set-environment -t \"$bree_session_target\" -u \(key) >/dev/null || exit $?"
        }
    }
}
