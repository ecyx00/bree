import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import SwiftUI

/// Routes key presses to the Attention list while the notifications popover
/// is open. The popover never becomes key (its host window stays key), so
/// SwiftUI key handlers would not see arrows, Return or Esc; a local monitor does.
@MainActor
final class AttentionKeyMonitor {
    var handler: ((NSEvent) -> Bool)?
    private var token: Any?

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let handler = self?.handler else { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .control, .option]
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).isDisjoint(with: blocked) else {
                return event
            }
            return handler(event) ? nil : event
        }
    }

    func stop() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
    }

    deinit {
        if let token { NSEvent.removeMonitor(token) }
    }
}

/// "While you were away": every agent pane that needs the user, ranked, with
/// the files that changed in workspaces the user left.
struct AttentionCenterView: View {
    @ObservedObject var store: AttentionStore
    /// Re-renders the list when notifications change (they feed the last-output line).
    let notificationRevision: Int
    let onDismiss: () -> Void

    @State private var selectedRowId: String?
    @State private var expandedWorkspaceIds: Set<UUID> = []
    @State private var lastOutputByPanel: [UUID: String] = [:]
    @State private var pendingToolByPanel: [UUID: AttentionPendingTool] = [:]
    @State private var showSnoozed = false
    @State private var keyMonitor = AttentionKeyMonitor()
    @Environment(\.breePalette) private var palette

    private enum Row: Identifiable {
        case item(AttentionItem)
        case file(AttentionItem, AttentionChangeLog.Entry)

        var id: String {
            switch self {
            case .item(let item): return item.id
            case .file(let item, let entry): return "\(item.id)|file|\(entry.path)"
            }
        }
    }

    var body: some View {
        // Reading the store here (not per row) keeps the rows value-only.
        let _ = notificationRevision
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let projection = makeProjection()
            let rows = projection.rows
            VStack(spacing: 0) {
            if rows.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                rowView(row, now: context.date)
                                    .id(row.id)
                            }
                        }
                    }
                    .onChange(of: selectedRowId) { _, id in
                        if let id { proxy.scrollTo(id) }
                    }
                }
            }
            if projection.snoozedCount > 0 {
                snoozedFooter(count: projection.snoozedCount)
            }
            }
        }
        .onAppear {
            keyMonitor.handler = { event in handleKey(event) }
            keyMonitor.start()
            if selectedRowId == nil { selectedRowId = makeRows().first?.id }
        }
        .onDisappear { keyMonitor.stop() }
        .background(palette.surfaceOverlay)
        .breeSurfaceColorScheme()
        .task {
            await loadLastOutput()
            await loadPendingTools()
        }
    }

    // MARK: - Rows

    private func makeRows() -> [Row] { makeProjection().rows }

    private func makeProjection() -> (rows: [Row], snoozedCount: Int) {
        var rows: [Row] = []
        let projection = store.projection(
            lastOutputByPanel: lastOutputByPanel,
            pendingToolByPanel: pendingToolByPanel,
            showSnoozed: showSnoozed
        )
        for item in projection.items {
            rows.append(.item(item))
            if expandedWorkspaceIds.contains(item.workspaceId), item.changedCount > 0 {
                for entry in store.changeLogs[item.workspaceId]?.entries ?? [] {
                    rows.append(.file(item, entry))
                }
            }
        }
        return (rows, projection.snoozedCount)
    }

    private func snoozedFooter(count: Int) -> some View {
        HStack(spacing: 6) {
            Text(String(
                format: String(localized: "attention.snooze.footer", defaultValue: "%lld snoozed"),
                Int64(count)
            ))
            Text(verbatim: "·")
            Button(showSnoozed
                ? String(localized: "attention.snooze.hide", defaultValue: "Hide")
                : String(localized: "attention.snooze.show", defaultValue: "Show")) {
                showSnoozed.toggle()
            }
            .buttonStyle(.plain)
            .foregroundColor(palette.textPrimary)
            .help(String(
                localized: "attention.snooze.help",
                defaultValue: "Snoozed for 10 minutes. Not kept after you quit Bree. A change of state wakes the row early."
            ))
            Spacer(minLength: 0)
        }
        .breeFont(.secondary)
        .foregroundColor(palette.textSecondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func rowView(_ row: Row, now: Date) -> some View {
        switch row {
        case .item(let item):
            AttentionRowView(
                item: item,
                nowMs: Int64(now.timeIntervalSince1970 * 1000),
                isSelected: selectedRowId == row.id,
                isExpanded: expandedWorkspaceIds.contains(item.workspaceId),
                isTruncated: store.changeLogs[item.workspaceId]?.isTruncated == true,
                onActivate: { jump(item) },
                onToggleExpanded: { toggleExpanded(item) },
                onSnoozeToggle: { toggleSnooze(item) }
            )
        case .file(let item, let entry):
            AttentionFileRowView(
                entry: entry,
                isSelected: selectedRowId == row.id,
                onActivate: { open(entry, in: item) }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            CmuxSystemSymbolImage(
                systemName: "checkmark.circle",
                pointSize: 30,
                weight: .light,
                tint: palette.textSecondary
            )
            Text(String(localized: "attention.empty", defaultValue: "Nothing needs you."))
                .breeFont(.body, weight: .medium)
                .foregroundColor(palette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Actions

    private func jump(_ item: AttentionItem) {
        DispatchQueue.main.async {
            _ = store.jump(to: item)
            onDismiss()
        }
    }

    private func toggleSnooze(_ item: AttentionItem) {
        if item.isSnoozed {
            store.unsnooze(id: item.id)
        } else {
            store.snooze(item)
        }
    }

    private func toggleExpanded(_ item: AttentionItem) {
        guard item.changedCount > 0 else { return }
        if expandedWorkspaceIds.contains(item.workspaceId) {
            expandedWorkspaceIds.remove(item.workspaceId)
        } else {
            expandedWorkspaceIds.insert(item.workspaceId)
        }
    }

    private func open(_ entry: AttentionChangeLog.Entry, in item: AttentionItem) {
        guard entry.kind != .deleted,
              let workspace = AppDelegate.shared?.tabManagerFor(tabId: item.workspaceId)?
                  .workspacesById[item.workspaceId] else {
            NSSound.beep()
            return
        }
        DispatchQueue.main.async {
            QuickViewResource.file(path: entry.path).open(from: workspace)
            onDismiss()
        }
    }

    /// Arrows move, Right/Left expand and collapse the changed files, Return
    /// jumps or opens, Delete dismisses a workspace's changed list, Esc closes.
    private func handleKey(_ event: NSEvent) -> Bool {
        // Safety net: never swallow terminal keys once the popover is gone.
        guard NotificationsPopoverVisibilityState.shared.isShown else {
            keyMonitor.stop()
            return false
        }
        let rows = makeRows()
        let index = rows.firstIndex { $0.id == selectedRowId }
        switch event.keyCode {
        case 125: // down
            guard !rows.isEmpty else { return true }
            selectedRowId = rows[min((index ?? -1) + 1, rows.count - 1)].id
        case 126: // up
            guard !rows.isEmpty else { return true }
            selectedRowId = rows[max((index ?? rows.count) - 1, 0)].id
        case 124: // right
            if let index, case .item(let item) = rows[index], !expandedWorkspaceIds.contains(item.workspaceId) {
                toggleExpanded(item)
            }
        case 123: // left
            if let index {
                switch rows[index] {
                case .item(let item):
                    expandedWorkspaceIds.remove(item.workspaceId)
                case .file(let item, _):
                    expandedWorkspaceIds.remove(item.workspaceId)
                    selectedRowId = item.id
                }
            }
        case 36, 76: // return
            if let index {
                switch rows[index] {
                case .item(let item): jump(item)
                case .file(let item, let entry): open(entry, in: item)
                }
            }
        case 51, 117: // delete, forward delete
            if let index {
                let item: AttentionItem
                switch rows[index] {
                case .item(let value): item = value
                case .file(let value, _): item = value
                }
                expandedWorkspaceIds.remove(item.workspaceId)
                selectedRowId = item.id
                store.dismissChanges(workspaceId: item.workspaceId)
            }
        case 53: // escape
            onDismiss()
        default:
            return false
        }
        return true
    }

    // MARK: - Last output

    /// Newest assistant message per surface from the Feed, joined through the
    /// hook-session store. Notifications already cover panes without Feed data.
    private func loadLastOutput() async {
        var latest: [String: String] = [:]
        for item in FeedCoordinator.shared.snapshot(pendingOnly: false) {
            if case .assistantMessage(let text) = item.payload { latest[item.workstreamId] = text }
        }
        guard !latest.isEmpty else { return }
        let targets = await FeedCoordinator.shared.resolveTargets(for: Array(latest.keys))
        var byPanel: [UUID: String] = [:]
        for (workstreamId, target) in targets {
            if let panelId = UUID(uuidString: target.surfaceId), let text = latest[workstreamId] {
                byPanel[panelId] = text
            }
        }
        if byPanel != lastOutputByPanel { lastOutputByPanel = byPanel }
    }
}

extension AttentionCenterView {
    /// Newest pending permission request per surface from the Feed, joined the
    /// same way as the last output. Only the in-app row reads it.
    fileprivate func loadPendingTools() async {
        var latest: [String: (date: Date, tool: AttentionPendingTool)] = [:]
        for item in FeedCoordinator.shared.snapshot(pendingOnly: true) {
            guard case .permissionRequest(_, let toolName, let toolInputJSON, _) = item.payload,
                  let tool = AttentionPendingTool.parse(toolName: toolName, toolInputJSON: toolInputJSON)
            else { continue }
            if let existing = latest[item.workstreamId], existing.date >= item.createdAt { continue }
            latest[item.workstreamId] = (item.createdAt, tool)
        }
        guard !latest.isEmpty else {
            if !pendingToolByPanel.isEmpty { pendingToolByPanel = [:] }
            return
        }
        let targets = await FeedCoordinator.shared.resolveTargets(for: Array(latest.keys))
        var byPanel: [UUID: AttentionPendingTool] = [:]
        for (workstreamId, target) in targets {
            if let panelId = UUID(uuidString: target.surfaceId), let entry = latest[workstreamId] {
                byPanel[panelId] = entry.tool
            }
        }
        if byPanel != pendingToolByPanel { pendingToolByPanel = byPanel }
    }
}

// MARK: - Row views

enum AttentionStyle {
    static func symbol(for state: AttentionState?, palette: BreeChromePalette) -> (name: String, tint: Color) {
        switch state {
        case .thermal: return ("thermometer.high", palette.signalError)
        case .running: return ("circle.fill", palette.signalInfo)
        case .needsInput: return ("circle.lefthalf.filled", palette.signalAttention)
        case .failed: return ("exclamationmark.circle.fill", palette.signalError)
        case .done: return ("checkmark.circle.fill", palette.signalSuccess)
        case nil: return ("pencil.circle.fill", palette.textSecondary)
        }
    }

    static func word(for state: AttentionState?, needsApproval: Bool = false) -> String? {
        switch state {
        case .thermal: return String(localized: "attention.state.thermal", defaultValue: "Running hot")
        case .running: return String(localized: "attention.state.running", defaultValue: "Running")
        case .needsInput:
            return needsApproval
                ? String(localized: "attention.state.needsApproval", defaultValue: "Needs approval")
                : String(localized: "attention.state.needsInput", defaultValue: "Needs input")
        case .failed: return String(localized: "attention.state.failed", defaultValue: "Failed")
        case .done: return String(localized: "attention.state.done", defaultValue: "Done")
        case nil: return nil
        }
    }

    static func changedText(_ count: Int) -> String {
        String(format: String(localized: "sidebar.pulse.changedAway", defaultValue: "%lld changed while away"), Int64(count))
    }
}

private struct AttentionRowView: View {
    let item: AttentionItem
    let nowMs: Int64
    let isSelected: Bool
    let isExpanded: Bool
    let isTruncated: Bool
    let onActivate: () -> Void
    let onToggleExpanded: () -> Void
    let onSnoozeToggle: () -> Void
    @State private var isHovering = false
    @Environment(\.breePalette) private var palette

    /// Selected rows sit on the quiet neutral `selectedFill`, so text keeps its normal tones.
    private var primaryText: Color { palette.textPrimary }
    private var secondaryText: Color { palette.textSecondary }

    private var snoozeTitle: String {
        item.isSnoozed
            ? String(localized: "attention.snooze.cancel", defaultValue: "Unsnooze")
            : String(localized: "attention.snooze.action", defaultValue: "Snooze 10 Minutes")
    }

    var body: some View {
        let symbol = AttentionStyle.symbol(for: item.state, palette: palette)
        HStack(alignment: .top, spacing: 8) {
            CmuxSystemSymbolImage(systemName: symbol.name, pointSize: 12, weight: .regular, tint: symbol.tint)
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.workspaceTitle)
                        .breeFont(.title)
                        .foregroundColor(primaryText)
                        .lineLimit(1)
                    if let detail = detailText {
                        Text(detail)
                            .breeFont(.secondary)
                            .foregroundColor(secondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(stateText)
                        .breeFont(.secondary, weight: .medium)
                        .foregroundColor(primaryText)
                        .lineLimit(1)
                }
                if let prompt = item.lastPrompt {
                    Text(prompt)
                        .breeFont(.secondary)
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }
                if let command = item.pendingCommand {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let risk = item.riskNote {
                    Text(risk)
                        .breeFont(.secondary, weight: .medium)
                        .foregroundColor(palette.signalAttention)
                        .lineLimit(1)
                }
                if let output = item.lastOutput {
                    Text(output)
                        .breeFont(.secondary)
                        .foregroundColor(secondaryText)
                        .lineLimit(1)
                }
            }
            if AttentionSnooze.canSnooze(item), isHovering || item.isSnoozed {
                Button(action: onSnoozeToggle) {
                    CmuxSystemSymbolImage(
                        systemName: item.isSnoozed ? "bell" : "bell.slash",
                        pointSize: 10,
                        weight: .regular,
                        tint: secondaryText
                    )
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.breeCompactIcon)
                .help(snoozeTitle)
                .accessibilityLabel(Text(snoozeTitle))
            }
            if item.changedCount > 0 {
                Button(action: onToggleExpanded) {
                    CmuxSystemSymbolImage(
                        systemName: isExpanded ? "chevron.down" : "chevron.right",
                        pointSize: 10,
                        weight: .regular,
                        tint: secondaryText
                    )
                    .frame(width: 20, height: 20)
                }
                .buttonStyle(.breeCompactIcon)
                .help(isExpanded
                    ? String(localized: "attention.changes.hide", defaultValue: "Hide changed files")
                    : String(localized: "attention.changes.show", defaultValue: "Show changed files"))
                .accessibilityLabel(Text(isExpanded
                    ? String(localized: "attention.changes.hide", defaultValue: "Hide changed files")
                    : String(localized: "attention.changes.show", defaultValue: "Show changed files")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(isSelected ? palette.selectedFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .onHover { isHovering = $0 }
        .contextMenu {
            if AttentionSnooze.canSnooze(item) {
                Button(snoozeTitle, action: onSnoozeToggle)
            }
        }
        .opacity(item.isSnoozed ? 0.55 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityHint(Text(String(localized: "attention.row.hint", defaultValue: "Jumps to this pane")))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onActivate)
    }

    /// Agent and pane, e.g. "Claude Code · zsh".
    private var detailText: String? {
        let parts = [item.agentName, item.paneTitle].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var stateText: String {
        var parts: [String] = []
        if let word = AttentionStyle.word(for: item.state, needsApproval: item.needsApproval) { parts.append(word) }
        if let since = item.sinceMs {
            parts.append(AttentionRanking.relativeLabel(sinceMs: since, nowMs: nowMs))
        }
        if item.changedCount > 0 {
            parts.append(AttentionStyle.changedText(item.changedCount) + (isTruncated ? "+" : ""))
        }
        return parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        [item.workspaceTitle, detailText, stateText, item.lastPrompt, item.pendingCommand, item.riskNote, item.lastOutput]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

private struct AttentionFileRowView: View {
    let entry: AttentionChangeLog.Entry
    let isSelected: Bool
    let onActivate: () -> Void
    @Environment(\.breePalette) private var palette

    /// Selected rows sit on the quiet neutral `selectedFill`, so text keeps its normal tones.
    private var primaryText: Color { palette.textPrimary }
    private var secondaryText: Color { palette.textSecondary }

    var body: some View {
        let url = URL(fileURLWithPath: entry.path)
        HStack(spacing: 8) {
            CmuxSystemSymbolImage(systemName: symbolName, pointSize: 11, weight: .regular, tint: secondaryText)
                .frame(width: 16, height: 16)
                .accessibilityHidden(true)
            Text(url.lastPathComponent)
                .breeFont(.secondary, weight: .medium)
                .foregroundColor(primaryText)
                .lineLimit(1)
            Text((url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath)
                .breeFont(.secondary)
                .foregroundColor(secondaryText)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 4)
            Text(kindText)
                .breeFont(.secondary)
                .foregroundColor(secondaryText)
        }
        .padding(.leading, 38)
        .padding(.trailing, 14)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .background(isSelected ? palette.selectedFill : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onActivate)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(url.lastPathComponent), \(kindText)"))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onActivate)
    }

    private var symbolName: String {
        switch entry.kind {
        case .created: return "plus.circle"
        case .modified: return "pencil.circle"
        case .deleted: return "minus.circle"
        }
    }

    private var kindText: String {
        switch entry.kind {
        case .created: return String(localized: "attention.change.created", defaultValue: "New")
        case .modified: return String(localized: "attention.change.modified", defaultValue: "Edited")
        case .deleted: return String(localized: "attention.change.deleted", defaultValue: "Deleted")
        }
    }
}
