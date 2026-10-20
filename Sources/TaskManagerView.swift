import BreeAppKitSupportUI
import BreeFoundation
import Observation
import SwiftUI

/// Shared chrome tokens for the Task Manager (warm surface, hairline, text).
@MainActor private var tmPalette: BreeChromePalette { BreeChromePaletteStore.shared.palette }

private struct TaskManagerHairline: View {
    var body: some View {
        Rectangle().fill(tmPalette.separator).frame(height: 1)
    }
}

struct BreeTaskManagerView: View {
    @Bindable var model: BreeTaskManagerModel

    var body: some View {
        // Outer view observes the model so the toolbar/summary/sort
        // header repaint on snapshot or sort changes. The lazy list
        // subtree is intentionally isolated below this boundary: it
        // receives value-typed snapshots and a closure action bundle so
        // row body re-evaluation can't be triggered by orthogonal model
        // mutations. See repo/CLAUDE.md "Snapshot boundary for list
        // subtrees" rule and issues #2586 / #4529.
        VStack(spacing: 0) {
            toolbar
            TaskManagerHairline()
            summary
            TaskManagerHairline()
            tableHeader
            TaskManagerHairline()
            BreeTaskManagerListView(
                errorMessage: model.errorMessage,
                isInitialLoading: model.isInitialLoading,
                rows: model.sortedRows,
                agentRows: model.sortedAgentRows,
                aggregateRows: model.sortedAggregateRows,
                childMemoryRows: model.sortedChildMemoryRows,
                actions: BreeTaskManagerRowActions.bound(to: model)
            )
        }
        .frame(minWidth: 820, minHeight: 480)
        .background(Color(nsColor: GhosttyApp.shared.defaultBackgroundColor))
        .onAppear {
            model.start()
        }
        .onDisappear {
            model.stop()
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(String(localized: "taskManager.title", defaultValue: "Task Manager"))
                .scaledFont(.title3, weight: .semibold)

            if model.isRefreshing || model.isInitialLoading {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(String(localized: "taskManager.refreshing", defaultValue: "Refreshing"))
            }

            Spacer()

            Toggle(
                String(localized: "taskManager.groupByWorktree", defaultValue: "Group by worktree"),
                isOn: $model.groupsByWorktree
            )
            .toggleStyle(.checkbox)

            Toggle(
                String(localized: "taskManager.showProcesses", defaultValue: "Processes"),
                isOn: $model.includesProcesses
            )
            .toggleStyle(.checkbox)

            Button {
                model.refresh(force: true)
            } label: {
                Label(String(localized: "taskManager.refresh", defaultValue: "Refresh"), systemImage: "arrow.clockwise")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var summary: some View {
        HStack(spacing: 24) {
            metric(
                title: String(localized: "taskManager.summary.cpu", defaultValue: "CPU"),
                value: BreeTaskManagerFormat.cpu(model.snapshot.total.cpuPercent)
            )
            metric(
                title: String(localized: "taskManager.summary.memory", defaultValue: "Memory"),
                value: BreeTaskManagerFormat.bytes(model.snapshot.total.memoryBytes)
            )
            if let memoryDiagnostic = model.snapshot.memoryDiagnostic {
                metric(
                    title: String(localized: "taskManager.summary.appFootprint", defaultValue: "App Footprint"),
                    value: BreeTaskManagerFormat.bytes(memoryDiagnostic.appFootprintBytes)
                )
                metric(
                    title: String(localized: "taskManager.summary.childRSS", defaultValue: "Child RSS"),
                    value: BreeTaskManagerFormat.bytes(memoryDiagnostic.childRSSBytes)
                )
            }
            metric(
                title: String(localized: "taskManager.summary.processes", defaultValue: "Processes"),
                value: "\(model.snapshot.total.processCount)"
            )
            metric(
                title: String(localized: "taskManager.summary.updated", defaultValue: "Updated"),
                value: model.snapshot.updatedText
            )
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func metric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .scaledFont(.caption)
                .foregroundStyle(tmPalette.textSecondary)
            Text(value)
                .scaledFont(.body, weight: .semibold, design: .monospaced)
                .monospacedDigit()
        }
    }

    private var tableHeader: some View {
        HStack(spacing: 8) {
            sortHeader(
                title: String(localized: "taskManager.column.name", defaultValue: "Name"),
                column: .name,
                maxWidth: .infinity,
                alignment: .leading
            )
            sortHeader(
                title: String(localized: "taskManager.column.cpu", defaultValue: "CPU"),
                column: .cpu,
                width: 82,
                alignment: .trailing
            )
            sortHeader(
                title: String(localized: "taskManager.column.memory", defaultValue: "Memory"),
                column: .memory,
                width: 96,
                alignment: .trailing
            )
            sortHeader(
                title: String(localized: "taskManager.column.processes", defaultValue: "Proc"),
                column: .processes,
                width: 70,
                alignment: .trailing
            )
        }
        .scaledFont(size: 11, weight: .semibold)
        .foregroundStyle(tmPalette.textSecondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func sortHeader(
        title: String,
        column: BreeTaskManagerSortOrder.Column,
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        alignment: Alignment
    ) -> some View {
        Button {
            model.sort(by: column)
        } label: {
            HStack(spacing: 3) {
                Text(title)
                    .lineLimit(1)
                sortIndicator(for: column)
            }
            .frame(maxWidth: .infinity, alignment: alignment)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.sortOrder.column == column ? tmPalette.textPrimary : tmPalette.textSecondary)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: maxWidth, alignment: alignment)
        .accessibilityLabel(title)
    }

    private func sortIndicator(for column: BreeTaskManagerSortOrder.Column) -> some View {
        let isActive = model.sortOrder.column == column
        let imageName = model.sortOrder.direction == .ascending ? "chevron.up" : "chevron.down"
        return BreeSystemSymbolImage(magnified: imageName, pointSize: 8, weight: .bold, tint: isActive ? .primary : .secondary)
            .opacity(isActive ? 1 : 0)
            .frame(width: 8)
            .accessibilityHidden(true)
    }
}

/// Closure bundle handed down to row views so they never reference the
/// `@Observable` `BreeTaskManagerModel`. Matches the
/// `IndexSectionActions` / `SectionGapActions` reference pattern in
/// `Sources/SessionIndexView.swift`. See repo/CLAUDE.md
/// "Snapshot boundary for list subtrees" rule and issues #2586 / #4529.
struct BreeTaskManagerRowActions {
    let viewWorkspace: @MainActor (BreeTaskManagerRow) -> Void
    let viewTerminal: @MainActor (BreeTaskManagerRow) -> Void
    let killProcess: @MainActor (BreeTaskManagerRow) -> Void
    let activate: @MainActor (BreeTaskManagerRow) -> Void

    @MainActor
    static func bound(to model: BreeTaskManagerModel) -> BreeTaskManagerRowActions {
        BreeTaskManagerRowActions(
            viewWorkspace: { row in model.viewWorkspace(for: row) },
            viewTerminal: { row in model.viewTerminal(for: row) },
            killProcess: { row in model.killProcess(for: row) },
            activate: { row in model.viewBestTarget(for: row) }
        )
    }
}

/// Lazy list subtree. Receives value-typed row arrays plus a closure
/// action bundle so SwiftUI can prove rows never observe the
/// `BreeTaskManagerModel`. Combined with the `Equatable` conformance on
/// `BreeTaskManagerRowView`, this stops the 3 s refresh timer from
/// invalidating every row on every tick.
struct BreeTaskManagerListView: View {
    let errorMessage: String?
    let isInitialLoading: Bool
    let rows: [BreeTaskManagerRow]
    let agentRows: [BreeTaskManagerRow]
    let aggregateRows: [BreeTaskManagerRow]
    let childMemoryRows: [BreeTaskManagerRow]
    let actions: BreeTaskManagerRowActions

    var body: some View {
        if let errorMessage {
            BreeTaskManagerMessageView(
                title: String(localized: "taskManager.error.title", defaultValue: "Unable to load resource usage"),
                detail: errorMessage
            )
        } else if isInitialLoading {
            BreeTaskManagerLoadingView()
        } else if rows.isEmpty && agentRows.isEmpty && aggregateRows.isEmpty && childMemoryRows.isEmpty {
            BreeTaskManagerMessageView(
                title: String(localized: "taskManager.empty.title", defaultValue: "No resource usage"),
                detail: String(localized: "taskManager.empty.detail", defaultValue: "Open a workspace, terminal, or browser surface to see it here.")
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !agentRows.isEmpty {
                        BreeTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.codingAgents", defaultValue: "Coding Agents")
                        ).equatable()
                        ForEach(agentRows) { row in
                            BreeTaskManagerRowView(
                                row: row,
                                onViewWorkspace: {},
                                onViewTerminal: {},
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: {}
                            ).equatable()
                            TaskManagerHairline()
                                .padding(.leading, 16)
                        }
                    }
                    if !aggregateRows.isEmpty {
                        BreeTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.programTotals", defaultValue: "Program Totals")
                        ).equatable()
                        ForEach(aggregateRows) { row in
                            BreeTaskManagerRowView(
                                row: row,
                                onViewWorkspace: {},
                                onViewTerminal: {},
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: {}
                            ).equatable()
                            TaskManagerHairline()
                                .padding(.leading, 16)
                        }
                    }
                    if !childMemoryRows.isEmpty {
                        BreeTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.childProcessRSS", defaultValue: "Child Process RSS")
                        ).equatable()
                        ForEach(childMemoryRows) { row in
                            BreeTaskManagerRowView(
                                row: row,
                                onViewWorkspace: { actions.viewWorkspace(row) },
                                onViewTerminal: { actions.viewTerminal(row) },
                                onKillProcess: { actions.killProcess(row) },
                                onActivate: { actions.activate(row) }
                            ).equatable()
                            TaskManagerHairline()
                                .padding(.leading, 16)
                        }
                    }
                    if !rows.isEmpty && (!agentRows.isEmpty || !aggregateRows.isEmpty || !childMemoryRows.isEmpty) {
                        BreeTaskManagerSectionHeaderView(
                            title: String(localized: "taskManager.section.hierarchy", defaultValue: "Hierarchy")
                        ).equatable()
                    }
                    ForEach(rows) { row in
                        BreeTaskManagerRowView(
                            row: row,
                            onViewWorkspace: { actions.viewWorkspace(row) },
                            onViewTerminal: { actions.viewTerminal(row) },
                            onKillProcess: { actions.killProcess(row) },
                            onActivate: { actions.activate(row) }
                        ).equatable()
                        TaskManagerHairline()
                            .padding(.leading, 16)
                    }
                }
            }
        }
    }
}

private struct BreeTaskManagerSectionHeaderView: View, Equatable {
    let title: String

    static func == (lhs: BreeTaskManagerSectionHeaderView, rhs: BreeTaskManagerSectionHeaderView) -> Bool {
        lhs.title == rhs.title
    }

    var body: some View {
        Text(title)
            .scaledFont(size: 11, weight: .semibold)
            .foregroundStyle(tmPalette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

private struct BreeTaskManagerLoadingView: View {
    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
                .accessibilityLabel(String(localized: "taskManager.loading.title", defaultValue: "Loading resource usage"))
            Text(String(localized: "taskManager.loading.title", defaultValue: "Loading resource usage"))
                .scaledFont(.headline)
                .foregroundStyle(tmPalette.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

private struct BreeTaskManagerMessageView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Text(title)
                .scaledFont(.headline)
            Text(detail)
                .scaledFont(.callout)
                .foregroundStyle(tmPalette.textSecondary)
                .multilineTextAlignment(.center)
                .copyOnlyTextSelection(for: detail)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}

/// Row view rendered inside the lazy list subtree. Conforms to
/// `Equatable` so SwiftUI can skip body re-evaluation when the `row`
/// snapshot is unchanged, even if the parent rebuilt the closure
/// bundle on a refresh tick. Closures are intentionally excluded from
/// `==`; they're expected to be stable in semantics (capture the same
/// model above the snapshot boundary) but their identity changes every
/// render. Comparing closure identity would defeat the optimization
/// and re-introduce the 0.64.8 memory leak (issue #4529).
struct BreeTaskManagerRowView: View, Equatable {
    let row: BreeTaskManagerRow
    let onViewWorkspace: @MainActor () -> Void
    let onViewTerminal: @MainActor () -> Void
    let onKillProcess: @MainActor () -> Void
    let onActivate: @MainActor () -> Void

    static func == (lhs: BreeTaskManagerRowView, rhs: BreeTaskManagerRowView) -> Bool {
        // Closures excluded on purpose: the parent rebuilds the action
        // bundle on every render tick, but the row payload is what
        // actually drives visible state. Comparing closure identity
        // would defeat `.equatable()` at the ForEach call site and
        // re-introduce the 0.64.8 memory leak.
        lhs.row == rhs.row
    }

    var body: some View {
        Group {
            if row.canViewWorkspace || row.canViewTerminal {
                Button(action: onActivate) {
                    rowContent
                }
                .buttonStyle(.plain)
            } else {
                rowContent
            }
        }
        .contextMenu {
            if row.canViewWorkspace {
                Button {
                    onViewWorkspace()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewWorkspace", defaultValue: "View Workspace"),
                        systemImage: "rectangle.stack"
                    )
                }
            }
            if row.canViewTerminal {
                Button {
                    onViewTerminal()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.viewTerminal", defaultValue: "View Terminal"),
                        systemImage: "terminal"
                    )
                }
            }
            if row.canKillProcess {
                if row.canViewWorkspace || row.canViewTerminal {
                    TaskManagerHairline()
                }
                Button {
                    onKillProcess()
                } label: {
                    Label(
                        String(localized: "taskManager.contextMenu.killProcess", defaultValue: "Kill Process..."),
                        systemImage: "xmark.octagon"
                    )
                }
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Color.clear
                    .frame(width: CGFloat(row.level) * 14)
                rowIcon
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(row.title)
                            .scaledFont(size: 12.5)
                            .lineLimit(1)
                        if let processClass = row.processClass {
                            classBadge(processClass)
                        }
                    }
                    if !row.detail.isEmpty {
                        Text(row.detail)
                            .scaledFont(size: 11)
                            .foregroundStyle(tmPalette.textSecondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(BreeTaskManagerFormat.cpu(row.resources.cpuPercent))
                .frame(width: 82, alignment: .trailing)
            Text(BreeTaskManagerFormat.bytes(row.resources.memoryBytes))
                .frame(width: 96, alignment: .trailing)
            Text("\(row.resources.processCount)")
                .frame(width: 70, alignment: .trailing)
        }
        .scaledFont(size: 12.5, design: .default)
        .monospacedDigit()
        .padding(.horizontal, 16)
        .padding(.vertical, 3)
        .opacity(row.isDimmed ? 0.68 : 1)
        .contentShape(Rectangle())
    }

    private func classBadge(_ processClass: BreeTaskManagerRow.ProcessClass) -> some View {
        let palette = BreeChromePalette.currentSnapshot
        let isLeaked = processClass == .leaked
        return Text(processClass.label)
            .scaledFont(size: 10)
            .foregroundStyle(isLeaked ? palette.accentFill : palette.textSecondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(Capsule().stroke(isLeaked ? palette.accentFill : palette.textSecondary.opacity(0.5), lineWidth: 0.5))
            .help(isLeaked ? String(
                localized: "taskManager.leaked.hint",
                defaultValue: "Hint: its Bree surface is gone or it was orphaned inside a worktree. Not killed automatically."
            ) : "")
    }

    @ViewBuilder
    private var rowIcon: some View {
        if let agentAssetName = row.agentAssetName {
            BreeResolvedIconImage(request: BreeResolvedIconRequest(
                source: .asset(name: agentAssetName, bundle: .main),
                size: NSSize(width: 14, height: 14)
            ))
            .frame(width: 14, height: 14)
        } else {
            BreeSystemSymbolImage(magnified: row.kind.systemImage, pointSize: 12, tint: row.kind.tint)
                .frame(width: 14)
        }
    }
}
