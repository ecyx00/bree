import BREEAgentLaunch
import Testing

@Suite("Claude Teams prompt boundary isolation")
struct ClaudeTeamsPromptBoundaryRecoveryTests {
    @Test("Drops post-boundary flags for remote-control launches")
    func dropsPostBoundaryFlagsForRemoteControlLaunches() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--remote-control-session-name-prefix",
                    "bree-team",
                    "--tmux",
                    "please",
                    "--permission-mode",
                    "bypassPermissions",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
                "--remote-control-session-name-prefix",
                "bree-team",
            ]
        )
    }

    @Test("Recovers safe post-boundary flags at end of argv")
    func recoversSafePostBoundaryFlagsAtEndOfArgv() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--remote-control-session-name-prefix",
                    "bree-team",
                    "--tmux",
                    "side effect should be dropped",
                    "--model",
                    "sonnet",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
                "--remote-control-session-name-prefix",
                "bree-team",
                "--model",
                "sonnet",
                "--permission-mode",
                "auto",
            ]
        )
    }
}
