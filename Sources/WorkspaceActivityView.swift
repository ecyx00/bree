import AppKit
import BreeFoundation
import SwiftUI

/// Right sidebar "Activity" mode: Artifact Shelf on top, Mods (live sections and stream written by the journal mod) below, both for the active workspace.
struct WorkspaceActivityView: View {
    @Environment(\.breePalette) private var palette
    @ObservedObject var store: WorkspaceActivityStore
    @ObservedObject private var lens = AgentLensStore.shared
    @ObservedObject private var commentPool = DiffCommentSubmissionPool.shared
    let tabManager: TabManager
    let workspaceId: UUID?
    /// Pins a file as a tab in the workspace (same closure the Files mode uses).
    let onPin: (String) -> Void

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    @State private var mods = ActivityModsSnapshot()
    @State private var warningsOnly = false
    @State private var hidden = Set(UserDefaults.standard.stringArray(forKey: ModFilterRules.hiddenDefaultsKey) ?? [])
    @State private var pending: PendingPress?
    @State private var lastPress: PendingPress?
    @State private var notice: PressNotice?
    @State private var nowMs = Date().timeIntervalSince1970 * 1000
    @ObservedObject private var pathCache = ModPathExistence.shared

    private struct PendingPress: Equatable {
        let id: String
        let sessionId: String
        let ownerId: String
        let consumer: String
    }

    private struct PressNotice: Equatable {
        let ownerId: String
        let text: String
    }

    private var workspace: Workspace? { workspaceId.flatMap { id in tabManager.tabs.first { $0.id == id } } }

    var body: some View {
        let activity = workspaceId.map(store.activity(for:)) ?? WorkspaceActivity()
        let root = workspace?.currentDirectory ?? ""
        let sessionIds = workspaceId.map { id in lens.cards.filter { $0.workspaceID == id }.map(\.statusSessionIDs) } ?? []
        let artifacts = workspaceId.map {
            WorkspaceActivityRules.claudeEditedFiles(cards: lens.cards, ended: lens.endedSessions[$0] ?? [], workspaceId: $0, dismissed: activity.dismissed)
        } ?? []
        VStack(spacing: 0) {
            sectionHeader(String(localized: "activity.shelf.title", defaultValue: "Edited by Claude"))
            if artifacts.isEmpty {
                emptyText(String(localized: "activity.shelf.empty", defaultValue: "Files Claude edits in this session appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(artifacts) { artifact in artifactRow(artifact, root: root) }
                    }
                }
                .frame(maxHeight: 240)
            }
            Divider()
            modsHeader
            let turns = workspaceId.map(store.turnRecords(for:)) ?? []
            modsSection
            if let workspaceId, let latest = turns.first,
               let surfaceId = UUID(uuidString: latest.surfaceId),
               commentPool.pendingCount(workspaceId: workspaceId) > 0 {
                sendCommentsButton(workspaceId: workspaceId, surfaceId: surfaceId)
            }
            Spacer(minLength: 0)
        }
        .task(id: workspaceId) {
            guard let workspaceId else { return }
            await store.reloadTurnRecords()
        }
        // Polls only while the view is on screen (the task is cancelled on disappear); the file reads
        // run detached, off the main actor.
        .task(id: workspaceId) {
            // Looking at Mods clears the sidebar attention dot and keeps it clear while visible.
            guard let id = workspaceId else { return }
            ModAttentionStore.shared.start()
            ModAttentionStore.shared.setVisible(id, true)
            defer { ModAttentionStore.shared.setVisible(id, false) }
            try? await Task.sleep(nanoseconds: UInt64.max / 2)
        }
        .task(id: ModsSource(sessionIds: sessionIds, cwd: root)) {
            let source = ModsSource(sessionIds: sessionIds, cwd: root)
            while !Task.isCancelled {
                let snapshot = await Task.detached(priority: .utility) {
                    ActivityModsStream.load(sessionIds: ActivityModsStream.newestIds(source.sessionIds), cwd: source.cwd)
                }.value
                if snapshot != mods { mods = snapshot }
                nowMs = Date().timeIntervalSince1970 * 1000
                if notice != nil, let last = lastPress, snapshot.answers.values.contains(where: { $0.id == last.id }) { notice = nil }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .accessibilityIdentifier("RightSidebarActivity")
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .breeFont(.secondary, weight: .semibold)
            .foregroundStyle(.breeSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .breeFont(.secondary)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
    }

    private func artifactRow(_ artifact: WorkspaceArtifact, root: String) -> some View {
        let dir = (artifact.path as NSString).deletingLastPathComponent
        let relativeDir = dir == root ? "." : dir.hasPrefix(root + "/") ? String(dir.dropFirst(root.count + 1)) : (dir as NSString).abbreviatingWithTildeInPath
        return HStack(spacing: 8) {
            Image(systemName: WorkspaceActivityRules.symbolName(forPath: artifact.path))
                .frame(width: 16)
                .foregroundStyle(.breeSecondaryText)
            VStack(alignment: .leading, spacing: 1) {
                Text((artifact.path as NSString).lastPathComponent).breeFont(.body).lineLimit(1)
                Text(relativeDir).breeFont(.caption).foregroundStyle(.breeSecondaryText).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 4)
            Text(Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: artifact.at), relativeTo: Date()))
                .breeFont(.caption)
                .foregroundStyle(.breeSecondaryText)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Double click first so the single-click handler does not swallow it.
        .onTapGesture(count: 2) { onPin(artifact.path) }
        .onTapGesture { openInQuickView(artifact.path) }
        .contextMenu {
            Button(String(localized: "fileExplorer.contextMenu.revealInFinder", defaultValue: "Reveal in Finder")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: artifact.path)])
            }
            Button(String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(artifact.path, forType: .string)
            }
            Button(String(localized: "activity.shelf.remove", defaultValue: "Remove from Shelf")) {
                if let workspaceId { store.removeArtifact(path: artifact.path, workspaceId: workspaceId) }
            }
        }
    }

    private struct ModsSource: Hashable {
        let sessionIds: [[String]]
        let cwd: String
    }

    private var modsHeader: some View {
        HStack(spacing: 8) {
            Text(String(localized: "activity.mods.title", defaultValue: "Plugin status"))
                .breeFont(.secondary, weight: .semibold)
                .foregroundStyle(.breeSecondaryText)
            Spacer(minLength: 4)
            ModFilterSwitch(
                warningsOnly: $warningsOnly,
                allTitle: String(localized: "activity.mods.filter.all", defaultValue: "All"),
                warningsTitle: String(localized: "activity.mods.filter.warnings", defaultValue: "Warnings"),
                label: String(localized: "activity.mods.filter.label", defaultValue: "Filter plugin output")
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var modsSection: some View {
        let view = ModFilterRules.apply(mods, warningsOnly: warningsOnly, hidden: hidden)
        let placed = footnotes(for: view)
        let footnotes = placed.byOwner
        if view.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                emptyText(String(localized: "activity.mods.empty", defaultValue: "No plugin status yet"))
                emptyText(String(localized: "activity.mods.empty.hint", defaultValue: "Start a Claude session here; your plugins report in this list."))
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(placed.orphans.enumerated()), id: \.offset) { _, note in orphanLine(note) }
                    ForEach(Array(view.live.enumerated()), id: \.offset) { _, section in liveRow(section, footnotes: footnotes) }
                    if !view.live.isEmpty && !view.rows.isEmpty { Divider().padding(.vertical, 4) }
                    ForEach(view.rows) { row in streamRow(row, footnotes: footnotes) }
                }
            }
        }
        if !hidden.isEmpty {
            HStack(spacing: 6) {
                Text(String(format: String(localized: "activity.mods.hiddenFooter", defaultValue: "Hidden: %@"), ModFilterRules.hiddenList(hidden)))
                    .breeFont(.caption)
                    .foregroundStyle(palette.textSecondary.opacity(0.8))
                    .lineLimit(1)
                Spacer(minLength: 4)
                modTextButton(String(localized: "activity.mods.showAll", defaultValue: "Show all"), disabled: false) { setHidden([]) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private func setHidden(_ value: Set<String>) {
        hidden = value
        UserDefaults.standard.set(value.sorted(), forKey: ModFilterRules.hiddenDefaultsKey)
    }

    private func modColor(_ kind: String?) -> Color {
        switch kind {
        case "warn": return palette.signalAttention
        case "error": return palette.signalError
        default: return palette.textSecondary
        }
    }

    /// Live rows show non-coloured kinds in the primary text colour.
    private func liveColor(_ kind: String?) -> Color {
        kind == nil || kind == "dim" || kind == "ok" || kind == "info" ? palette.textPrimary : modColor(kind)
    }

    private func footnotes(for view: ActivityModsSnapshot) -> (byOwner: [String: ModAnswerRules.Footnote], orphans: [ModAnswerRules.Footnote]) {
        var notes: [ModAnswerRules.Footnote] = []
        for (sessionId, answer) in view.answers {
            let local = lastPress?.id == answer.id
            let owner = local
                ? lastPress?.ownerId
                : ModAnswerRules.ownerId(answer: answer, sessionId: sessionId, live: view.live, rows: view.rows)
            notes.append(ModAnswerRules.Footnote(
                ownerId: owner, title: local ? (lastPress?.consumer ?? answer.command) : answer.command,
                text: answer.text, failed: answer.failed, at: answer.at))
        }
        if let notice {
            notes.append(ModAnswerRules.Footnote(
                ownerId: notice.ownerId, title: lastPress?.consumer ?? "", text: notice.text, failed: true, at: nil))
        }
        // Notice goes last so it wins the owner slot, as before.
        let rendered = Set(view.live.map(ModAnswerRules.liveId) + view.rows.map(\.id))
        return ModAnswerRules.placeFootnotes(notes, renderedOwners: rendered, nowMs: nowMs)
    }

    private func orphanLine(_ note: ModAnswerRules.Footnote) -> some View {
        Text(note.title.isEmpty ? note.text : "\(note.title) · \(note.text)")
            .breeFont(.caption)
            .foregroundStyle(note.failed ? palette.signalError : palette.textSecondary.opacity(0.8))
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
    }

    private func hideMenu(_ consumer: String) -> some View {
        Button(String(format: String(localized: "activity.mods.hide", defaultValue: "Hide %@"), consumer)) {
            setHidden(hidden.union([consumer]))
        }
    }

    private func lineText(_ line: ModLine, live: Bool, lineLimit: Int) -> some View {
        ModLineText(
            line: line, live: live, lineLimit: lineLimit,
            color: live ? liveColor : modColor,
            existing: pathCache.known,
            open: openLink)
    }

    @ViewBuilder
    private func footer(ownerId: String, buttons: [ModButton], consumer: String, key: String, sessionId: String, footnotes: [String: ModAnswerRules.Footnote]) -> some View {
        if !buttons.isEmpty {
            ModFlowLayout(maxRows: 3, spacing: 6) {
                ForEach(Array(buttons.enumerated()), id: \.offset) { _, button in
                    modTextButton(button.label, disabled: pending != nil || sessionId.isEmpty) {
                        press(button, consumer: consumer, key: key, sessionId: sessionId, ownerId: ownerId)
                    }
                }
            }
            .padding(.top, 2)
        }
        if let note = footnotes[ownerId] {
            Text(note.text)
                .breeFont(.caption)
                .foregroundStyle(note.failed ? palette.signalError : palette.textSecondary.opacity(0.8))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func modTextButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        ModTextButton(title: title, disabled: disabled, action: action)
    }

    private func liveRow(_ section: ModLiveSection, footnotes: [String: ModAnswerRules.Footnote]) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(section.consumer)
                    .breeFont(.mono)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                if let line = section.lines.first {
                    lineText(line, live: true, lineLimit: 1)
                }
                Spacer(minLength: 0)
            }
            footer(ownerId: ModAnswerRules.liveId(section), buttons: section.buttons, consumer: section.consumer,
                   key: section.key, sessionId: section.sessionId, footnotes: footnotes)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .contextMenu { hideMenu(section.consumer) }
    }

    private func streamRow(_ row: ModStreamRow, footnotes: [String: ModAnswerRules.Footnote]) -> some View {
        let entry = row.entry
        let age = Self.relativeFormatter.localizedString(for: Date(timeIntervalSince1970: entry.at / 1000), relativeTo: Date())
        return VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(entry.consumer)
                    .breeFont(.mono)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                if entry.showsTitle {
                    Text(entry.title)
                        .breeFont(.secondary)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                }
                if row.count > 1 {
                    Text("×\(row.count)")
                        .breeFont(.mono)
                        .foregroundStyle(palette.textSecondary)
                }
                Spacer(minLength: 4)
                Text(age)
                    .breeFont(.caption)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
            }
            ForEach(Array(entry.lines.enumerated()), id: \.offset) { _, line in
                lineText(line, live: false, lineLimit: 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer(ownerId: row.id, buttons: entry.buttons, consumer: entry.consumer,
                   key: entry.key, sessionId: entry.sessionId, footnotes: footnotes)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .contextMenu { hideMenu(entry.consumer) }
    }

    // MARK: Actions

    private func openLink(_ link: ModLink) {
        switch link {
        case .path(let path, let line, let column):
            guard let workspace else { return }
            QuickViewResource.file(path: path, line: line, column: column).open(from: workspace)
        case .url(let raw):
            TerminalLinkOpenCoordinator().open(TerminalLinkOpenRequest(
                rawValue: raw, sourceWorkspaceId: workspaceId, sourcePanelId: nil,
                workingDirectory: workspace?.currentDirectory))
        }
    }

    /// Writes press.json for the session, then waits up to 5 s for the matching `answer`.
    private func press(_ button: ModButton, consumer: String, key: String, sessionId: String, ownerId: String) {
        guard pending == nil, !sessionId.isEmpty else { return }
        let press = ModPress(
            id: UUID().uuidString, consumer: consumer, key: key, label: button.label,
            at: Date().timeIntervalSince1970 * 1000)
        let ref = PendingPress(id: press.id, sessionId: sessionId, ownerId: ownerId, consumer: consumer)
        pending = ref
        lastPress = ref
        notice = nil
        Task { @MainActor in
            let written = await Task.detached(priority: .userInitiated) {
                ModPress.write(press, sessionId: sessionId)
            }.value
#if DEBUG
            breeDebugLog("mods.press written=\(written) id=\(press.id.prefix(8)) consumer=\(consumer) label=\(button.label)")
#endif
            let deadline = Date().addingTimeInterval(ModAnswerRules.timeoutSeconds)
            while written, Date() < deadline {
                let answer = await Task.detached(priority: .userInitiated) {
                    ModPress.readAnswer(sessionId: sessionId)
                }.value
                if let answer, answer.id == press.id {
                    mods.answers[sessionId] = answer
                    pending = nil
#if DEBUG
                    breeDebugLog("mods.answer received id=\(press.id.prefix(8)) failed=\(answer.failed)")
#endif
                    return
                }
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
            notice = PressNotice(
                ownerId: ownerId,
                text: String(localized: "activity.mods.noAnswer", defaultValue: "No answer. Is the Claude session still running?"))
            pending = nil
#if DEBUG
            breeDebugLog("mods.answer timeout id=\(press.id.prefix(8)) consumer=\(consumer) label=\(button.label)")
#endif
        }
    }

    private func sendCommentsButton(workspaceId: UUID, surfaceId: UUID) -> some View {
        let count = commentPool.pendingCount(workspaceId: workspaceId)
        return Button {
            AgentTurnReview.sendPendingComments(workspaceId: workspaceId, surfaceId: surfaceId, tabManager: tabManager)
        } label: {
            Text(String(
                format: String(localized: "activity.turn.sendCommentsCount", defaultValue: "Send %lld comments to agent"),
                count))
                .breeFont(.secondary)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .accessibilityIdentifier("ActivitySendCommentsToAgent")
    }

    private func openInQuickView(_ path: String) {
        guard let workspace else { return }
        QuickViewResource.file(path: path).open(from: workspace)
    }
}
