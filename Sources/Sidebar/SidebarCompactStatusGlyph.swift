import AppKit
import CmuxFoundation
import Foundation

/// The single leading glyph a workspace row shows when
/// `sidebar.compactAgentStatus` is on, modeled on the Claude desktop session
/// list: glyph then title on one line, with the details in the glyph's
/// tooltip.
///
/// Compact mode folds in the lines cmux generates on your behalf: the
/// agent-owned status entries (agent hooks report their lifecycle as keyed
/// entries, `set_status claude_code Running --icon=bolt.fill`), the
/// branch/directory line, the notification preview,
/// the unread count badge and the loading spinner. It also holds the title to
/// one line, so title wrapping does not undo it.
///
/// Lines you asked for yourself stay where they are: the workspace
/// description, your own `cmux set-status` keys, logs, progress, ports, the
/// checklist, and a remote workspace's connection row with its Reconnect
/// button. Those carry text and controls a user chose to put there, so
/// compact mode does not hide them; `set-status` under your own key stays the
/// way to keep a line in compact mode.
///
/// Precedence, loudest first:
/// 1. Error (an agent reported a failure): red warning triangle. Only for
///    something that broke.
/// 2. Needs input: amber dot.
/// 3. Running through subagents: pulsing gray connected-points symbol. The
///    agent is working, but through background agents it spawned.
/// 4. Waiting on a deterministic wakeup (a background command, a scheduled
///    wakeup, a CI run): gray hourglass. Not your turn, and not finished. A
///    waiting pane still reports a *running* lifecycle (it must not look
///    hibernatable), so waiting is read off the reported work state and wins
///    over the running branch below, but only when every running agent in the
///    workspace is covered by a waiting report.
/// 5. Running: pulsing gray dot. It replaces the row's loading spinner.
/// 6. Starting (agent present, state not reported yet): hollow ring.
/// 7. Unseen (unread notifications): blue dot. Applied by the row, which owns
///    the unread count; see ``applyingUnread(_:latestNotificationText:)``. It
///    outranks "starting", which asks for nothing.
/// 8. Agent idle (done and seen): gray checkmark.
/// 9. Branch: gray branch.
/// 10. Otherwise, a plain terminal: nothing, so the title starts at the
///    row's edge (a `terminal` entry in `sidebar.compactStatusIcons` adds one).
/// Only the three agent states Claude marks with dots (needs input, unseen,
/// running) are dots; everything settled gets a symbol that says what it is.
struct SidebarCompactStatusGlyph: Equatable, Hashable {
    enum Kind: Equatable, Hashable {
        case error
        case needsInput
        case subagents
        case running
        case waiting
        case pending
        case unseen
        case idle
        case branch
        case terminal
    }

    let kind: Kind
    /// One line per fact: agent statuses, branch, directory.
    let tooltip: String
    /// `sidebar.compactStatusIcons`: SF Symbol names by ``IconSlot`` raw value.
    var iconOverrides: [String: String] = [:]

    /// The customizable states; raw values are the `sidebar.compactStatusIcons`
    /// keys in cmux.json.
    enum IconSlot: String, CaseIterable {
        case error
        case needsInput
        case subagents
        case running
        case waiting
        case starting
        case unseen
        case idle
        case branch
        case terminal
    }

    var iconSlot: IconSlot {
        switch kind {
        case .error: return .error
        case .needsInput: return .needsInput
        case .subagents: return .subagents
        case .running: return .running
        case .waiting: return .waiting
        case .pending: return .starting
        case .unseen: return .unseen
        case .idle: return .idle
        case .branch: return .branch
        case .terminal: return .terminal
        }
    }

    /// Keeps entries whose key names a state and whose symbol name is not blank.
    static func validIconOverrides(_ raw: [String: String]) -> [String: String] {
        var valid: [String: String] = [:]
        for (key, value) in raw where IconSlot(rawValue: key) != nil {
            let symbol = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !symbol.isEmpty { valid[key] = symbol }
        }
        return valid
    }

    /// The configured symbol for this state, or nil for the built-in one.
    var customSymbolName: String? {
        iconOverrides[iconSlot.rawValue]
    }

    /// The symbol drawn: the configured one, else the built-in default.
    var symbolName: String {
        customSymbolName ?? defaultSymbolName
    }

    /// The same glyph with this state's configured symbol dropped, so a name
    /// that no SF Symbols version resolves falls back to the built-in glyph
    /// exactly as an unconfigured one draws: at the built-in ``sizeScale``.
    /// Without this a bad symbol on a dot state drew the dot at full size.
    var droppingCustomSymbol: SidebarCompactStatusGlyph {
        guard customSymbolName != nil else { return self }
        var fallback = self
        fallback.iconOverrides.removeValue(forKey: iconSlot.rawValue)
        return fallback
    }

    var defaultSymbolName: String {
        switch kind {
        case .error: return "exclamationmark.triangle.fill"
        case .pending: return "circle.dashed"
        case .subagents: return "point.3.filled.connected.trianglepath.dotted"
        case .waiting: return "hourglass"
        // Attention states get their own shapes (not the running dot), so the
        // signal never relies on colour alone.
        case .needsInput: return "questionmark.circle.fill"
        case .unseen: return "bell.fill"
        case .running: return "circle.fill"
        case .idle: return "checkmark.circle"
        case .branch: return "arrow.triangle.branch"
        case .terminal: return "terminal"
        }
    }

    /// How far the glyph sits into the row's leading padding, and its gap to
    /// the title; both engines use these.
    static let leadingPullIn: CGFloat = 4
    static let titleSpacing: CGFloat = 5

    /// The built-in dots draw smaller than symbols so they read as status,
    /// not icons. A symbol configured through `sidebar.compactStatusIcons`
    /// draws full size, like every other configured symbol.
    var sizeScale: CGFloat {
        guard customSymbolName == nil else { return 1 }
        switch kind {
        case .running: return 0.6
        default: return 1
        }
    }

    /// Needs input and unread: the theme's attention signal (thread-safe snapshot).
    static var needsInputColor: NSColor {
        BreeChromePalette.currentSnapshot.ns.signalAttention
    }

    /// A plain terminal or a bare branch draws nothing unless an icon is
    /// configured for it (the branch is already spelled out on line 2).
    var isDrawn: Bool {
        (kind != .terminal && kind != .branch) || customSymbolName != nil
    }

    /// Whether the glyph pulses (the running indicators). Waiting does not:
    /// the agent is parked, and a pulsing hourglass would claim otherwise.
    var pulses: Bool { kind == .running || kind == .subagents }

    /// Unread notifications turn a settled row blue; agent activity and
    /// errors stay louder. The latest notification leads the tooltip, since
    /// compact rows hide the notification preview line and the count badge.
    func applyingUnread(_ unreadCount: Int, latestNotificationText: String?) -> SidebarCompactStatusGlyph {
        guard unreadCount > 0 else { return self }
        let text = latestNotificationText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreadTooltip = [text, tooltip]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: "\n")
        switch kind {
        // "Starting" is not an attention state, so unread outranks it; that
        // also keeps unread visible on a group header, which only rolls up
        // states that ask for attention.
        case .idle, .branch, .terminal, .pending:
            return SidebarCompactStatusGlyph(kind: .unseen, tooltip: unreadTooltip, iconOverrides: iconOverrides)
        case .error, .needsInput, .subagents, .running, .waiting, .unseen:
            return SidebarCompactStatusGlyph(kind: kind, tooltip: unreadTooltip, iconOverrides: iconOverrides)
        }
    }

    /// A workspace a group header stands in for: its title and glyph.
    struct GroupMember: Equatable, Hashable {
        let title: String
        let glyph: SidebarCompactStatusGlyph
    }

    /// How loud a state is on a group header, or nil when it does
    /// not surface there. Only states that ask for attention roll up; a
    /// settled idle agent, branch or terminal stays inside.
    private var groupRank: Int? {
        switch kind {
        case .error: return 0
        case .needsInput: return 1
        case .subagents: return 2
        case .running: return 3
        case .waiting: return 4
        case .unseen: return 5
        case .pending, .idle, .branch, .terminal: return nil
        }
    }

    /// The loudest of the members' glyphs, for a group header. The tooltip
    /// names every member asking for attention, loudest first. Nil when no
    /// member needs attention.
    static func rollUp(_ members: [GroupMember]) -> SidebarCompactStatusGlyph? {
        let ranked = members.compactMap { member in
            member.glyph.groupRank.map { (rank: $0, member: member) }
        }
        // Stable: members keep sidebar order within one rank.
        let sorted = ranked.enumerated()
            .sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }
            .map(\.element.member)
        guard let loudest = sorted.first else { return nil }
        let tooltip = sorted.map { member in
            let detail = member.glyph.tooltip.split(separator: "\n").first.map(String.init)
            return detail.map { line(member.title, $0) } ?? member.title
        }.joined(separator: "\n")
        return SidebarCompactStatusGlyph(kind: loudest.glyph.kind, tooltip: tooltip, iconOverrides: loudest.glyph.iconOverrides)
    }

    /// The glyph for a group header, which stands in for the workspaces
    /// without rows of their own: the anchor while the group is expanded, and
    /// every member once it is collapsed. `members` holds each workspace's
    /// glyph before unread, keyed by workspace id; `unread` gives its count
    /// and latest notification text.
    static func groupHeader(
        isCollapsed: Bool,
        anchorId: UUID?,
        memberIds: [UUID],
        members: [UUID: GroupMember],
        unread: (UUID) -> (count: Int, latestText: String?)
    ) -> SidebarCompactStatusGlyph? {
        let ids = isCollapsed ? memberIds : (anchorId.map { [$0] } ?? [])
        return rollUp(ids.compactMap { id in
            guard let member = members[id] else { return nil }
            let unread = unread(id)
            return GroupMember(
                title: member.title,
                glyph: member.glyph.applyingUnread(unread.count, latestNotificationText: unread.latestText)
            )
        })
    }

    private static let tooltipFormat = String(
        localized: "sidebar.agentStatus.glyph.tooltip",
        defaultValue: "%1$@: %2$@"
    )

    static func line(_ name: String, _ value: String) -> String {
        String(format: tooltipFormat, locale: .current, name, value)
    }

    /// Selected rows flatten the glyph to the selected foreground, like the
    /// metadata rows do, so colors never vanish into the selection fill.
    func color(isActive: Bool, selected: NSColor, secondary: NSColor) -> NSColor {
        if isActive { return selected }
        switch kind {
        case .error: return BreeChromePalette.currentSnapshot.ns.signalError
        case .needsInput, .unseen: return Self.needsInputColor
        case .subagents, .running, .waiting, .pending, .idle, .branch, .terminal:
            return secondary
        }
    }
}
