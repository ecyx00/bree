import BreeSurfaceCatalogModel
import Testing

@Suite struct RemoteAgentSidebarStatusTests {
    @Test func daemonStatesMapToSidebarActivity() {
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "claude"))
            == .init(statusKey: "bree.remote.agent:claude_code", activity: .running))
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "blocked", source: "hook", agent: "codex"))
            == .init(statusKey: "bree.remote.agent:codex", activity: .needsInput))
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "idle", source: "hook", agent: "codex"))?.activity == .idle)
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "done", source: "hook", agent: "claude")) == nil)
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "unknown", source: "hook", agent: "claude")) == nil)
    }

    @Test func slotKeyIsTheAdapterNotTheProvenance() {
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook"))?.statusKey
            == "bree.remote.agent:agent")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "claude-code"))?.statusKey
            == "bree.remote.agent:claude_code")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "plugin", agent: " OpenCode "))?.statusKey
            == "bree.remote.agent:opencode")
        #expect(RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "a b;c"))?.statusKey
            == "bree.remote.agent:abc")
    }

    @Test func ownedKeysStayOutOfTheLocalHookSlots() {
        let status = RemoteAgentSidebarStatus(badge: .init(state: "working", source: "hook", agent: "claude"))
        #expect(status.map { RemoteAgentSidebarStatus.isOwnedStatusKey($0.statusKey) } == true)
        #expect(!RemoteAgentSidebarStatus.isOwnedStatusKey("claude_code"))
        #expect(!RemoteAgentSidebarStatus.isOwnedStatusKey("codex"))
    }

    @Test func workspaceSlotShowsTheMostUrgentTerminal() {
        let slots = RemoteAgentSidebarStatus.workspaceSlots([
            .init(statusKey: "bree.remote.agent:claude_code", activity: .idle),
            .init(statusKey: "bree.remote.agent:claude_code", activity: .needsInput),
            .init(statusKey: "bree.remote.agent:claude_code", activity: .running),
            .init(statusKey: "bree.remote.agent:codex", activity: .idle),
        ])
        #expect(slots == [
            "bree.remote.agent:claude_code": .needsInput,
            "bree.remote.agent:codex": .idle,
        ])
    }
}
