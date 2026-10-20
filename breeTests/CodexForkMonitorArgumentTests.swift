import Foundation
import Testing
import BREEAgentLaunch

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

struct CodexForkMonitorArgumentTests {
    @Test
    func forwardsForkParentClaimToDetachedMonitor() {
        let arguments = CodexForkMonitorArguments().make(environment: [
            "BREE_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "BREE_AGENT_FORK_LAUNCH_ID": "launch-id",
            "BREE_CODEX_PID": "1234",
        ])

        #expect(arguments == [
            "--fork-parent", "parent-session",
            "--fork-launch-id", "launch-id",
            "--fork-owner-pid", "1234",
        ])
    }

    @Test
    func omitsForkArgumentsForNormalCodexMonitor() {
        #expect(CodexForkMonitorArguments().make(environment: [:]).isEmpty)
    }
    @Test
    func omitsForkArgumentsWithoutValidParent() {
        for parent in [String?.none, ""] {
            var environment = ["BREE_AGENT_FORK_LAUNCH_ID": "launch-id", "BREE_CODEX_PID": "1234"]
            environment["BREE_AGENT_FORK_PARENT_SESSION_ID"] = parent
            #expect(CodexForkMonitorArguments().make(environment: environment).isEmpty)
        }
    }

    @Test
    func omitsEmptyOptionalForkMetadata() {
        #expect(CodexForkMonitorArguments().make(environment: [
            "BREE_AGENT_FORK_PARENT_SESSION_ID": "parent-session",
            "BREE_AGENT_FORK_LAUNCH_ID": "",
            "BREE_CODEX_PID": "",
        ]) == ["--fork-parent", "parent-session"])
    }

}
