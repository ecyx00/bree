import AppKit
import BreeFoundation
import Combine
import Foundation

/// One agent on the Board. Pure value, rebuilt from the Attention data (Bree panes)
/// and `claude agents --json --all` (sessions outside Bree).
struct BoardCard: Identifiable, Equatable {
    /// Display order of the lanes.
    enum Lane: Int, CaseIterable {
        case needsYou, running, error, done
    }

    enum Source: Equatable {
        case bree(workspaceId: UUID, panelId: UUID?)
        case outside(OutsideAgent)
    }

    let id: String
    let lane: Lane
    let name: String
    /// Last two path parts of the working directory.
    let project: String
    let agentKind: String
    let stateWord: String
    let sinceMs: Int64
    /// Current action ("Edit a.swift"), the pending command, or the last output line.
    let detail: String?
    let riskNote: String?
    let source: Source
}

/// A row of `claude agents --json --all`.
struct OutsideAgent: Equatable, Sendable, Decodable {
    let pid: Int?
    let cwd: String?
    let kind: String?
    let startedAt: Int64?
    let sessionId: String
    let name: String?
    let status: String?
}

/// Reads the `claude` CLI off the main thread. A missing binary reads as "no outside agents".
enum BoardClaudeCLI {
    private static let timeout: TimeInterval = 8

    /// `nil` when `claude` is missing or fails: the caller hides the source quietly.
    static func listAgents() async -> [OutsideAgent]? {
        await Task.detached(priority: .utility) {
            guard let out = run(["agents", "--json", "--all"]),
                  let rows = try? JSONDecoder().decode([OutsideAgent].self, from: out) else { return nil }
            return rows
        }.value
    }

    private static func run(_ arguments: [String]) -> Data? {
        guard let path = WikiToolLookup.executable(for: "claude") else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (WikiToolLookup.loginPath + WikiToolLookup.fixedFolders).joined(separator: ":")
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }
}

@MainActor
final class BoardModel: ObservableObject {
    /// "Done" keeps the last few hours only.
    static let doneWindowMs: Int64 = 4 * 3600 * 1000
    static let doneLimit = 20
    private static let outsideInterval: Duration = .seconds(5)

    @Published private(set) var cards: [BoardCard] = []
    @Published var selectedId: String?
    /// Height of the lanes, measured by the view; the popover follows it.
    @Published var contentHeight: CGFloat = 0
    /// Closes the popover; set by its controller.
    var close: (() -> Void)?

    private var outside: [OutsideAgent] = []
    /// When each outside session entered its current status, as first seen by this sampler
    /// (`startedAt` for the first sighting). `claude agents` has no state-change time.
    private var outsideSince: [String: (status: String, sinceMs: Int64)] = [:]
    private var breeCards: [BoardCard] = []
    private var cancellables: Set<AnyCancellable> = []
    private var outsideTask: Task<Void, Never>?
    private var breeTask: Task<Void, Never>?

    func lane(_ lane: BoardCard.Lane) -> [BoardCard] { cards.filter { $0.lane == lane } }

    // MARK: - Lifecycle (only while the Board is visible)

    func start() {
        guard cancellables.isEmpty else { return }
        AttentionStore.shared.$revision
            .merge(with: AgentLensStore.shared.$cards.map { _ in 0 })
            .sink { [weak self] _ in self?.refreshBree() }
            .store(in: &cancellables)
        refreshBree()
        outsideTask = Task { [weak self] in
            while !Task.isCancelled {
                let rows = await BoardClaudeCLI.listAgents()
                guard !Task.isCancelled else { return }
                self?.applyOutside(rows)
                try? await Task.sleep(for: Self.outsideInterval)
            }
        }
    }

    func stop() {
        cancellables.removeAll()
        outsideTask?.cancel()
        outsideTask = nil
        breeTask?.cancel()
        breeTask = nil
    }

    // MARK: - Bree panes

    private func refreshBree() {
        breeTask?.cancel()
        breeTask = Task { [weak self] in
            let tools = await AttentionPendingTool.loadByPanel()
            guard !Task.isCancelled, let self else { return }
            self.breeCards = self.makeBreeCards(pendingTools: tools)
            self.rebuild()
        }
    }

    private func makeBreeCards(pendingTools: [UUID: AttentionPendingTool]) -> [BoardCard] {
        let nowMs = AttentionStore.nowMs()
        let projection = AttentionStore.shared.projection(
            pendingToolByPanel: pendingTools,
            showSnoozed: true,
            includeSeenDone: true,
            nowMs: nowMs
        )
        let lens = AgentLensStore.shared.cards
        var result: [BoardCard] = []
        for item in projection.items {
            guard let state = item.state, state != .thermal, let panelId = item.panelId else { continue }
            let since = item.sinceMs ?? nowMs
            let lane: BoardCard.Lane
            switch state {
            case .needsInput: lane = .needsYou
            case .running: lane = .running
            case .failed: lane = .error
            case .done:
                guard nowMs - since <= Self.doneWindowMs else { continue }
                lane = .done
            case .thermal: continue
            }
            let step = lens.first { $0.surfaceID == panelId }?.step
            let detail: String?
            switch lane {
            case .running: detail = step.map(Self.actionText) ?? item.lastPrompt
            case .needsYou: detail = item.pendingCommand ?? item.lastOutput
            case .error, .done: detail = item.lastOutput
            }
            let directory = AppDelegate.shared?.tabManagerFor(tabId: item.workspaceId)?
                .workspacesById[item.workspaceId]?.currentDirectory
            result.append(BoardCard(
                id: item.id,
                lane: lane,
                name: item.workspaceTitle,
                project: Self.project(of: directory),
                agentKind: item.agentName ?? "",
                stateWord: AttentionStyle.word(for: state, needsApproval: item.needsApproval) ?? "",
                sinceMs: since,
                detail: detail,
                riskNote: item.riskNote,
                source: .bree(workspaceId: item.workspaceId, panelId: panelId)
            ))
        }
        return result
    }

    // MARK: - Outside Bree

    private func applyOutside(_ rows: [OutsideAgent]?) {
        outside = rows ?? []
        let now = AttentionStore.nowMs()
        var seen: [String: (status: String, sinceMs: Int64)] = [:]
        for row in outside {
            let status = (row.status ?? "").lowercased()
            if let known = outsideSince[row.sessionId], known.status == status {
                seen[row.sessionId] = known
            } else {
                // First sighting: the state is at least as old as the session's start only for a
                // fresh session; otherwise it began no later than now.
                seen[row.sessionId] = (status, row.startedAt ?? now)
            }
        }
        outsideSince = seen
        rebuild()
    }

    private func makeOutsideCards(excluding breeSessionIds: Set<String>) -> [BoardCard] {
        let nowMs = AttentionStore.nowMs()
        var result: [BoardCard] = []
        for row in outside where !breeSessionIds.contains(row.sessionId) {
            let status = outsideSince[row.sessionId]?.status ?? (row.status ?? "").lowercased()
            let since = outsideSince[row.sessionId]?.sinceMs ?? row.startedAt ?? nowMs
            let lane: BoardCard.Lane
            let word: String
            switch status {
            case "busy", "running", "working":
                lane = .running
                word = AttentionStyle.word(for: .running) ?? ""
            case let s where ["wait", "input", "permission", "approval", "blocked"].contains(where: s.contains):
                lane = .needsYou
                word = AttentionStyle.word(for: .needsInput) ?? ""
            case let s where ["fail", "error"].contains(where: s.contains):
                lane = .error
                word = AttentionStyle.word(for: .failed) ?? ""
            default:
                guard nowMs - since <= Self.doneWindowMs else { continue }
                lane = .done
                word = status == "idle"
                    ? String(localized: "board.state.idle", defaultValue: "Idle")
                    : AttentionStyle.word(for: .done) ?? ""
            }
            let cwd = row.cwd
            let kind = row.kind == "background"
                ? String(localized: "board.kind.background", defaultValue: "Background")
                : String(localized: "board.kind.interactive", defaultValue: "Interactive")
            result.append(BoardCard(
                id: "outside|" + row.sessionId,
                lane: lane,
                name: row.name ?? cwd.map { ($0 as NSString).lastPathComponent } ?? row.sessionId,
                project: Self.project(of: cwd),
                agentKind: "Claude Code · " + kind,
                stateWord: word,
                sinceMs: since,
                detail: nil,
                riskNote: nil,
                source: .outside(row)
            ))
        }
        return result
    }

    // MARK: - Merge

    private func rebuild() {
        // An agent never shows twice: Bree panes win over `claude agents` rows with the same session.
        let breeSessionIds = Set(AgentLensStore.shared.cards.filter { $0.surfaceID != nil }.flatMap {
            [$0.id, $0.claudeSessionID].compactMap { $0 }
        })
        var all = breeCards + makeOutsideCards(excluding: breeSessionIds)
        // Longest-waiting first for lanes that block on the owner; newest first elsewhere.
        all.sort { lhs, rhs in
            if lhs.lane != rhs.lane { return lhs.lane.rawValue < rhs.lane.rawValue }
            return lhs.lane == .needsYou ? lhs.sinceMs < rhs.sinceMs : lhs.sinceMs > rhs.sinceMs
        }
        var doneSeen = 0
        all = all.filter { card in
            guard card.lane == .done else { return true }
            doneSeen += 1
            return doneSeen <= Self.doneLimit
        }
        if all != cards { cards = all }
        if let selectedId, !all.contains(where: { $0.id == selectedId }) { self.selectedId = nil }
    }

    // MARK: - Actions

    /// Focuses the workspace and pane of a Bree card in the main window.
    func focus(_ card: BoardCard) {
        guard case .bree(let workspaceId, let panelId) = card.source else { return }
        let jumped = AppDelegate.shared?.openNotification(
            tabId: workspaceId,
            surfaceId: panelId,
            panelId: panelId,
            notificationId: nil
        ) ?? false
        if !jumped { NSSound.beep() }
    }

    // MARK: - Text

    private static func actionText(_ step: AgentLensCard.Step) -> String {
        guard let target = step.target, !target.isEmpty else { return step.tool }
        let shown = target.contains("/") ? (target as NSString).lastPathComponent : target
        return step.tool + " " + shown
    }

    /// The last two path parts, e.g. "Projects/bree".
    static func project(of path: String?) -> String {
        guard let path, !path.isEmpty else { return "" }
        let parts = path.split(separator: "/").suffix(2)
        return parts.joined(separator: "/")
    }
}
