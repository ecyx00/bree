import AppKit
import BreeFoundation
import SwiftUI
import WebKit

/// Content of an ``ArtifactPanel`` in the Quick View window.
struct ArtifactPanelView: View {
    @ObservedObject var panel: ArtifactPanel
    let appearance: PanelAppearance

    var body: some View {
        if panel.showSource, let source = panel.sourcePanel {
            FilePreviewPanelView(
                panel: source, isFocused: true, isVisibleInUI: true, portalPriority: 1,
                appearance: appearance, onRequestPanelFocus: {}
            )
        } else {
            rendered
                .task { panel.load() }
        }
    }

    @ViewBuilder
    private var rendered: some View {
        switch panel.kind {
        case .html:
            ArtifactHTMLContainer(panel: panel)
        case .csv:
            if let table = panel.table {
                VStack(spacing: 0) {
                    ArtifactTableView(result: table)
                    if table.truncated { ArtifactTruncationFooter() }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .jsonl:
            if let records = panel.records {
                ArtifactJSONLView(result: records)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .folder:
            ArtifactImageGridView(panel: panel)
        }
    }
}

struct ArtifactTruncationFooter: View {
    var body: some View {
        Text(String(
            format: String(localized: "artifact.table.truncated", defaultValue: "Showing first %@ rows"),
            ArtifactViewLimits.maxRows.formatted()
        ))
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
}

// MARK: - Toolbar items

/// 28x28 titlebar icon button with an accessibility label and a "Name (shortcut)" help tag.
struct QuickViewIconButton: View {
    let systemName: String
    let label: String
    var shortcut: String?
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
        }
        .buttonStyle(.breeIcon)
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .help(shortcut.map { "\(label) (\($0))" } ?? label)
    }
}

/// Rendered/Source toggle plus the grid zoom buttons for artifact panels.
struct ArtifactToolbarItems: View {
    @ObservedObject var panel: ArtifactPanel

    var body: some View {
        if panel.supportsSourceToggle {
            QuickViewIconButton(
                systemName: panel.showSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right",
                label: panel.showSource
                    ? String(localized: "quickView.showRendered", defaultValue: "Show Rendered")
                    : String(localized: "quickView.showSource", defaultValue: "Show Source"),
                shortcut: "Cmd+U",
                action: panel.toggleSource
            )
        }
        if panel.kind == .folder {
            QuickViewIconButton(
                systemName: "minus.magnifyingglass",
                label: String(localized: "artifact.grid.smaller", defaultValue: "Smaller Thumbnails"),
                shortcut: "Cmd+-", isDisabled: !panel.canZoomOut
            ) { panel.zoom(by: -1) }
            QuickViewIconButton(
                systemName: "plus.magnifyingglass",
                label: String(localized: "artifact.grid.larger", defaultValue: "Larger Thumbnails"),
                shortcut: "Cmd++", isDisabled: !panel.canZoomIn
            ) { panel.zoom(by: 1) }
        }
    }
}

/// Preview/Source toggle for Markdown (same Cmd+U shortcut as artifact panels).
struct MarkdownSourceToggleButton: View {
    @ObservedObject var panel: MarkdownPanel

    var body: some View {
        let isPreview = panel.displayMode == .preview
        QuickViewIconButton(
            systemName: isPreview ? "chevron.left.forwardslash.chevron.right" : "doc.richtext",
            label: isPreview
                ? String(localized: "quickView.showSource", defaultValue: "Show Source")
                : String(localized: "quickView.showRendered", defaultValue: "Show Rendered"),
            shortcut: "Cmd+U",
            action: { panel.setDisplayMode(isPreview ? .text : .preview) }
        )
    }
}

// MARK: - HTML

private struct ArtifactHTMLContainer: View {
    @ObservedObject var panel: ArtifactPanel

    var body: some View {
        ArtifactHTMLView(panel: panel)
            .overlay(alignment: .topTrailing) {
                if panel.remoteContentBlocked && !panel.allowsRemoteContent {
                    HStack(spacing: 8) {
                        Text(String(localized: "artifact.html.remoteBlocked", defaultValue: "Remote content blocked"))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Button(String(localized: "artifact.html.loadRemote", defaultValue: "Load Remote Content")) {
                            panel.allowsRemoteContent = true
                        }
                        .controlSize(.small)
                        .frame(minHeight: 28)
                    }
                    .padding(.horizontal, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(8)
                }
            }
    }
}

/// Renders a local HTML file. Remote http(s) subresources are blocked with a content rule list
/// until the user clicks "Load Remote Content".
private struct ArtifactHTMLView: NSViewRepresentable {
    @ObservedObject var panel: ArtifactPanel

    func makeCoordinator() -> Coordinator { Coordinator(panel: panel) }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.start()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.applyRemotePolicy()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllContentRuleLists()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let panel: ArtifactPanel
        weak var webView: WKWebView?
        private var remoteAllowed = false

        private static let ruleListJSON = """
        [
          {"trigger": {"url-filter": "^https?://"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^wss?://"}, "action": {"type": "block"}},
          {"trigger": {"url-filter": "^ftp://"}, "action": {"type": "block"}}
        ]
        """

        init(panel: ArtifactPanel) { self.panel = panel }

        /// Compiles the block list, then loads. If compiling fails the page is NOT loaded (fail closed).
        func start() {
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "BreeArtifactBlockRemote",
                encodedContentRuleList: Self.ruleListJSON
            ) { [weak self] list, _ in
                MainActor.assumeIsolated {
                    guard let self, let webView = self.webView, let list else { return }
                    webView.configuration.userContentController.add(list)
                    self.load()
                }
            }
        }

        private func load() {
            let url = URL(fileURLWithPath: panel.path)
            webView?.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func applyRemotePolicy() {
            guard panel.allowsRemoteContent, !remoteAllowed, let webView else { return }
            remoteAllowed = true
            webView.configuration.userContentController.removeAllContentRuleLists()
            webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else { return .allow }
            guard navigationAction.navigationType == .linkActivated else {
                // Script-driven top-level navigation to a remote URL must never replace the local page.
                let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
                if isMainFrame, let scheme = url.scheme?.lowercased(), ["http", "https", "ws", "wss", "ftp"].contains(scheme) {
                    return .cancel
                }
                return .allow
            }
            if url.isFileURL {
                if url.standardizedFileURL.path == URL(fileURLWithPath: panel.path).standardizedFileURL.path { return .allow }
                if !QuickViewWindowController.openLink(url.path, fromPanelId: panel.id) { NSWorkspace.shared.open(url) }
            } else if let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }

        /// WKContentRuleList cannot report what it blocked, so look for remote subresource URLs in the DOM.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !remoteAllowed else { return }
            let script = #"""
            (function () {
              var els = document.querySelectorAll('[src],link[rel~=stylesheet][href],[style*="url("]');
              for (var i = 0; i < els.length; i++) {
                var e = els[i];
                var u = e.currentSrc || e.src || e.href || '';
                if (typeof u === 'string' && /^https?:/i.test(u)) return true;
                if (/url\(\s*['"]?https?:/i.test(e.getAttribute('style') || '')) return true;
              }
              return false;
            })()
            """#
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                MainActor.assumeIsolated { self?.panel.remoteContentBlocked = (result as? Bool) ?? false }
            }
        }
    }
}

// MARK: - CSV table

private struct ArtifactTableView: NSViewRepresentable {
    let result: ArtifactCSVParser.Result
    private static let maxColumns = 200

    func makeCoordinator() -> Coordinator { Coordinator(rows: result.rows) }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.rowHeight = 20
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let sample = result.rows.prefix(100)
        for (index, title) in result.header.prefix(Self.maxColumns).enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = title
            column.minWidth = 40
            let longest = sample.reduce(title.count) { max($0, index < $1.count ? $1[index].count : 0) }
            column.width = CGFloat(min(max(longest * 7 + 16, 60), 360))
            column.sortDescriptorPrototype = NSSortDescriptor(key: "c\(index)", ascending: true)
            table.addTableColumn(column)
        }
        context.coordinator.table = table
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let rows: [[String]]
        private var order: [Int]
        weak var table: NSTableView?

        init(rows: [[String]]) {
            self.rows = rows
            self.order = Array(rows.indices)
        }

        func numberOfRows(in tableView: NSTableView) -> Int { order.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue.dropFirst()) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
                let field = NSTextField(labelWithString: "")
                field.identifier = identifier
                field.lineBreakMode = .byTruncatingTail
                field.font = .systemFont(ofSize: 12)
                return field
            }()
            let record = rows[order[row]]
            field.stringValue = column < record.count ? record[column] : ""
            return field
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key,
                  let column = Int(key.dropFirst()) else {
                order = Array(rows.indices)
                tableView.reloadData()
                return
            }
            let rows = rows
            func value(_ index: Int) -> String { column < rows[index].count ? rows[index][column] : "" }
            order.sort { lhs, rhs in
                let a = value(lhs), b = value(rhs)
                let result: ComparisonResult
                if let x = Double(a.trimmingCharacters(in: .whitespaces)), let y = Double(b.trimmingCharacters(in: .whitespaces)) {
                    result = x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
                } else {
                    result = a.localizedStandardCompare(b)
                }
                if result == .orderedSame { return lhs < rhs }
                return descriptor.ascending ? result == .orderedAscending : result == .orderedDescending
            }
            tableView.reloadData()
        }
    }
}

// MARK: - JSONL

private struct ArtifactJSONLView: View {
    let result: ArtifactJSONLParser.Result

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(result.records) { record in
                        HStack(alignment: .top, spacing: 10) {
                            Text("\(record.lineNumber)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 56, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                if !record.isValid {
                                    Text(String(localized: "artifact.jsonl.invalid", defaultValue: "Invalid JSON"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(BreeChromePalette.currentSnapshot.signalError)
                                }
                                Text(record.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 8)
                        .background(record.isValid ? Color.clear : BreeChromePalette.currentSnapshot.signalError.opacity(0.1))
                        Divider()
                    }
                }
            }
            if result.truncated { ArtifactTruncationFooter() }
        }
    }
}
