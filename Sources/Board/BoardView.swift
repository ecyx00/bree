import AppKit
import BreeFoundation
import SwiftUI

/// Lanes top to bottom: Needs you, Running, Error, Done. Color only where the palette says so
/// (yellow = needs you, red = error, green check = done); Running is a spinner. Every state
/// also carries a word.
struct BoardView: View {
    @ObservedObject var model: BoardModel
    @Environment(\.breePalette) private var palette

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            let nowMs = Int64(context.date.timeIntervalSince1970 * 1000)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(BoardCard.Lane.allCases, id: \.self) { lane in
                        laneView(lane, nowMs: nowMs)
                    }
                }
                .padding(.vertical, 12)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { model.contentHeight = $0 }
            }
        }
        .background(palette.surfaceOverlay)
        .breeSurfaceColorScheme()
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.downArrow) { move(1); return .handled }
        .onKeyPress(.upArrow) { move(-1); return .handled }
        .onKeyPress(.return) {
            guard let card = model.cards.first(where: { $0.id == model.selectedId }) else { return .ignored }
            activate(card)
            return .handled
        }
    }

    // MARK: - Lanes

    @ViewBuilder
    private func laneView(_ lane: BoardCard.Lane, nowMs: Int64) -> some View {
        let cards = model.lane(lane)
        // An empty Error lane is hidden: no failures is the calm state.
        if !(lane == .error && cards.isEmpty) {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(Self.laneTitle(lane))
                    .breeFont(.title)
                    .foregroundColor(palette.textPrimary)
                Text("\(cards.count)")
                    .breeFont(.count)
                    .foregroundColor(palette.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if cards.isEmpty {
                Text(String(localized: "board.lane.empty", defaultValue: "Nothing here"))
                    .breeFont(.secondary)
                    .foregroundColor(palette.glyphTertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
            } else {
                ForEach(cards) { card in
                    BoardCardRow(
                        card: card,
                        nowMs: nowMs,
                        isSelected: model.selectedId == card.id,
                        onSelect: { model.selectedId = card.id },
                        onActivate: { activate(card) }
                    )
                }
            }
        }
        }
    }

    static func laneTitle(_ lane: BoardCard.Lane) -> String {
        switch lane {
        case .needsYou: return String(localized: "board.lane.needsYou", defaultValue: "Needs you")
        case .running: return String(localized: "board.lane.running", defaultValue: "Running")
        case .error: return String(localized: "board.lane.error", defaultValue: "Error")
        case .done: return String(localized: "board.lane.done", defaultValue: "Done")
        }
    }

    // MARK: - Actions

    private func move(_ delta: Int) {
        let ids = model.cards.map(\.id)
        guard !ids.isEmpty else { return }
        let index = model.selectedId.flatMap(ids.firstIndex(of:))
        model.selectedId = ids[min(max((index ?? (delta > 0 ? -1 : ids.count)) + delta, 0), ids.count - 1)]
    }

    /// Bree card: focus its pane. Outside cards are read-only.
    private func activate(_ card: BoardCard) {
        guard case .bree = card.source else { return }
        model.close?()
        model.focus(card)
    }
}

private struct BoardCardRow: View {
    let card: BoardCard
    let nowMs: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onActivate: () -> Void
    @State private var isHovering = false
    @Environment(\.breePalette) private var palette

    private var isOutside: Bool {
        if case .outside = card.source { return true }
        return false
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            glyph
                .frame(width: 16, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.name)
                        .breeFont(.body, weight: .medium)
                        .foregroundColor(palette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(stateText)
                        .breeFont(.secondary, weight: .medium)
                        .foregroundColor(palette.textPrimary)
                        .lineLimit(1)
                }
                Text(metaText)
                    .breeFont(.secondary)
                    .foregroundColor(palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = card.detail {
                    Text(detail)
                        .breeFont(.secondary)
                        .foregroundColor(palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let risk = card.riskNote {
                    (Text(Image(systemName: "exclamationmark.triangle.fill")) + Text(" " + risk))
                        .breeFont(.secondary, weight: .medium)
                        .foregroundColor(palette.signalError)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? palette.selectedFill : (isHovering ? palette.hoverFill : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? palette.selectedBorder : Color.clear, lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            // A click on a Bree card shows its pane. Outside cards are read-only.
            if !isOutside { onActivate() }
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            if !isOutside {
                Button(String(localized: "board.action.focus", defaultValue: "Show in Window"), action: onActivate)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityText))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, onActivate)
    }

    @ViewBuilder
    private var glyph: some View {
        switch card.lane {
        case .running:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        case .needsYou:
            BreeSystemSymbolImage(systemName: "circle.lefthalf.filled", pointSize: 12, weight: .regular, tint: palette.signalAttention)
        case .error:
            BreeSystemSymbolImage(systemName: "exclamationmark.circle.fill", pointSize: 12, weight: .regular, tint: palette.signalError)
        case .done:
            BreeSystemSymbolImage(systemName: "checkmark.circle.fill", pointSize: 12, weight: .regular, tint: palette.signalSuccess)
        }
    }

    private var stateText: String {
        card.stateWord + " · " + AttentionRanking.relativeLabel(sinceMs: card.sinceMs, nowMs: nowMs)
    }

    /// "Projects/bree · Claude Code · Bree pane"
    private var metaText: String {
        let source = isOutside
            ? String(localized: "board.source.outside", defaultValue: "Outside Bree")
            : String(localized: "board.source.bree", defaultValue: "Bree pane")
        return [card.project, card.agentKind, source].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var accessibilityText: String {
        [card.name, stateText, metaText, card.detail, card.riskNote].compactMap { $0 }.joined(separator: ", ")
    }
}
