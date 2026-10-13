import BreeFoundation
import BreeBrowser
import AppKit
import BreeSidebarProviderKit
import SwiftUI
import WebKit

struct BreeExtensionSidebarWorkspaceRowView: View, Equatable {
    let row: BreeSidebarProviderRow
    let workspace: BreeSidebarProviderWorkspace?
    let providerId: String
    let relativeNow: Date
    let isSelected: Bool
    let onSelect: (UUID) -> Void
    let onOpenWindow: (BreeSidebarProviderWorkspace) -> Void
    @State private var showsInspector = false
    @State private var inspectorDraft: BreeExtensionWorkspaceInspectorDraft?

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row &&
            lhs.workspace == rhs.workspace &&
            lhs.providerId == rhs.providerId &&
            lhs.relativeNow == rhs.relativeNow &&
            lhs.isSelected == rhs.isSelected
    }

    private var isSuperCompact: Bool {
        false
    }

    private var isThin: Bool {
        false
    }

    var body: some View {
        let primarySize: CGFloat = isSuperCompact ? 10.5 : 12.5
        let secondarySize: CGFloat = isSuperCompact ? 9 : 10
        HStack(spacing: isSuperCompact ? 5 : 7) {
            VStack(alignment: .leading, spacing: isSuperCompact ? 0 : 2) {
                Text(row.title)
                    .scaledFont(size: primarySize, weight: .regular)
                    .foregroundColor(isSelected ? .primary : .primary.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.tail)

                if !isSuperCompact, let subtitle = rendered(row.subtitle) {
                    Text(subtitle)
                        .scaledFont(size: secondarySize, weight: .regular)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isSuperCompact, let trailing = rendered(row.trailingText) {
                Text(trailing)
                    .scaledFont(size: 10.5, weight: .regular)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let accessory = row.accessory, let workspace {
                Button {
                    if inspectorDraft == nil {
                        inspectorDraft = BreeExtensionWorkspaceInspectorDraft.initial(
                            workspace: workspace,
                            selectedTab: accessory.defaultTab
                        )
                    }
                    showsInspector = true
                } label: {
                    Image(systemName: accessory.systemImageName)
                        .scaledFont(size: isSuperCompact ? 10 : 12, weight: .regular)
                        .frame(width: isSuperCompact ? 14 : 18, height: isSuperCompact ? 14 : 18)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.inspectWorkspace", defaultValue: "Workspace tools"))
                .popover(isPresented: $showsInspector, arrowEdge: .trailing) {
                    BreeExtensionWorkspaceInspectorView(
                        workspace: workspace,
                        draft: Binding(
                            get: {
                                inspectorDraft ?? BreeExtensionWorkspaceInspectorDraft.initial(
                                    workspace: workspace,
                                    selectedTab: accessory.defaultTab
                                )
                            },
                            set: { inspectorDraft = $0 }
                        ),
                        onOpenWindow: { onOpenWindow(workspace) }
                    )
                    .frame(width: 460, height: 340)
                }
            }
        }
        .padding(.leading, isSuperCompact ? 14 : 28)
        .padding(.trailing, 8)
        .padding(.vertical, isSuperCompact ? 2 : (isThin ? 5 : 7))
        .frame(minHeight: isSuperCompact ? 22 : 32)
        .background {
            if isSelected {
                Rectangle()
                    .fill(Color.primary.opacity(0.10))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect(row.workspaceId)
        }
    }

    private func rendered(_ text: BreeSidebarProviderText?) -> String? {
        guard let text else { return nil }
        switch text {
        case .plain(let value):
            return value
        case .localized(let localized):
            return BreeExtensionSidebarSelection.localizedText(localized)
        case .relativeDate(let date, _):
            return BreeExtensionRelativeTimeFormatter.string(from: date, to: relativeNow)
        }
    }
}

struct BreeExtensionWorkspaceInspectorDraft: Equatable {
    var selectedTab: BreeSidebarProviderWorkspacePopoverTab
    var notes: String
    var address: String
    var committedAddress: String

    static func initial(
        workspace: BreeSidebarProviderWorkspace,
        selectedTab: BreeSidebarProviderWorkspacePopoverTab = .notes
    ) -> BreeExtensionWorkspaceInspectorDraft {
        let initialAddress = "https://github.com/"
        return BreeExtensionWorkspaceInspectorDraft(
            selectedTab: selectedTab,
            notes: "",
            address: initialAddress,
            committedAddress: initialAddress
        )
    }
}

enum BreeExtensionRelativeTimeFormatter {
    static func string(from date: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return String(localized: "relativeTime.now", defaultValue: "now") }
        let minutes = seconds / 60
        if minutes < 60 { return localizedCount("relativeTime.minutes", defaultValue: "%lldm", count: minutes) }
        let hours = minutes / 60
        if hours < 24 { return localizedCount("relativeTime.hours", defaultValue: "%lldh", count: hours) }
        let days = hours / 24
        if days < 7 { return localizedCount("relativeTime.days", defaultValue: "%lldd", count: days) }
        let weeks = days / 7
        return localizedCount("relativeTime.weeks", defaultValue: "%lldw", count: weeks)
    }

    private static func localizedCount(_ key: String, defaultValue: String, count: Int) -> String {
        let format = NSLocalizedString(
            key,
            tableName: "Localizable",
            bundle: .main,
            value: defaultValue,
            comment: ""
        )
        return String.localizedStringWithFormat(format, Int64(count))
    }
}

struct BreeExtensionWorkspaceInspectorView: View {
    let workspace: BreeSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @Binding private var draft: BreeExtensionWorkspaceInspectorDraft

    init(
        workspace: BreeSidebarProviderWorkspace,
        draft: Binding<BreeExtensionWorkspaceInspectorDraft>,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self._draft = draft
        self.onOpenWindow = onOpenWindow
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $draft.selectedTab) {
                    Text(String(localized: "sidebar.extension.notesTab", defaultValue: "Notes")).tag(BreeSidebarProviderWorkspacePopoverTab.notes)
                    Text(String(localized: "sidebar.extension.browserTab", defaultValue: "Browser")).tag(BreeSidebarProviderWorkspacePopoverTab.browser)
                }
                .pickerStyle(.segmented)

                Button(action: onOpenWindow) {
                    Image(systemName: "macwindow")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .safeHelp(String(localized: "sidebar.extension.openWindow", defaultValue: "Open window"))
            }
            .padding(10)

            Divider()

            switch draft.selectedTab {
            case .notes:
                TextEditor(text: $draft.notes)
                    .scaledFont(size: 13)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .accessibilityIdentifier("ExtensionSidebarNotesEditor")
            case .browser:
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.secondary)
                        TextField(
                            String(localized: "sidebar.extension.browserAddress", defaultValue: "Search or enter URL"),
                            text: $draft.address
                        )
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let normalized = BreeExtensionWorkspaceInspectorBrowserView.normalizedAddress(draft.address)
                            draft.address = normalized
                            draft.committedAddress = normalized
                        }
                    }
                    .scaledFont(size: 12)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(Color(nsColor: .controlBackgroundColor))

                    BreeExtensionWorkspaceInspectorBrowserView(address: draft.committedAddress)
                }
            }
        }
    }
}

struct BreeExtensionWorkspaceInspectorWindowContentView: View {
    let workspace: BreeSidebarProviderWorkspace
    let onOpenWindow: () -> Void
    @State private var draft: BreeExtensionWorkspaceInspectorDraft

    init(
        workspace: BreeSidebarProviderWorkspace,
        onOpenWindow: @escaping () -> Void
    ) {
        self.workspace = workspace
        self.onOpenWindow = onOpenWindow
        _draft = State(initialValue: BreeExtensionWorkspaceInspectorDraft.initial(workspace: workspace))
    }

    var body: some View {
        BreeExtensionWorkspaceInspectorView(
            workspace: workspace,
            draft: $draft,
            onOpenWindow: onOpenWindow
        )
    }
}

struct BreeExtensionWorkspaceInspectorBrowserView: NSViewRepresentable {
    let address: String

    final class Coordinator {
        var loadedAddress: String?
    }

    static func normalizedAddress(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "https://github.com/" }
        if trimmed.contains("://") { return trimmed }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "https://\(trimmed)" }
        let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return "https://www.google.com/search?q=\(query)"
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = ExtensionSidebarWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let normalized = Self.normalizedAddress(address)
        guard context.coordinator.loadedAddress != normalized,
              let url = URL(string: normalized) else {
            return
        }
        context.coordinator.loadedAddress = normalized
        webView.load(URLRequest(url: url))
    }
}

@MainActor
final class BreeExtensionSidebarInspectorWindowController {
    private static var controllers: [UUID: NSWindowController] = [:]
    private static var closeObservers: [UUID: NSObjectProtocol] = [:]

    static func show(workspace: BreeSidebarProviderWorkspace) {
        if let controller = controllers[workspace.id] {
            controller.window?.title = workspace.title
            controller.window?.setContentSize(NSSize(width: 620, height: 440))
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = BreeExtensionWorkspaceInspectorWindowContentView(workspace: workspace) {
            show(workspace: workspace)
        }
        let hostingController = NSHostingController(rootView: view.frame(width: 620, height: 440))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.title
        window.identifier = NSUserInterfaceItemIdentifier("bree.extensionSidebarInspector")
        window.setContentSize(NSSize(width: 620, height: 440))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        let controller = NSWindowController(window: window)
        controllers[workspace.id] = controller
        closeObservers[workspace.id] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            Task { @MainActor in
                controllers.removeValue(forKey: workspace.id)
                if let observer = closeObservers.removeValue(forKey: workspace.id) {
                    NotificationCenter.default.removeObserver(observer)
                }
            }
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

/// Extension sidebar row web view: completes routed undo/redo chords with the
/// app's keyboard-layout-aware check.
private final class ExtensionSidebarWebView: BreeUndoableWebView {
    override func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        event.breeIsUndoRedoCommandEquivalent
    }
}
