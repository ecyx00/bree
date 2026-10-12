import Combine
import CmuxFoundation
import Foundation

/// One line of the Activity timeline. `detail` is the agent name, port or file name.
struct WorkspaceActivityEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case agentStarted, agentFinished, agentNeedsInput, agentFailed, portOpened, portClosed
        /// Kept so timelines persisted by older builds still decode; no longer recorded.
        case artifact
    }

    var id = UUID()
    var kind: Kind
    var detail: String = ""
    /// Seconds since 1970.
    var at: TimeInterval
    var surfaceId: UUID?
    var path: String?

    var label: String {
        switch kind {
        case .agentStarted: return String(localized: "activity.event.agentStarted", defaultValue: "Prompt sent")
        case .agentFinished: return String(format: String(localized: "activity.event.agentFinished", defaultValue: "%@ finished"), detail)
        case .agentNeedsInput: return String(format: String(localized: "activity.event.agentNeedsInput", defaultValue: "%@ needs input"), detail)
        case .agentFailed: return String(format: String(localized: "activity.event.agentFailed", defaultValue: "%@ failed"), detail)
        case .portOpened: return String(format: String(localized: "activity.event.portOpened", defaultValue: "Port %@ opened"), detail)
        case .portClosed: return String(format: String(localized: "activity.event.portClosed", defaultValue: "Port %@ closed"), detail)
        case .artifact: return String(format: String(localized: "activity.event.artifact", defaultValue: "%@ appeared"), detail)
        }
    }
}

struct WorkspaceArtifact: Equatable, Identifiable {
    var path: String
    /// Seconds since 1970: last event of the Claude session that edited the file.
    var at: TimeInterval
    var id: String { path }
}

/// Per-workspace Artifact Shelf and Timeline. Pure value type so the caps and pruning are unit-testable.
struct WorkspaceActivity: Codable, Equatable {
    static let eventCap = 200

    var events: [WorkspaceActivityEvent] = []
    /// Shelf removals; the file returns only when Claude touches it again after this time.
    var dismissed: [String: TimeInterval] = [:]
    var touched: TimeInterval = 0

    /// Newest first, capped.
    mutating func record(_ event: WorkspaceActivityEvent) {
        events.insert(event, at: 0)
        if events.count > Self.eventCap { events.removeLast(events.count - Self.eventCap) }
        touched = max(touched, event.at)
    }

    mutating func removeArtifact(path: String, now: TimeInterval) {
        dismissed[path] = now
    }

    /// Drops workspaces untouched for more than `maxAge` seconds.
    static func pruned(
        _ all: [UUID: WorkspaceActivity],
        now: TimeInterval,
        maxAge: TimeInterval = 14 * 24 * 3600
    ) -> [UUID: WorkspaceActivity] {
        all.filter { now - $0.value.touched <= maxAge }
    }
}

enum WorkspaceActivityRules {
    /// Maps a notification to a timeline kind; nil when it is not an agent lifecycle signal.
    static func agentKind(isAgentEvent: Bool, category: String?, isError: Bool) -> WorkspaceActivityEvent.Kind? {
        guard isAgentEvent || category != nil else { return nil }
        if isError { return .agentFailed }
        switch category {
        case "turn-complete": return .agentFinished
        case "needs-permission", "idle-reminder": return .agentNeedsInput
        default: return nil
        }
    }

    static func symbolName(forPath path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "svg": return "photo"
        case "pdf": return "doc.richtext"
        case "html", "htm": return "globe"
        case "csv", "tsv": return "tablecells"
        case "json": return "curlybraces"
        case "diff", "patch": return "plus.forwardslash.minus"
        case "md", "txt", "log": return "doc.text"
        default: return "doc"
        }
    }

    /// Files Claude edited or wrote in this workspace's live sessions: newest session first,
    /// each session's own recency order kept, deduped by path, dismissed ones hidden until
    /// the session touches again. `at` is the owning session's last event (cards carry no per-file time).
    static func claudeEditedFiles(
        cards: [AgentLensCard], ended: [AgentLensStore.EndedSession] = [],
        workspaceId: UUID, dismissed: [String: TimeInterval], cap: Int = 50
    ) -> [WorkspaceArtifact] {
        var seen = Set<String>()
        var result: [WorkspaceArtifact] = []
        // Live sessions plus the retained files of ended ones, newest first.
        let sources = cards.filter { $0.workspaceID == workspaceId }.map { ($0.lastEventAt, $0.files) }
            + ended.map { ($0.at, $0.files) }
        for (when, files) in sources.sorted(by: { $0.0 > $1.0 }) {
            let at = when.timeIntervalSince1970
            for path in files where seen.insert(path).inserted {
                if let dismissedAt = dismissed[path], at <= dismissedAt { continue }
                result.append(WorkspaceArtifact(path: path, at: at))
                if result.count == cap { return result }
            }
        }
        return result
    }
}

/// One JSON per bundle id, next to the Files navigation file; nil under automated tests.
enum WorkspaceActivityStorage {
    nonisolated static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard let nav = FileExplorerNavigationStorage.defaultFileURL(
            bundleIdentifier: bundleIdentifier, isRunningUnderAutomatedTests: isRunningUnderAutomatedTests
        ) else { return nil }
        let name = nav.lastPathComponent.replacingOccurrences(of: "file-explorer-navigation-", with: "workspace-activity-")
        return nav.deletingLastPathComponent().appendingPathComponent(name, isDirectory: false)
    }

    static func read(_ url: URL, now: TimeInterval = Date().timeIntervalSince1970) -> [UUID: WorkspaceActivity] {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: WorkspaceActivity].self, from: data) else { return [:] }
        var result: [UUID: WorkspaceActivity] = [:]
        for (key, value) in raw { if let id = UUID(uuidString: key) { result[id] = value } }
        return WorkspaceActivity.pruned(result, now: now)
    }

    static func write(_ all: [UUID: WorkspaceActivity], to url: URL) {
        guard let data = try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: all.map { ($0.key.uuidString, $0.value) })) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// App-wide recorder behind the right sidebar's Activity mode. Subscribes to the
/// notification store (agent lifecycle) and each workspace's ports; never polls.
@MainActor
final class WorkspaceActivityStore: ObservableObject {
    static let shared = WorkspaceActivityStore()

    @Published private(set) var byWorkspace: [UUID: WorkspaceActivity]
    /// Review station turn records keyed by lowercased workspace id, newest first.
    /// Written by the hook process (`cmux` CLI); the app only reads it and flips `reviewed`.
    @Published private(set) var turnRecords: [String: [AgentTurnRecord]] = [:]
    private let fileURL: URL?
    private let saveScheduler = MainActorDeferredActionScheduler()
    private var attachedManagers: Set<ObjectIdentifier> = []
    private var cancellables: [AnyCancellable] = []
    private var workspaceCancellables: [UUID: [AnyCancellable]] = [:]
    private var lastPorts: [UUID: Set<Int>] = [:]
    private var seenNotificationIds: Set<UUID>?

    init(fileURL: URL? = WorkspaceActivityStorage.defaultFileURL()) {
        self.fileURL = fileURL
        self.byWorkspace = fileURL.map { WorkspaceActivityStorage.read($0) } ?? [:]
    }

    func activity(for workspaceId: UUID) -> WorkspaceActivity {
        byWorkspace[workspaceId] ?? WorkspaceActivity()
    }

    func turnRecords(for workspaceId: UUID) -> [AgentTurnRecord] {
        turnRecords[workspaceId.uuidString.lowercased()] ?? []
    }

    /// Re-reads the shared turn-record file off the main actor. No-op under automated tests.
    func reloadTurnRecords() async {
        guard fileURL != nil else { return }
        let file = await Task.detached(priority: .utility) {
            AgentTurnRecordStorage.read(path: AgentTurnRecordStorage.path())
        }.value
        let grouped = Dictionary(grouping: file.records, by: \.workspaceId)
            .mapValues { $0.sorted { $0.finishedAt > $1.finishedAt } }
        if grouped != turnRecords { turnRecords = grouped }
    }

    /// The hook writes the record around the time the finish notification arrives; re-read twice.
    private func scheduleTurnRecordReload() {
        Task { [weak self] in
            for delay in [Duration.milliseconds(600), .seconds(3)] {
                try? await Task.sleep(for: delay)
                await self?.reloadTurnRecords()
            }
        }
    }

    func markReviewed(_ record: AgentTurnRecord) {
        guard !record.reviewed, fileURL != nil else { return }
        let id = record.id
        if var list = turnRecords[record.workspaceId], let index = list.firstIndex(where: { $0.id == id }) {
            list[index].reviewed = true
            turnRecords[record.workspaceId] = list
        }
        Task.detached(priority: .utility) {
            try? AgentTurnRecordStorage.update(path: AgentTurnRecordStorage.path()) { $0.markReviewed(id: id) }
        }
    }

    func record(
        _ kind: WorkspaceActivityEvent.Kind, detail: String = "", workspaceId: UUID,
        surfaceId: UUID? = nil, path: String? = nil, at: Date = Date()
    ) {
        mutate(workspaceId) {
            $0.record(WorkspaceActivityEvent(
                kind: kind, detail: detail, at: at.timeIntervalSince1970, surfaceId: surfaceId, path: path))
        }
    }

    func removeArtifact(path: String, workspaceId: UUID) {
        mutate(workspaceId) { $0.removeArtifact(path: path, now: Date().timeIntervalSince1970) }
    }

    /// Idempotent per window. Safe to call from a view's onAppear.
    func attach(tabManager: TabManager) {
        guard attachedManagers.insert(ObjectIdentifier(tabManager)).inserted else { return }
        Task { await reloadTurnRecords() }
        tabManager.tabsPublisher
            .sink { [weak self] workspaces in
                guard let self else { return }
                for workspace in workspaces { self.observe(workspace) }
            }
            .store(in: &cancellables)
        guard seenNotificationIds == nil else { return }
        seenNotificationIds = []
        TerminalNotificationStore.shared.$notifications
            .sink { [weak self] in self?.ingest($0) }
            .store(in: &cancellables)
    }

    private func observe(_ workspace: Workspace) {
        let id = workspace.id
        guard workspaceCancellables[id] == nil else { return }
        // ponytail: subscriptions are never torn down per workspace; weak refs keep them cheap.
        workspaceCancellables[id] = [
            workspace.$listeningPorts
                .sink { [weak self] in self?.portsChanged(Set($0), workspaceId: id) },
            workspace.$latestSubmittedAt
                .dropFirst()
                .compactMap { $0 }
                .sink { [weak self] in self?.record(.agentStarted, workspaceId: id, at: $0) },
        ]
    }

    private func portsChanged(_ ports: Set<Int>, workspaceId: UUID) {
        let previous = lastPorts.updateValue(ports, forKey: workspaceId)
        guard let previous else { return }
        for port in ports.subtracting(previous).sorted().prefix(5) {
            record(.portOpened, detail: String(port), workspaceId: workspaceId)
        }
        for port in previous.subtracting(ports).sorted().prefix(5) {
            record(.portClosed, detail: String(port), workspaceId: workspaceId)
        }
    }

    private func ingest(_ notifications: [TerminalNotification]) {
        let seen = seenNotificationIds ?? []
        seenNotificationIds = Set(notifications.map(\.id))
        // The first emission and history restored after launch are old; only fresh ones are events.
        for notification in notifications where !seen.contains(notification.id)
            && Date().timeIntervalSince(notification.createdAt) < 60 {
            guard let kind = WorkspaceActivityRules.agentKind(
                isAgentEvent: notification.isAgentEvent,
                category: notification.agentCategory,
                isError: notification.soundContext?.alertType == .errorStalled
            ) else { continue }
            record(
                kind,
                detail: notification.agentKind?.capitalized ?? notification.title,
                workspaceId: notification.tabId, surfaceId: notification.surfaceId,
                at: notification.createdAt)
            if kind == .agentFinished { scheduleTurnRecordReload() }
        }
    }

    private func mutate(_ workspaceId: UUID, _ change: (inout WorkspaceActivity) -> Void) {
        var activity = byWorkspace[workspaceId] ?? WorkspaceActivity()
        change(&activity)
        byWorkspace[workspaceId] = activity
        guard let url = fileURL else { return }
        saveScheduler.schedule(after: .seconds(1)) { [weak self] in
            guard let self else { return }
            WorkspaceActivityStorage.write(
                WorkspaceActivity.pruned(self.byWorkspace, now: Date().timeIntervalSince1970), to: url)
        }
    }
}
