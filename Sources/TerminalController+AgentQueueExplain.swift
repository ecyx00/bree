import BreeAgentJournal
import BreeWorkspaces
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

/// Per-surface record behind `bree agent wait`: the last aggregate lifecycle
/// and how many times the agent entered `idle` and `needsInput`. A waiter that
/// subscribes after a quick running -> idle -> running round trip still sees
/// the counter move, so a finished turn is never lost.
@MainActor
final class AgentWaitLedger {
    static let shared = AgentWaitLedger()

    struct Entry {
        var lifecycle = AgentHibernationLifecycleState.unknown
        var hasAgent = false
        var idleSeq = 0
        var needsInputSeq = 0
    }

    private var entries: [UUID: Entry] = [:]

    func entry(for panelId: UUID) -> Entry { entries[panelId] ?? Entry() }

    /// Records the surface's new aggregate state and publishes
    /// `agent.lifecycle.changed` when the state or the agent's presence moved.
    func note(workspaceId: UUID, panelId: UUID, lifecycle: AgentHibernationLifecycleState, hasAgent: Bool) {
        var entry = entries[panelId] ?? Entry()
        guard entry.lifecycle != lifecycle || entry.hasAgent != hasAgent else { return }
        if hasAgent, entry.lifecycle != lifecycle {
            if lifecycle == .idle { entry.idleSeq += 1 }
            if lifecycle == .needsInput { entry.needsInputSeq += 1 }
        }
        entry.lifecycle = lifecycle
        entry.hasAgent = hasAgent
        entries[panelId] = entry
        BreeEventBus.shared.publish(
            name: "agent.lifecycle.changed",
            category: "agent",
            source: "workspace",
            workspaceId: workspaceId.uuidString,
            surfaceId: panelId.uuidString,
            payload: [
                "lifecycle": lifecycle.rawValue,
                "agent": hasAgent,
                "idle_seq": entry.idleSeq,
                "needs_input_seq": entry.needsInputSeq,
            ]
        )
    }
}

extension TerminalController {
    /// `agent.state`: the lean read behind `bree agent wait`. Returns the
    /// surface's aggregate lifecycle, the idle / needs-input entry counters and
    /// `event_seq`, the event-bus cursor read BEFORE the state. Streaming
    /// `agent.lifecycle.changed` with `after_seq: event_seq` therefore replays
    /// every transition that the returned state might not include.
    /// Read-only; not allowlisted for the remote relay.
    nonisolated func v2AgentState(params: [String: Any]) -> V2CallResult {
        let eventSeq = BreeEventBus.shared.latestSequence
        let live: [String: Any]? = v2MainSync {
            guard let (workspace, surfaceId) = self.v2QueueResolveSurface(params: params) else { return nil }
            let entry = AgentWaitLedger.shared.entry(for: surfaceId)
            return [
                "surface_id": surfaceId.uuidString,
                "workspace_id": workspace.id.uuidString,
                "agent": workspace.agentLifecycleStatesByPanelId[surfaceId]?.isEmpty == false,
                "lifecycle": workspace.agentHibernationLifecycleState(panelId: surfaceId, fallback: nil).rawValue,
                "idle_seq": entry.idleSeq,
                "needs_input_seq": entry.needsInputSeq,
            ]
        }
        guard var payload = live else { return v2QueueSurfaceNotFound() }
        payload["event_seq"] = NSNumber(value: eventSeq)
        return .ok(payload)
    }
}

/// `snapshots.list` and `snapshots.restore` behind `bree snapshots`. Neither is
/// allowlisted in `RemoteRelayCommandPolicy`: restore rewrites the owner's
/// session file. Restore also freezes the current snapshot file for this
/// process (see `restoreLayoutHistoryEntry`), so the layout applies on the
/// next launch and the running app cannot overwrite it before then.
extension TerminalController {
    private nonisolated func v2SnapshotRepository() -> SessionSnapshotRepository<AppSessionSnapshot>? {
        v2MainSync { AppDelegate.shared?.sessionSnapshotStore as? SessionSnapshotRepository<AppSessionSnapshot> }
    }

    private nonisolated func v2SnapshotEntries(
        _ repository: SessionSnapshotRepository<AppSessionSnapshot>
    ) -> [(id: Int64, fileURL: URL, date: Date)] {
        repository.layoutHistory().map { (Int64($0.date.timeIntervalSince1970 * 1000), $0.fileURL, $0.date) }
    }

    nonisolated func v2SnapshotsList() -> V2CallResult {
        guard let repository = v2SnapshotRepository() else {
            return .err(code: "unavailable", message: "Session snapshots are unavailable.", data: nil)
        }
        let formatter = ISO8601DateFormatter()
        let entries: [[String: Any]] = v2SnapshotEntries(repository).map { entry in
            let size = (try? entry.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return ["id": String(entry.id), "date": formatter.string(from: entry.date), "bytes": size]
        }
        return .ok(["snapshots": entries])
    }

    nonisolated func v2SnapshotsRestore(params: [String: Any]) -> V2CallResult {
        guard let repository = v2SnapshotRepository() else {
            return .err(code: "unavailable", message: "Session snapshots are unavailable.", data: nil)
        }
        guard let id = params["id"] as? String, !id.isEmpty else {
            return .err(code: "invalid_params", message: "snapshots.restore requires id.", data: nil)
        }
        guard let entry = v2SnapshotEntries(repository).first(where: { String($0.id) == id }) else {
            return .err(code: "not_found", message: "No snapshot with id \(id).", data: nil)
        }
        guard repository.restoreLayoutHistoryEntry(entry.fileURL) else {
            return .err(code: "restore_failed", message: "Snapshot \(id) could not be restored.", data: nil)
        }
        return .ok(["id": id, "applies": "next_launch"])
    }
}
