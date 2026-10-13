import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite(.serialized)
struct TerminalAgentPanelInitialTitleTests {
    @Test
    func versionedClaudeTeammateNameIsTheInitialPanelTitle() {
        let command = """
        cd /tmp/work && env CLAUDECODE=1 /Users/dev/.local/share/claude/versions/2.1.233 \
          --agent-id PathScout2@session-87b88f27 \
          --agent-name PathScout2 \
          --team-name session-87b88f27 \
          --agent-color blue \
          --agent-type general-purpose \
          --parent-session-id f9b4d8eb-1069-4776-bd4b-ff1da62f2561
        """
        let panel = TerminalPanel(
            workspaceId: UUID(),
            initialCommand: command,
            runtimeSpawnPolicy: .heldForStartupRestoreAdmission
        )
        defer { panel.surface.teardownHostedSurfaceForTesting() }

        #expect(panel.displayTitle == "PathScout2")
    }
}
