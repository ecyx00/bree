import BreeFoundation
import Darwin
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite struct AgentQuitOwnershipTests {
    @Test func processGenerationAndAppAncestryAreBothRequired() {
        let owner = AgentPIDProcessIdentity(pid: 20, startSeconds: 1, startMicroseconds: 2)
        let shell = AgentPIDProcessIdentity(pid: 19, startSeconds: 1, startMicroseconds: 1)
        let owned = AgentQuitProcessOwnership(appPID: 18) { pid in
            if pid == owner.pid { return (owner, shell.pid) }
            if pid == shell.pid { return (shell, 18) }
            return nil
        }
        #expect(owned.isOwned(owner))
        #expect(!owned.isOwned(AgentPIDProcessIdentity(pid: owner.pid, startSeconds: 2, startMicroseconds: 0)))
        let foreign = AgentQuitProcessOwnership(appPID: 18) { pid in pid == owner.pid ? (owner, 1) : nil }
        #expect(!foreign.isOwned(owner))
        #expect(!AgentQuitProcessOwnership(appPID: 18, snapshot: { _ in nil }).isOwned(owner))
    }

    @MainActor
    @Test func localTerminalDefersQuitWithoutAnyCachedAgentEvidence() {
        let previousApp = AppDelegate.shared
        let app = AppDelegate()
        defer { AppDelegate.shared = previousApp }
        let manager = TabManager(autoWelcomeIfNeeded: false)
        defer { manager.finalizeAllWorkspacesForWindowClose() }
        app.tabManager = manager
        #expect(app.hasLocalTerminalSurfacesForQuit)
        #expect(app.quitAgentTerminationScopes(index: .empty).isEmpty)
        #expect(app.quitAgentTerminationScopes(index: .unavailable).isEmpty)
    }
}
