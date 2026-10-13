import BreeAgentJournal
import Foundation

/// Socket v2 surface for `bree queue` and `bree agent explain`:
/// `agent.queue.add|list|clear` and `agent.explain`.
///
/// Scoped to one terminal surface (`surface_id`, or `workspace_id` for that
/// workspace's focused surface). None of these is allowlisted in
/// `RemoteRelayCommandPolicy`, so a `bree ssh` session cannot reach them.
/// They never focus anything; `agent.explain` is read-only and returns no
/// typed text, draft text or tool input.
extension TerminalController {
    private nonisolated func v2QueueError(_ code: String, _ message: String) -> V2CallResult {
        .err(code: code, message: message, data: nil)
    }

    /// Resolves the target terminal surface. Runs on the main actor.
    @MainActor
    private func v2QueueResolveSurface(params: [String: Any]) -> (workspace: Workspace, surfaceId: UUID)? {
        if let requested = v2UUID(params, "surface_id") {
            guard let located = AppDelegate.shared?.workspaceContainingPanel(
                panelId: requested,
                preferredWorkspaceId: v2UUID(params, "workspace_id")
            ), located.workspace.panels[requested] is TerminalPanel else { return nil }
            return (located.workspace, requested)
        }
        guard let tabManager = v2ResolveTabManager(params: params),
              let workspace = v2ResolveWorkspace(params: params, tabManager: tabManager),
              let focused = workspace.focusedPanelId,
              workspace.panels[focused] is TerminalPanel else { return nil }
        return (workspace, focused)
    }

    private nonisolated func v2QueueSurfaceNotFound() -> V2CallResult {
        v2QueueError("not_found", String(
            localized: "socket.agentQueue.error.surfaceNotFound",
            defaultValue: "Terminal surface not found."
        ))
    }

    /// `agent.queue.add` (`text`), `agent.queue.list`, `agent.queue.clear`.
    /// `add` also types the oldest message at once when the agent is already idle.
    nonisolated func v2AgentQueue(params: [String: Any], action: String) -> V2CallResult {
        let text = v2String(params, "text")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if action == "add", text.isEmpty {
            return v2QueueError("invalid_params", String(
                localized: "socket.agentQueue.error.textRequired",
                defaultValue: "A message is required."
            ))
        }
        return v2MainSync { () -> V2CallResult in
            guard let (workspace, surfaceId) = self.v2QueueResolveSurface(params: params) else {
                return self.v2QueueSurfaceNotFound()
            }
            let store = AgentQueueStore.shared
            var payload: [String: Any] = [
                "surface_id": surfaceId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "capacity": AgentQueueStore.capacity,
            ]
            switch action {
            case "add":
                guard store.add(text, panelId: surfaceId) != nil else {
                    return self.v2QueueError("queue_full", String(
                        localized: "socket.agentQueue.error.full",
                        defaultValue: "The queue for this pane is full (20 messages)."
                    ))
                }
                let delivered = store.noteIdle(panelId: surfaceId, workspace: workspace)
                payload["delivered_now"] = delivered
            case "clear":
                payload["cleared"] = store.clear(panelId: surfaceId)
            default:
                break
            }
            // Message text is returned to the pane's own queue reader only.
            payload["messages"] = store.list(panelId: surfaceId)
            payload["count"] = store.count(panelId: surfaceId)
            return .ok(payload)
        }
    }

    private nonisolated static func explainPhase(of draft: AgentJournalEventDraft) -> String? {
        switch draft.kind {
        case .sessionStarted: return "unknown"
        case .turnStarted: return "running"
        case .attentionResolved:
            return (draft.declaredPhase ?? (draft.pendingWork ? .backgroundWorkPending : .idle)).rawValue
        case .turnCompleted, .idleObserved:
            return draft.pendingWork ? "backgroundWorkPending" : "idle"
        case .approvalRequested, .questionRequested, .planReviewRequested: return "needsInput"
        case .errorReported: return "error"
        case .stateChanged: return draft.declaredPhase?.rawValue
        case .sessionEnded: return "ended"
        default: return nil
        }
    }

    /// `agent.explain`: why a pane shows its agent state. Current state per agent
    /// key, the event that set it, and the last 5 transitions (newest first),
    /// read from the Agent Journal. Read-only.
    nonisolated func v2AgentExplain(params: [String: Any]) -> V2CallResult {
        struct Live { let workspaceId: String; let surfaceId: String; let aggregate: String; let perAgent: [String: String]; let queued: Int }
        let live: Live? = v2MainSync {
            guard let (workspace, surfaceId) = self.v2QueueResolveSurface(params: params) else { return nil }
            let perAgent = (workspace.agentLifecycleStatesByPanelId[surfaceId] ?? [:]).mapValues(\.rawValue)
            return Live(
                workspaceId: workspace.id.uuidString,
                surfaceId: surfaceId.uuidString,
                aggregate: workspace.agentHibernationLifecycleState(panelId: surfaceId, fallback: nil).rawValue,
                perAgent: perAgent,
                queued: AgentQueueStore.shared.count(panelId: surfaceId)
            )
        }
        guard let live else { return v2QueueSurfaceNotFound() }

        var payload: [String: Any] = [
            "surface_id": live.surfaceId,
            "workspace_id": live.workspaceId,
            "state": live.aggregate,
            "agents": live.perAgent,
            "queued": live.queued,
        ]
        guard let events = AgentJournalLifecycleCenter.shared.recentEvents(surfaceId: live.surfaceId, limit: 400) else {
            payload["journal_available"] = false
            payload["transitions"] = [[String: Any]]()
            return .ok(payload)
        }
        payload["journal_available"] = true
        var previousByAgent: [String: String] = [:]
        var transitions: [[String: Any]] = []
        for event in events.reversed() {
            guard let phase = Self.explainPhase(of: event.draft) else { continue }
            let agent = event.draft.agentKey
            let previous = previousByAgent[agent]
            if phase == previous { continue }
            previousByAgent[agent] = phase
            transitions.append([
                "at_ms": event.draft.occurredAtMs,
                "from": previous ?? NSNull(),
                "to": phase,
                "agent": agent,
                "source": event.draft.source,
                "hook_event": event.draft.nativeEvent ?? NSNull(),
                "kind": event.draft.kind.rawValue,
                "session_id": event.draft.sessionId ?? NSNull(),
            ])
        }
        let recent = Array(transitions.suffix(5).reversed())
        payload["transitions"] = recent
        if let last = recent.first {
            payload["since_ms"] = last["at_ms"] ?? NSNull()
            payload["set_by"] = last
        }
        return .ok(payload)
    }
}
