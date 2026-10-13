import BREEAgentLaunch
import Testing

@Suite("Claude Teams policy isolation")
struct ClaudeTeamsPolicyIsolationTests {
    @Test("Drops equals-style tmux mode and preserves later flags")
    func dropsEqualsStyleTmuxModeAndPreservesLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--tmux=classic",
                    "--remote-control-session-name-prefix",
                    "bree-team",
                    "--model",
                    "sonnet",
                    "--dangerously-skip-permissions",
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
                "--dangerously-skip-permissions",
            ]
        )
    }

    @Test("Drops split tmux mode and preserves later flags")
    func dropsSplitTmuxModeAndPreservesLaterFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--tmux",
                    "classic",
                    "--worktree",
                    "/tmp/team",
                    "--remote-control-session-name-prefix",
                    "bree-team",
                    "--model",
                    "sonnet",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
                "--worktree",
                "/tmp/team",
                "--remote-control-session-name-prefix",
                "bree-team",
                "--model",
                "sonnet",
            ]
        )
    }

    @Test("Treats non-mode equals tmux as prompt boundary")
    func treatsNonModeEqualsTmuxAsPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--tmux=fix",
                    "--permission-mode",
                    "auto",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
            ]
        )
    }

    @Test("Plain Claude still drops worktree selectors")
    func plainClaudeStillDropsWorktreeSelectors() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "claude",
                    "--worktree",
                    "/tmp/repo",
                    "--model",
                    "sonnet",
                ],
                launcher: "claude",
                fallbackKind: "claude"
            ) == [
                "claude",
                "--model",
                "sonnet",
            ]
        )
    }
}
