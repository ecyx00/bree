import CmuxCommandPalette
import CmuxFoundation
import Observation
import SwiftUI

enum CommandPaletteRenderTrailingLabelStyle: Equatable {
    case shortcut
    case kind
}

struct CommandPaletteRenderTrailingLabel: Equatable {
    let text: String
    let style: CommandPaletteRenderTrailingLabelStyle
}

struct CommandPaletteRenderResultRow: Identifiable, Equatable {
    let id: String
    let title: String
    let matchedIndices: Set<Int>
    let trailingLabel: CommandPaletteRenderTrailingLabel?
    /// Quiet header drawn above this row when it starts a category group.
    /// Display only: headers are not rows, so selection never lands on one.
    var sectionTitle: String? = nil
}

/// Result-row fill. Selection wins over hover, and hover stays quieter than
/// selection so the pointer row never reads as the keyboard selection (white
/// at 8% was about as bright as the accent at 12% in dark mode).
enum CommandPaletteRowHighlight: Equatable {
    case selected
    case hovered
    case plain

    init(isSelected: Bool, isHovered: Bool) {
        if isSelected {
            self = .selected
        } else if isHovered {
            self = .hovered
        } else {
            self = .plain
        }
    }

    var backgroundOpacity: Double {
        switch self {
        case .selected: return 0.12
        case .hovered: return 0.04
        case .plain: return 0
        }
    }

    /// Palette fills: the row label keeps the primary text colour, so selection
    /// uses the quiet fill rather than the white-text `selectedFill`.
    func backgroundColor(palette: BreeChromePalette) -> Color {
        switch self {
        case .selected: return palette.selectedQuiet
        case .hovered: return palette.hoverFill
        case .plain: return .clear
        }
    }
}

struct CommandPaletteCommandListRenderState: Equatable {
    var resultsVersion: UInt64 = 0
    var emptyStateText: String = ""
    var listIdentity: String = "switcher"
    var rows: [CommandPaletteRenderResultRow] = []
    var selectedIndex: Int = 0
    var shouldShowEmptyState = false
    var scrollTargetID: String?
    var scrollTargetAnchor: UnitPoint?

    static let empty = CommandPaletteCommandListRenderState()
}

@MainActor
@Observable
final class CommandPaletteOverlayRenderModel {
    private(set) var commandList = CommandPaletteCommandListRenderState.empty
    @ObservationIgnored private var scheduledCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListSequence: UInt64 = 0
    @ObservationIgnored private var appliedCommandListResultsVersion: UInt64 = 0

    deinit {}

    func scheduleCommandListUpdate(_ state: CommandPaletteCommandListRenderState) {
        scheduledCommandListSequence &+= 1
        let sequence = scheduledCommandListSequence

        Task { @MainActor in
            await Task.yield()
            guard sequence >= appliedCommandListSequence else { return }
            guard state.resultsVersion >= appliedCommandListResultsVersion else { return }
            appliedCommandListSequence = sequence
            appliedCommandListResultsVersion = max(appliedCommandListResultsVersion, state.resultsVersion)
            updateCommandList(state)
        }
    }

    private func updateCommandList(_ state: CommandPaletteCommandListRenderState) {
        guard commandList != state else { return }
        commandList = state
    }
}

struct CommandPaletteCommandListRenderView: View {
    let renderModel: CommandPaletteOverlayRenderModel
    let onRunResult: (String) -> Void

    var body: some View {
        CommandPaletteCommandListRowsView(
            state: renderModel.commandList,
            onRunResult: onRunResult
        )
    }
}

struct CommandPaletteCommandListRowsView: View {
    @Environment(\.breePalette) private var palette
    let state: CommandPaletteCommandListRenderState
    let onRunResult: (String) -> Void
    @State private var hoveredIndex: Int?

    private static let listMaxHeight: CGFloat = 450
    private static let rowHeight: CGFloat = 24
    private static let headerHeight: CGFloat = 22
    private static let emptyStateHeight: CGFloat = 44

    var body: some View {
        let headerCount = state.rows.filter { $0.sectionTitle != nil }.count
        let contentHeight = state.rows.isEmpty
            ? Self.emptyStateHeight
            : CGFloat(state.rows.count) * Self.rowHeight + CGFloat(headerCount) * Self.headerHeight
        let listHeight = min(Self.listMaxHeight, contentHeight)

        ScrollView {
            LazyVStack(spacing: 0) {
                if state.rows.isEmpty {
                    if state.shouldShowEmptyState {
                        Text(state.emptyStateText)
                            .breeFont(.body)
                            .foregroundStyle(palette.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 12)
                    } else {
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: Self.emptyStateHeight)
                    }
                } else {
                    ForEach(Array(state.rows.enumerated()), id: \.element.id) { index, row in
                        let rowBackground = CommandPaletteRowHighlight(
                            isSelected: index == state.selectedIndex,
                            isHovered: hoveredIndex == index
                        ).backgroundColor(palette: palette)

                        VStack(spacing: 0) {
                        if let sectionTitle = row.sectionTitle {
                            Text(sectionTitle)
                                .breeFont(.caption, weight: .medium)
                                .foregroundStyle(palette.textSecondary)
                                .frame(maxWidth: .infinity, minHeight: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.horizontal, 9)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                        }

                        Button {
                            onRunResult(row.id)
                        } label: {
                            ContentView.commandPaletteRenderResultLabelContent(
                                title: row.title,
                                matchedIndices: row.matchedIndices,
                                trailingLabel: row.trailingLabel
                            )
                            .padding(.horizontal, 9)
                            .padding(.vertical, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowBackground)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        // The command id lives in the identifier (not the spoken value)
                        // so UI tests can find rows without VoiceOver reading internal ids.
                        .accessibilityIdentifier("CommandPaletteResultRow.\(index).\(row.id)")
                        .onHover { hovering in
                            if hovering {
                                hoveredIndex = index
                            } else if hoveredIndex == index {
                                hoveredIndex = nil
                            }
                        }
                        }
                    }
                }
            }
            .scrollTargetLayout()
        }
        .id(state.listIdentity)
        .frame(height: listHeight)
        .scrollPosition(
            id: Binding(
                get: { state.scrollTargetID },
                // Ignore passive readback so manual scrolling doesn't mutate selection-follow state.
                set: { _ in }
            ),
            anchor: state.scrollTargetAnchor
        )
        .onChange(of: state.rows.count) { _, count in
            if let hoveredIndex, hoveredIndex >= count {
                self.hoveredIndex = nil
            }
        }
    }
}

extension CommandPaletteCategory {
    /// Header text for the grouped empty-query list.
    var localizedTitle: String {
        switch self {
        case .workspace: return String(localized: "commandPalette.category.workspace", defaultValue: "Workspace")
        case .pane: return String(localized: "commandPalette.category.pane", defaultValue: "Pane")
        case .agent: return String(localized: "commandPalette.category.agent", defaultValue: "Agent")
        case .view: return String(localized: "commandPalette.category.view", defaultValue: "View")
        case .learn: return String(localized: "commandPalette.category.learn", defaultValue: "Learn")
        case .app: return String(localized: "commandPalette.category.app", defaultValue: "App")
        }
    }
}
