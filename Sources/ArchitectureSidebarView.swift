import AppKit
import BreeFoundation
import SwiftUI
import WebKit

/// Toolbar plus diagram, Changes list or empty state. Used by the Architecture popup.
struct ArchitectureContentView: View {
    @ObservedObject var model: ArchitectureViewModel
    @Environment(\.breePalette) private var palette
    @Environment(\.breeAccentColor) private var breeAccent

    var body: some View {
        if model.isActive {
            VStack(spacing: 0) {
                if !(model.content == .empty && model.tab == .current) {
                    toolbar
                    Divider()
                }
                bodyContent
            }
        } else {
            Color.clear
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Picker("", selection: Binding(get: { model.tab }, set: { model.select($0) })) {
                Text(String(localized: "architecture.toolbar.current", defaultValue: "Current")).tag(ArchitectureTab.current)
                Text(String(localized: "architecture.toolbar.changes", defaultValue: "Changes")).tag(ArchitectureTab.changes)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .tint(breeAccent.selectedFillColor)
            Spacer(minLength: 0)
            iconButton(
                "arrow.clockwise",
                String(localized: "architecture.toolbar.reload", defaultValue: "Reload diagrams"),
                help: String(localized: "architecture.toolbar.reload.help",
                             defaultValue: "Reload the diagrams from disk. This does not regenerate them.")
            ) { model.refresh() }
            iconButton(
                "square.and.arrow.up",
                String(localized: "architecture.toolbar.export", defaultValue: "Export")
            ) { model.export() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    /// 28x28 hit area (the borderless style gave an 11x14 target).
    private func iconButton(_ symbol: String, _ title: String, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).accessibilityLabel(title) }
            .buttonStyle(BreeIconButtonStyle())
            .help(help ?? title)
            .accessibilityLabel(title)
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch model.content {
        case .empty:
            VStack(spacing: 6) {
                Text(String(
                    localized: "architecture.empty.title",
                    defaultValue: "No architecture diagram yet"
                ))
                .breeFont(.body, weight: .medium)
                .foregroundStyle(palette.textPrimary)
                Text(String(
                    localized: "architecture.empty.hint",
                    defaultValue: "Ask your agent: bree guide architecture"
                ))
                .breeFont(.secondary)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .web:
            ArchitectureWebView(model: model)
        case .changes:
            List(Array(model.changes.enumerated()), id: \.offset) { _, change in
                Button { model.openChange(change) } label: {
                    Text(change.rowText)
                        .foregroundStyle(change.rowColor(palette: palette))
                        .breeFont(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        case .message(let text):
            Text(text)
                .breeFont(.body)
                .foregroundStyle(.breeSecondaryText)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct ArchitectureWebView: NSViewRepresentable {
    let model: ArchitectureViewModel

    func makeNSView(context: Context) -> WKWebView { model.ensureWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

extension ArchitectureChange {
    func rowColor(palette: BreeChromePalette) -> Color {
        switch kind {
        case .added: return palette.signalSuccess
        case .removed: return palette.signalError
        case .changed: return palette.textSecondary
        }
    }

    var rowText: String {
        let symbol: String
        switch kind {
        case .added: symbol = "+"
        case .removed: symbol = "−"
        case .changed: symbol = "~"
        }
        let type = isEdge
            ? String(localized: "architecture.kind.edge", defaultValue: "Connection")
            : String(localized: "architecture.kind.node", defaultValue: "Node")
        var text = "\(symbol) \(type): \(label)"
        if let sourcePath { text += "  —  \(sourcePath)" + (line.map { ":\($0)" } ?? "") }
        return text
    }
}
