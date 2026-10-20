import BreeFoundation
import AppKit
import Combine
import Foundation

/// Attention timestamps and away-change logs, keyed by panel and workspace id so
/// `Workspace` carries no new stored properties. Fed from three narrow hooks:
/// `Workspace.setAgentLifecycle`/`clearAgentLifecycle` (state transitions),
/// `TabManager.selectedWorkspaceIdDidChange` (seen + away watchers) and
/// `TabManager.closeWorkspace` (cleanup).
@MainActor
final class AttentionStore: ObservableObject {
    static let shared = AttentionStore()

    private struct RecordKey: Hashable {
        let panelId: UUID
        let agentKey: String
    }

    private struct Record {
        var lifecycle: AgentHibernationLifecycleState
        var failed: Bool
        var approval = false
        var sinceMs: Int64
    }

    /// Bumped on every transition or selection change so open views re-project.
    @Published private(set) var revision = 0
    /// Away change logs; a log is kept after reselect until the next switch or dismissal.
    @Published private(set) var changeLogs: [UUID: AttentionChangeLog] = [:]

    private var records: [RecordKey: Record] = [:]
    /// The single Resource-guard thermal row, `nil` while the Mac is not hot.
    private var thermalItem: AttentionItem?
    /// Journal `occurredAtMs` for the next transition of a key (startup replay).
    private var seeds: [RecordKey: Int64] = [:]
    /// Set by the journal apply path just before the lifecycle write, which
    /// maps `.error` to `.needsInput`.
    private var failedHints: Set<RecordKey> = []
    private var approvalHints: Set<RecordKey> = []
    private var seenAtMs: [UUID: Int64] = [:]
    /// Closed workspaces never get a watcher, even when the close races a selection change.
    private var closedWorkspaceIds: Set<UUID> = []
    private let launchMs = AttentionStore.nowMs()

    private final class AwayWatch {
        var task: Task<Void, Never>?
        var watcher: RecursivePathWatcher?
    }
    private var awayWatches: [UUID: AwayWatch] = [:]

    /// Workspaces watched only because the user was away while looking at them.
    private var awaySelectedIds: Set<UUID> = []

    private init() {
        installAwayObservers()
    }

    private func installAwayObservers() {
        let leave: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didResignActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.willSleepNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidResignActiveNotification),
        ]
        let back: [(NotificationCenter, Notification.Name)] = [
            (.default, NSApplication.didBecomeActiveNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification),
            (NSWorkspace.shared.notificationCenter, NSWorkspace.sessionDidBecomeActiveNotification),
        ]
        for (center, name) in leave {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userLeft() }
            }
        }
        for (center, name) in back {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.userReturned() }
            }
        }
    }

    /// The user left with agents possibly running in the workspace they are looking at:
    /// watch each window's selected workspace too.
    private func userLeft() {
        for manager in AppDelegate.shared?.allMainWindowTabManagersForDebug() ?? [] {
            guard let workspace = manager.selectedWorkspace,
                  !awaySelectedIds.contains(workspace.id),
                  awayWatches[workspace.id] == nil else { continue }
            changeLogs.removeValue(forKey: workspace.id)
            startAwayWatch(workspace)
            if awayWatches[workspace.id] != nil { awaySelectedIds.insert(workspace.id) }
        }
    }

    /// Back: stop the selected-workspace watchers but keep their lists on screen until the
    /// user dismisses them or switches workspace.
    private func userReturned() {
        for id in awaySelectedIds { stopAwayWatch(id) }
        awaySelectedIds.removeAll()
        revision &+= 1
    }

    nonisolated static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    // MARK: - Lifecycle transitions

    func seedSince(panelId: UUID, agentKey: String, occurredAtMs: Int64) {
        seeds[RecordKey(panelId: panelId, agentKey: agentKey)] = occurredAtMs
    }

    func noteFailedHint(panelId: UUID, agentKey: String, failed: Bool) {
        let key = RecordKey(panelId: panelId, agentKey: agentKey)
        if failed { failedHints.insert(key) } else { failedHints.remove(key) }
    }

    /// Set just before the lifecycle write: the needs-input came from a permission request.
    func noteApprovalHint(panelId: UUID, agentKey: String, approval: Bool) {
        let key = RecordKey(panelId: panelId, agentKey: agentKey)
        if approval { approvalHints.insert(key) } else { approvalHints.remove(key) }
    }

    /// Records when a panel's agent state was entered; no-op when it did not change.
    func noteLifecycle(panelId: UUID, agentKey: String, lifecycle: AgentHibernationLifecycleState) {
        let key = RecordKey(panelId: panelId, agentKey: agentKey)
        let failed = lifecycle == .needsInput && failedHints.remove(key) != nil
        let approval = lifecycle == .needsInput && approvalHints.contains(key)
        if let existing = records[key], existing.lifecycle == lifecycle, existing.failed == failed,
           existing.approval == approval {
            seeds.removeValue(forKey: key)
            return
        }
        records[key] = Record(
            lifecycle: lifecycle,
            failed: failed,
            approval: approval,
            sinceMs: seeds.removeValue(forKey: key) ?? Self.nowMs()
        )
        revision &+= 1
    }

    func noteLifecycleCleared(panelId: UUID, agentKey: String? = nil) {
        let before = records.count
        records = records.filter { $0.key.panelId != panelId || (agentKey != nil && $0.key.agentKey != agentKey) }
        if records.count != before { revision &+= 1 }
    }

    // MARK: - Projection

    /// Every agent pane that needs the user, ranked, plus changes-only rows.
    /// `ranked.first` is where Jump to Unread goes.
    func rankedItems(
        lastOutputByPanel: [UUID: String] = [:],
        pendingToolByPanel: [UUID: AttentionPendingTool] = [:]
    ) -> [AttentionItem] {
        projection(lastOutputByPanel: lastOutputByPanel, pendingToolByPanel: pendingToolByPanel).items
    }

    /// Ranked rows after the snooze filter, plus how many rows are snoozed.
    /// `showSnoozed` keeps them in the list, flagged.
    func projection(
        lastOutputByPanel: [UUID: String] = [:],
        pendingToolByPanel: [UUID: AttentionPendingTool] = [:],
        showSnoozed: Bool = false,
        includeSeenDone: Bool = false,
        hideFinished: Bool = false,
        nowMs: Int64 = AttentionStore.nowMs()
    ) -> (items: [AttentionItem], snoozedCount: Int) {
        let managers = AppDelegate.shared?.allMainWindowTabManagersForDebug() ?? []
        let notifications = AppDelegate.shared?.notificationStore?.notifications ?? []
        var items: [AttentionItem] = []
        var titles: [UUID: String] = [:]
        for manager in managers {
            for workspace in manager.tabs {
                titles[workspace.id] = workspace.title
                let isSelected = manager.selectedTabId == workspace.id
                for (panelId, states) in workspace.agentLifecycleStatesByPanelId {
                    guard workspace.panels[panelId] != nil else { continue }
                    var best: (state: AttentionState, sinceMs: Int64, agentKey: String, approval: Bool)?
                    for (agentKey, lifecycle) in states {
                        guard let record = records[RecordKey(panelId: panelId, agentKey: agentKey)],
                              record.lifecycle == lifecycle else { continue }
                        guard let state = attentionState(
                            for: record,
                            workspace: workspace,
                            agentKey: agentKey,
                            isSelected: isSelected,
                            includeSeenDone: includeSeenDone
                        ) else { continue }
                        if best == nil || state < best!.state {
                            best = (state, record.sinceMs, agentKey, record.approval)
                        }
                    }
                    guard let best else { continue }
                    let prompt = workspace.panelPrompts[panelId]?.message ?? workspace.latestSubmittedMessage
                    let notificationBody = notifications
                        .filter { $0.tabId == workspace.id && ($0.panelId ?? $0.surfaceId) == panelId }
                        .max(by: { $0.createdAt < $1.createdAt })?.body
                    let output = lastOutputByPanel[panelId] ?? notificationBody
                    let pendingTool = best.state == .needsInput ? pendingToolByPanel[panelId] : nil
                    let approval = best.state == .needsInput && (best.approval || AgentLensStore.shared.cards.contains {
                        $0.surfaceID == panelId && $0.state == .needsInput && $0.needsApproval
                    })
                    items.append(AttentionItem(
                        id: "\(workspace.id.uuidString)|\(panelId.uuidString)",
                        workspaceId: workspace.id,
                        panelId: panelId,
                        workspaceTitle: workspace.title,
                        paneTitle: workspace.panelTitle(panelId: panelId),
                        agentName: Self.plainAgentName(best.agentKey),
                        state: best.state,
                        sinceMs: best.sinceMs,
                        lastPrompt: AttentionRanking.oneLine(prompt),
                        lastOutput: AttentionRanking.lastLine(output),
                        pendingCommand: pendingTool?.summary,
                        riskNote: pendingTool.flatMap(AttentionRisk.first(for:))?.note,
                        needsApproval: approval
                    ))
                }
            }
        }
        if let thermalItem { items.append(thermalItem) }
        // Hidden rows must not count toward the snoozed footer.
        if hideFinished { items.removeAll { $0.state == .done || $0.state == .running } }
        let filtered = AttentionSnooze.apply(
            to: items,
            snoozes: snoozes,
            nowMs: nowMs,
            showSnoozed: showSnoozed
        )
        let ranked = AttentionRanking.rank(filtered.items)
        let withChanges = AttentionRanking.attachChangeCounts(
            to: ranked,
            counts: changeLogs.mapValues(\.count),
            titles: titles
        )
        return (withChanges, filtered.snoozedCount)
    }

    // MARK: - Snooze

    /// Snoozed rows by item id. In memory only: a restart brings every row back.
    private var snoozes: [String: AttentionSnoozeEntry] = [:]

    func snooze(_ item: AttentionItem) {
        guard AttentionSnooze.canSnooze(item) else { return }
        let now = Self.nowMs()
        snoozes = snoozes.filter { $0.value.untilMs > now }
        snoozes[item.id] = AttentionSnooze.entry(for: item, nowMs: now)
        revision &+= 1
    }

    func unsnooze(id: String) {
        guard snoozes.removeValue(forKey: id) != nil else { return }
        revision &+= 1
    }

    private func attentionState(
        for record: Record,
        workspace: Workspace,
        agentKey: String,
        isSelected: Bool,
        includeSeenDone: Bool
    ) -> AttentionState? {
        switch record.lifecycle {
        case .needsInput:
            let entryFailed = workspace.statusEntries[agentKey]?.icon?.contains("exclamationmark.triangle") == true
            return record.failed || entryFailed ? .failed : .needsInput
        case .running, .backgroundWorkPending:
            return .running
        case .idle:
            let seenAt = seenAtMs[workspace.id] ?? launchMs
            // The Board lists every recent finish, seen or not.
            return includeSeenDone
                || AttentionRanking.isUnseenDone(sinceMs: record.sinceMs, seenAtMs: seenAt, isSelected: isSelected)
                ? .done : nil
        case .unknown:
            return nil
        }
    }

    /// The workspace's top agent state and whether it is a permission request,
    /// read from the same records and `attentionState` rules as the Attention
    /// rows, so the sidebar row and Attention never disagree. `nil` when no
    /// agent pane has a record (plain shells keep their own running line).
    /// Seen finishes still count as done here.
    func topState(for workspace: Workspace) -> (state: AttentionState, approval: Bool)? {
        var best: (state: AttentionState, approval: Bool)?
        for (panelId, states) in workspace.agentLifecycleStatesByPanelId where workspace.panels[panelId] != nil {
            for (agentKey, lifecycle) in states {
                guard let record = records[RecordKey(panelId: panelId, agentKey: agentKey)],
                      record.lifecycle == lifecycle,
                      let state = attentionState(
                          for: record,
                          workspace: workspace,
                          agentKey: agentKey,
                          isSelected: false,
                          includeSeenDone: true
                      ) else { continue }
                let approval = state == .needsInput && (record.approval || AgentLensStore.shared.cards.contains {
                    $0.surfaceID == panelId && $0.state == .needsInput && $0.needsApproval
                })
                if best == nil || state < best!.state { best = (state, approval) }
            }
        }
        return best
    }

    /// The agent state entry time of a workspace's top agent pane, for the Pulse.
    func pulseSince(workspaceId: UUID, panelIds: [UUID]) -> Date? {
        let ms = records.filter { panelIds.contains($0.key.panelId) }.map(\.value.sinceMs).max()
        return ms.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    // MARK: - Jump

    /// Jumps to the highest-ranked blocked pane (needs input, then failed).
    /// Returns `false` when nothing is blocked, so callers fall back to unread notifications.
    @discardableResult
    func jumpToTopBlocked() -> Bool {
        let ranked = rankedItems()
        let current = AppDelegate.shared?.tabManager?.selectedWorkspace
        guard let target = AttentionRanking.nextJumpTarget(
            in: ranked,
            currentWorkspaceId: current?.id,
            currentPanelId: current?.focusedPanelId
        ) else { return false }
        return jump(to: target)
    }

    @discardableResult
    func jump(to item: AttentionItem) -> Bool {
        AppDelegate.shared?.openNotification(
            tabId: item.workspaceId,
            surfaceId: item.panelId,
            panelId: item.panelId,
            notificationId: nil
        ) ?? false
    }

    // MARK: - Selection, seen and away watchers

    /// `old` stops being selected: it is now "seen" up to this moment, its
    /// previous away list resets, and a fresh watcher starts. `new` is
    /// selected: it is seen and its watcher stops, keeping the list on screen.
    func workspaceSelectionChanged(old: Workspace?, new: Workspace?) {
        let now = Self.nowMs()
        if let new {
            seenAtMs[new.id] = now
            stopAwayWatch(new.id)
            awaySelectedIds.remove(new.id)
        }
        if let old, old.id != new?.id {
            seenAtMs[old.id] = now
            changeLogs.removeValue(forKey: old.id)
            startAwayWatch(old)
        }
        pruneWatches()
        revision &+= 1
    }

    func workspaceClosed(_ workspaceId: UUID) {
        closedWorkspaceIds.insert(workspaceId)
        stopAwayWatch(workspaceId)
        awaySelectedIds.remove(workspaceId)
        changeLogs.removeValue(forKey: workspaceId)
        seenAtMs.removeValue(forKey: workspaceId)
        // A closed workspace must never leave a stopped process group behind.
        ResourceGuard.shared.resume(workspaceId: workspaceId)
        if thermalItem?.workspaceId == workspaceId { thermalItem = nil }
        revision &+= 1
    }

    /// Raises or clears the one thermal attention item.
    func setThermalItem(_ item: AttentionItem?) {
        guard thermalItem != item else { return }
        thermalItem = item
        revision &+= 1
    }

    /// Dismisses a workspace's away list (Attention Center action).
    func dismissChanges(workspaceId: UUID) {
        guard changeLogs[workspaceId] != nil else { return }
        changeLogs.removeValue(forKey: workspaceId)
        revision &+= 1
    }

    private func pruneWatches() {
        let live = Set((AppDelegate.shared?.allMainWindowTabManagersForDebug() ?? []).flatMap { $0.tabs.map(\.id) })
        guard !live.isEmpty else { return }
        for id in awayWatches.keys where !live.contains(id) { stopAwayWatch(id) }
        for id in changeLogs.keys where !live.contains(id) { changeLogs.removeValue(forKey: id) }
    }

    private func stopAwayWatch(_ workspaceId: UUID) {
        guard let watch = awayWatches.removeValue(forKey: workspaceId) else { return }
        watch.task?.cancel()
        if let watcher = watch.watcher {
            Task { await watcher.stop() }
        }
    }

    private func startAwayWatch(_ workspace: Workspace) {
        let workspaceId = workspace.id
        stopAwayWatch(workspaceId)
        guard !closedWorkspaceIds.contains(workspaceId), !workspace.usesRemoteDirectoryProvenance else { return }
        let root = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard AttentionChangeRules.isWatchableRoot(root),
              FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory),
              isDirectory.boolValue else { return }
        let watch = AwayWatch()
        awayWatches[workspaceId] = watch
        let startedAt = Date()
        watch.task = Task { [weak self, weak watch] in
            let watcher = await RecursivePathWatcher(
                paths: [root],
                throttleInterval: .seconds(1),
                eventFilter: { change in
                    change.requiresFullRescan
                        || change.paths.contains { !AttentionChangeRules.shouldIgnore(path: $0, root: root) }
                }
            )
            guard let watcher else { return }
            guard !Task.isCancelled, let watch else {
                await watcher.stop()
                return
            }
            watch.watcher = watcher
            for await change in watcher.pathEvents {
                if Task.isCancelled { break }
                let changedPaths = change.paths
                let observed = await Task.detached(priority: .utility) {
                    AttentionChangeScanner.classify(paths: changedPaths, root: root, watchStartedAt: startedAt)
                }.value
                guard !Task.isCancelled else { break }
                self?.applyAwayChange(
                    workspaceId: workspaceId,
                    observed: observed,
                    truncated: change.requiresFullRescan
                )
            }
        }
    }

    private func applyAwayChange(
        workspaceId: UUID,
        observed: [(path: String, kind: AttentionChangeKind)],
        truncated: Bool
    ) {
        guard awayWatches[workspaceId] != nil else { return }
        var log = changeLogs[workspaceId] ?? AttentionChangeLog()
        for item in observed { log.record(path: item.path, kind: item.kind) }
        if truncated { log.markTruncated() }
        guard log != changeLogs[workspaceId] else { return }
        changeLogs[workspaceId] = log
        revision &+= 1
    }

    /// Attention agent keys can carry the feed prefix ("bree.feed.attention:claude code"); show the plain name.
    static func plainAgentName(_ key: String) -> String {
        let prefix = FeedCoordinator.attentionStatusKeyPrefix
        let plain = key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
        let name = SidebarCompactStatusGlyph.agentDisplayName(forStatusKey: plain)
        return name.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

/// Stats changed paths off the main thread. Directories are skipped (their own
/// mtime changes are noise); a missing path is a deletion; a file born after the
/// watcher started is created. FSEvents flags are not exposed by
/// `RecursivePathWatcher`, so a rename reads as a deletion plus a creation.
enum AttentionChangeScanner {
    nonisolated static func classify(
        paths: [String],
        root: String,
        watchStartedAt: Date
    ) -> [(path: String, kind: AttentionChangeKind)] {
        var result: [(path: String, kind: AttentionChangeKind)] = []
        for path in paths where !AttentionChangeRules.shouldIgnore(path: path, root: root) {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]) else {
                result.append((path, .deleted))
                continue
            }
            if values.isDirectory == true { continue }
            let born = values.creationDate ?? .distantPast
            result.append((path, born >= watchStartedAt.addingTimeInterval(-1) ? .created : .modified))
        }
        return result
    }

}
