import AppKit
import CmuxFoundation
import SwiftUI

/// Remembers which absolute paths exist so line text can link them. The check runs off the main
/// thread; results are cached for the app's lifetime (bounded).
@MainActor
final class ModPathExistence: ObservableObject {
    static let shared = ModPathExistence()
    @Published private(set) var known: [String: Bool] = [:]
    private var inflight: Set<String> = []

    func resolve(_ paths: [String]) async {
        let todo = Set(paths).filter { known[$0] == nil && !inflight.contains($0) }
        guard !todo.isEmpty else { return }
        inflight.formUnion(todo)
        let result = await Task.detached(priority: .utility) { ModLinkDetector.existing(Array(todo)) }.value
        inflight.subtract(todo)
        if known.count > 2000 { known = [:] }
        known.merge(result) { _, new in new }
    }
}

/// Small plain text button: caption text, hairline capsule border that brightens on hover, 20 pt hit area.
struct ModTextButton: View {
    @Environment(\.breePalette) private var palette
    let title: String
    let disabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .breeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(minHeight: 20)
                .overlay(Capsule().strokeBorder(hovering && !disabled ? palette.borderStrong : palette.separator, lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
    }
}

/// Two-way All / Warnings switch in palette colours (the system segmented control paints
/// the selection in the system accent blue).
struct ModFilterSwitch: View {
    @Environment(\.breePalette) private var palette
    @Binding var warningsOnly: Bool
    let allTitle: String
    let warningsTitle: String
    let label: String

    var body: some View {
        HStack(spacing: 2) {
            segment(allTitle, selected: !warningsOnly) { warningsOnly = false }
            segment(warningsTitle, selected: warningsOnly) { warningsOnly = true }
        }
        .padding(2)
        .background(Capsule().fill(palette.selectedQuiet))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .breeFont(.caption, weight: selected ? .medium : nil)
                .foregroundStyle(selected ? palette.textPrimary : palette.textSecondary)
                .padding(.horizontal, 8)
                .frame(minHeight: 18)
                .background(Capsule().fill(selected ? palette.selectedFill : Color.clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Left-to-right wrapping layout, capped at `maxRows` rows (the rest is clipped away).
struct ModFlowLayout: Layout {
    var maxRows: Int
    var spacing: CGFloat = 0

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect?]) {
        var frames: [CGRect?] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, row = 0, maxX: CGFloat = 0
        for sub in subviews {
            var size = sub.sizeThatFits(ProposedViewSize(width: width.isFinite ? width : nil, height: nil))
            if width.isFinite { size.width = min(size.width, width) }
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight
                rowHeight = 0
                row += 1
            }
            if row >= maxRows { frames.append(nil); continue }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), frames)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews)
        for (sub, frame) in zip(subviews, result.frames) {
            if let frame {
                sub.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
            } else {
                sub.place(at: CGPoint(x: -100_000, y: -100_000), proposal: ProposedViewSize(width: 0, height: 0))
            }
        }
    }
}

private struct ModLinkToken: View {
    let text: String
    let color: Color
    let link: ModLink
    let open: (ModLink) -> Void
    @State private var hovering = false

    var body: some View {
        Text(text)
            .underline(hovering)
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.middle)
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture { open(link) }
    }
}

/// One mod line: coloured parts, with absolute paths that exist and http(s) URLs clickable
/// (underlined only on hover).
struct ModLineText: View {
    let line: ModLine
    let live: Bool
    let lineLimit: Int
    let color: (String?) -> Color
    let existing: [String: Bool]
    let open: (ModLink) -> Void

    private struct Token {
        let text: String
        let color: Color
        let link: ModLink?
    }

    private var pieces: [(text: String, kind: String?)] {
        (line.parts ?? [ModLinePart(text: line.text, kind: nil)]).map { ($0.text, $0.kind ?? line.kind) }
    }

    private var candidates: [String] {
        pieces.flatMap { ModLinkDetector.segments(in: $0.text).compactMap { $0.link?.pathCandidate } }
    }

    private func isLive(_ link: ModLink?) -> Bool {
        switch link {
        case .url?: return true
        case .path(let path, _, _)?: return existing[path] == true
        case nil: return false
        }
    }

    private func tokens() -> [Token] {
        var out: [Token] = []
        for piece in pieces {
            let tint = color(piece.kind)
            for segment in ModLinkDetector.segments(in: piece.text) {
                if isLive(segment.link) {
                    out.append(Token(text: segment.text, color: tint, link: segment.link))
                } else {
                    out += Self.words(segment.text).map { Token(text: $0, color: tint, link: nil) }
                }
            }
        }
        return out
    }

    /// Words with their trailing whitespace, so the flow layout can wrap between them.
    static func words(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var sawSpace = false
        for ch in text {
            if sawSpace, !ch.isWhitespace {
                result.append(current)
                current = ""
                sawSpace = false
            }
            current.append(ch)
            if ch.isWhitespace { sawSpace = true }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        let toks = tokens()
        Group {
            if toks.contains(where: { $0.link != nil }) {
                ModFlowLayout(maxRows: lineLimit) {
                    ForEach(Array(toks.enumerated()), id: \.offset) { _, token in
                        if let link = token.link {
                            ModLinkToken(text: token.text, color: token.color, link: link, open: open)
                        } else {
                            Text(token.text).foregroundStyle(token.color).lineLimit(1)
                        }
                    }
                }
                .clipped()
            } else {
                pieces.reduce(Text("")) { $0 + Text($1.text).foregroundColor(color($1.kind)) }
                    .lineLimit(lineLimit)
            }
        }
        .modifier(ModLineFont(live: live))
        .task(id: line.text) { await ModPathExistence.shared.resolve(candidates) }
    }
}

private struct ModLineFont: ViewModifier {
    let live: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if live {
            content.breeFont(.secondary)
        } else {
            content.font(.system(size: 10, design: .monospaced))
        }
    }
}
