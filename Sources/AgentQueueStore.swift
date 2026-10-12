import CMUXAgentLaunch
import Combine
import Foundation

/// Messages `bree queue` holds for a pane until its agent rests.
///
/// In app memory only (lost on quit), keyed by terminal surface id, at most
/// ``capacity`` per surface. `AgentJournalLifecycleCenter.apply` calls
/// ``noteIdle(panelId:workspace:)`` when a pane's agent becomes idle; the
/// oldest message is typed (plus Enter) only when the prompt is free, one per
/// idle transition. ``counts`` is published for a "1 queued" marker in views.
@MainActor
final class AgentQueueStore: ObservableObject {
    static let shared = AgentQueueStore()
    static let capacity = 20

    /// Queued message count per surface (only non-empty entries).
    @Published private(set) var counts: [UUID: Int] = [:]
    private var queues: [UUID: [String]] = [:]

    func count(panelId: UUID) -> Int { queues[panelId]?.count ?? 0 }

    func list(panelId: UUID) -> [String] { queues[panelId] ?? [] }

    /// Appends `text`; returns the new queue length, or nil when the queue is full.
    func add(_ text: String, panelId: UUID) -> Int? {
        var queue = queues[panelId] ?? []
        guard queue.count < Self.capacity else { return nil }
        queue.append(text)
        queues[panelId] = queue
        counts[panelId] = queue.count
        return queue.count
    }

    /// Removes every message of the surface; returns how many were dropped.
    @discardableResult
    func clear(panelId: UUID) -> Int {
        let dropped = queues.removeValue(forKey: panelId)?.count ?? 0
        counts.removeValue(forKey: panelId)
        return dropped
    }

    /// Types the oldest queued message when the agent is idle and the prompt is
    /// free (no half-typed draft, no open dialog: the rule `bree send` applies).
    /// Otherwise keeps it for the next idle transition. Returns true when typed.
    @discardableResult
    func noteIdle(panelId: UUID, workspace: Workspace) -> Bool {
        guard var queue = queues[panelId], let next = queue.first else { return false }
        guard workspace.agentHibernationLifecycleState(panelId: panelId, fallback: nil) == .idle,
              let panel = workspace.panels[panelId] as? TerminalPanel else { return false }
        // A shell back at its own prompt means no agent is in the foreground
        // (crash, Ctrl+C or exit without SessionEnd leaves the lifecycle idle):
        // typing now would run the message as a shell command. Keep it queued.
        if workspace.panelShellActivityStates[panelId] == .promptIdle { return false }
        let hasAgent = workspace.agentLifecycleStatesByPanelId[panelId]?.isEmpty == false
        switch TerminalController.agentPromptInputState(of: panel.surface) {
        case .draft, .dialog:
            if hasAgent { return false }
        case .empty, .unknown:
            break
        }
        guard panel.sendInputResult(next + "\r").accepted else { return false }
        queue.removeFirst()
        if queue.isEmpty {
            queues.removeValue(forKey: panelId)
            counts.removeValue(forKey: panelId)
        } else {
            queues[panelId] = queue
            counts[panelId] = queue.count
        }
        return true
    }
}
