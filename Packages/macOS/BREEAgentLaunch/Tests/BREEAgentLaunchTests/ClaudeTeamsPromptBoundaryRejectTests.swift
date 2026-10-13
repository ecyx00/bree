import BREEAgentLaunch
import Testing

@Suite("Claude Teams prompt boundary rejects")
struct ClaudeTeamsPromptBoundaryRejectTests {
    @Test("Drops non-restorable-looking prompt text after tmux prompt boundary")
    func dropsNonRestorableLookingPromptTextAfterTmuxPromptBoundary() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--no-session-persistence",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
            ]
        )
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Applications/bree.app/Contents/Resources/bin/bree",
                    "claude-teams",
                    "--tmux",
                    "fix",
                    "--print=true",
                ],
                launcher: "claudeTeams",
                fallbackKind: "claude"
            ) == [
                "/Applications/bree.app/Contents/Resources/bin/bree",
                "claude-teams",
            ]
        )
    }
}
