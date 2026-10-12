import Foundation

/// What an agent pane asks of the user, in the order the Attention Center ranks it.
enum AttentionState: Int, Comparable, Sendable {
    /// System thermal pressure (Resource guard); outranks every agent state.
    case thermal = -1
    case needsInput = 0
    case failed = 1
    case done = 2
    case running = 3

    static func < (lhs: AttentionState, rhs: AttentionState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// States where the agent is blocked on the user; they sort longest-waiting first.
    var isBlocking: Bool { self == .needsInput || self == .failed }
}

/// One row of the Attention Center. `state == nil` is a changes-only row: a
/// workspace with files changed while the user was away but no agent to report.
struct AttentionItem: Identifiable, Equatable, Sendable {
    let id: String
    let workspaceId: UUID
    let panelId: UUID?
    let workspaceTitle: String
    let paneTitle: String?
    let agentName: String?
    let state: AttentionState?
    /// When the state was entered, in ms since the Unix epoch.
    let sinceMs: Int64?
    let lastPrompt: String?
    let lastOutput: String?
    var changedCount: Int = 0
    /// One-line command or file the agent waits for approval on; in-app only.
    var pendingCommand: String?
    /// Localized warning when the pending command matches a risk rule.
    var riskNote: String?
    /// While `state == .needsInput`: a permission request (approval), not a question. From the
    /// same `AgentLensCard.needsApproval` the sidebar row uses.
    var needsApproval: Bool = false
    /// Set when the row is shown although the user snoozed it.
    var isSnoozed: Bool = false
}

/// What a snooze remembers about the row, so a change of state wakes it early.
struct AttentionSnoozeEntry: Equatable, Sendable {
    let untilMs: Int64
    let state: AttentionState?
    let sinceMs: Int64?
}

/// Pure snooze filter: runs before ranking.
enum AttentionSnooze {
    static let durationMs: Int64 = 10 * 60 * 1000

    static func entry(for item: AttentionItem, nowMs: Int64) -> AttentionSnoozeEntry {
        AttentionSnoozeEntry(untilMs: nowMs + durationMs, state: item.state, sinceMs: item.sinceMs)
    }

    /// Only agent rows can be snoozed; thermal and changes-only rows cannot.
    static func canSnooze(_ item: AttentionItem) -> Bool {
        guard let state = item.state else { return false }
        return state != .thermal
    }

    /// A snooze holds until it expires or the row's state or `sinceMs` changes.
    static func isActive(_ entry: AttentionSnoozeEntry, for item: AttentionItem, nowMs: Int64) -> Bool {
        nowMs < entry.untilMs && entry.state == item.state && entry.sinceMs == item.sinceMs
    }

    /// Drops snoozed rows (or flags them when `showSnoozed`) and counts them.
    static func apply(
        to items: [AttentionItem],
        snoozes: [String: AttentionSnoozeEntry],
        nowMs: Int64,
        showSnoozed: Bool
    ) -> (items: [AttentionItem], snoozedCount: Int) {
        guard !snoozes.isEmpty else { return (items, 0) }
        var result: [AttentionItem] = []
        var count = 0
        for item in items {
            if let entry = snoozes[item.id], isActive(entry, for: item, nowMs: nowMs) {
                count += 1
                if showSnoozed {
                    var copy = item
                    copy.isSnoozed = true
                    result.append(copy)
                }
            } else {
                result.append(item)
            }
        }
        return (result, count)
    }
}

/// Pure ranking and formatting rules; kept free of app state so tests can run them.
enum AttentionRanking {
    /// Needs input, then failed, then done-unseen, then running, then changes-only rows.
    /// Blocked states list the longest wait first; the others list the newest first.
    static func rank(_ items: [AttentionItem]) -> [AttentionItem] {
        items.sorted { lhs, rhs in
            switch (lhs.state, rhs.state) {
            case (nil, nil): break
            case (nil, _): return false
            case (_, nil): return true
            case (let l?, let r?):
                if l != r { return l < r }
                let lSince = lhs.sinceMs ?? 0
                let rSince = rhs.sinceMs ?? 0
                if lSince != rSince {
                    return l.isBlocking ? lSince < rSince : lSince > rSince
                }
            }
            return lhs.id < rhs.id
        }
    }

    /// A done state counts as unseen until the user has selected the workspace
    /// since the state was entered. A selected workspace is being looked at.
    static func isUnseenDone(sinceMs: Int64, seenAtMs: Int64, isSelected: Bool) -> Bool {
        !isSelected && sinceMs > seenAtMs
    }

    /// Puts each workspace's changed-file count on its top-ranked row and adds a
    /// changes-only row for workspaces that have changes but no agent row.
    /// `ranked` must already be ranked; the result stays ranked.
    static func attachChangeCounts(
        to ranked: [AttentionItem],
        counts: [UUID: Int],
        titles: [UUID: String]
    ) -> [AttentionItem] {
        var remaining = counts.filter { $0.value > 0 }
        var result = ranked.map { item -> AttentionItem in
            guard let count = remaining.removeValue(forKey: item.workspaceId) else { return item }
            var copy = item
            copy.changedCount = count
            return copy
        }
        let extras = remaining.keys.sorted { $0.uuidString < $1.uuidString }.map { workspaceId in
            AttentionItem(
                id: "\(workspaceId.uuidString)|changes",
                workspaceId: workspaceId,
                panelId: nil,
                workspaceTitle: titles[workspaceId] ?? "",
                paneTitle: nil,
                agentName: nil,
                state: nil,
                sinceMs: nil,
                lastPrompt: nil,
                lastOutput: nil,
                changedCount: remaining[workspaceId] ?? 0
            )
        }
        result.append(contentsOf: extras)
        return result
    }

    /// Items an agent is blocked on, in rank order: the targets of Jump to Unread.
    static func blockingItems(_ ranked: [AttentionItem]) -> [AttentionItem] {
        ranked.filter { $0.state?.isBlocking == true }
    }

    /// The next blocked pane to jump to. Repeated jumps cycle: the pane already
    /// focused is skipped, so a second press moves on instead of sticking.
    static func nextJumpTarget(
        in ranked: [AttentionItem],
        currentWorkspaceId: UUID?,
        currentPanelId: UUID?
    ) -> AttentionItem? {
        blockingItems(ranked).first { item in
            !(item.workspaceId == currentWorkspaceId && item.panelId == currentPanelId)
        }
    }

    enum TimeBucket: Equatable {
        case now
        case minutes(Int)
        case hours(Int)
        case days(Int)
    }

    static func timeBucket(sinceMs: Int64, nowMs: Int64) -> TimeBucket {
        let seconds = max(0, (nowMs - sinceMs) / 1000)
        if seconds < 60 { return .now }
        let minutes = seconds / 60
        if minutes < 60 { return .minutes(Int(minutes)) }
        let hours = minutes / 60
        if hours < 24 { return .hours(Int(hours)) }
        return .days(Int(hours / 24))
    }

    /// "now", "12m", "3h", "2d" (localized unit letters).
    static func relativeLabel(sinceMs: Int64, nowMs: Int64) -> String {
        let unit: Duration
        switch timeBucket(sinceMs: sinceMs, nowMs: nowMs) {
        case .now:
            return String(localized: "attention.time.now", defaultValue: "now")
        case .minutes(let value): unit = .seconds(value * 60)
        case .hours(let value): unit = .seconds(value * 3600)
        case .days(let value): unit = .seconds(value * 86400)
        }
        return unit.formatted(.units(
            allowed: [.days, .hours, .minutes],
            width: .narrow,
            maximumUnitCount: 1
        ))
    }

    /// Collapses whitespace and newlines into one short line; `nil` when empty.
    static func oneLine(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let collapsed = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }

    /// The last non-empty line of an agent's output, as one line.
    static func lastLine(_ text: String?, limit: Int = 160) -> String? {
        guard let text else { return nil }
        let line = text
            .split(whereSeparator: { $0.isNewline })
            .last(where: { !$0.allSatisfy(\.isWhitespace) })
        return oneLine(line.map(String.init), limit: limit)
    }
}
