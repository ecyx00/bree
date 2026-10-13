import Foundation
import BreeSidebar
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

extension SidebarWorkspaceSnapshotRefreshPolicyTests {
    @Test func contextMenuAgentActivityChangeUpdatesDisplayedSpinnerImmediately() {
        let current = Self.snapshot(
            latestConversationMessage: "old message",
            activeCodingAgentCount: 0
        )
        let next = Self.snapshot(
            latestConversationMessage: "new message",
            activeCodingAgentCount: 1
        )

        let decision = SidebarWorkspaceSnapshotRefreshPolicy().decision(
            current: current,
            next: next,
            force: false,
            contextMenuVisible: true
        )

        #expect(decision.workspaceSnapshotStorage?.activeCodingAgentCount == 1)
        #expect(decision.workspaceSnapshotStorage?.latestConversationMessage == "old message")
        #expect(decision.pendingWorkspaceSnapshot == next)
        #expect(decision.hasDeferredWorkspaceObservationInvalidation)
    }

    @Test func presentationKeyChangesWhenAgentActivityVisibilityChanges() {
        let hidden = Self.presentationKey(showsAgentActivity: false)
        let visible = Self.presentationKey(showsAgentActivity: true)

        #expect(hidden != visible)
        #expect(!hidden.showsAgentActivity)
        #expect(visible.showsAgentActivity)
    }

    @Test func disabledSpinnerDoesNotReadAgentLifecycleStates() {
        var didReadAgentLifecycleStates = false
        let agentLifecycleStates: () -> [UUID: [String: AgentHibernationLifecycleState]] = {
            didReadAgentLifecycleStates = true
            return [
                UUID(): [
                    "codex": .running,
                    "claude_code": .running,
                ],
            ]
        }

        let count = SidebarAgentActivitySummary.visibleActiveCodingAgentCount(
            showsAgentActivity: false,
            statesByPanelId: agentLifecycleStates()
        )

        #expect(count == 0)
        #expect(!didReadAgentLifecycleStates)
    }

    @Test func pulseLineJoinsOnlyThePartsThatExist() {
        #expect(SidebarWorkspacePulse.line(
            branch: "main", changedFileCount: 3, agentKind: .waiting, agentName: "Codex", ports: [3000]
        ) == "main · 3 changed · Codex waiting · :3000")
        #expect(SidebarWorkspacePulse.line(
            branch: nil, changedFileCount: 0, agentKind: .running, ports: []
        ) == "running")
        #expect(SidebarWorkspacePulse.line(
            branch: "main", changedFileCount: nil, agentKind: .terminal, ports: []
        ) == "main")
        #expect(SidebarWorkspacePulse.line(
            branch: nil, changedFileCount: nil, agentKind: .unseen, ports: []
        ) == nil)
    }
}
