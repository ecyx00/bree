import AppKit
import Bonsplit
import CmuxFoundation
import Combine
import CryptoKit
import SwiftUI

// MARK: - Pure helpers (unit-tested)

struct ArchitectureSourceLocation: Equatable {
    let path: String
    let line: Int?
    let column: Int?
}

/// Maps a link clicked inside `.architecture/current.html` to a local source file.
///
/// Archify (tt-a1i/archify) authors node sources as `sources: [{path, line, end_line, label}]`
/// with repo-relative POSIX paths. Its HTML links them to a pinned web blob
/// (`https://github.com/<o>/<r>/blob/<sha>/<path>#L12-L20`, `link_mode: web`) or leaves them
/// local-only. Also handled: `file://` URLs, `src/foo.py:42[:7]` and `src/foo.py#L42`.
enum ArchitectureSourceLink {
    static func resolve(
        _ href: String,
        root: String,
        exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> ArchitectureSourceLocation? {
        let archDir = root + "/.architecture"
        var rawPath: String
        var line: Int?
        if href.contains("://") || href.hasPrefix("file:") {
            guard let url = URL(string: href), let scheme = url.scheme?.lowercased() else { return nil }
            switch scheme {
            case "file":
                rawPath = url.path
            case "http", "https":
                // ponytail: any host; a local file with the same repo-relative path wins over the browser.
                let parts = url.path.components(separatedBy: "/")
                guard let blob = parts.firstIndex(of: "blob"), blob + 2 < parts.count else { return nil }
                rawPath = parts[(blob + 2)...].joined(separator: "/")
            default:
                return nil
            }
            line = lineFromFragment(url.fragment)
        } else {
            rawPath = href
            if let hash = rawPath.firstIndex(of: "#") {
                line = lineFromFragment(String(rawPath[rawPath.index(after: hash)...]))
                rawPath = String(rawPath[..<hash])
            }
            rawPath = rawPath.removingPercentEncoding ?? rawPath
        }

        var numbers: [Int] = []
        while numbers.count < 2, let colon = rawPath.lastIndex(of: ":"),
              let n = Int(rawPath[rawPath.index(after: colon)...]), n > 0 {
            numbers.insert(n, at: 0)
            rawPath = String(rawPath[..<colon])
        }
        var column: Int?
        if numbers.count == 2 {
            line = numbers[0]
            column = numbers[1]
        } else if let n = numbers.first {
            line = n
        }
        guard !rawPath.isEmpty else { return nil }

        var candidates: [String] = []
        if rawPath.hasPrefix("/") {
            candidates.append(rawPath)
            // A relative href resolved by WebKit against the .architecture directory.
            if rawPath.hasPrefix(archDir + "/") {
                candidates.append(root + "/" + rawPath.dropFirst(archDir.count + 1))
            }
        } else {
            candidates = [root + "/" + rawPath, archDir + "/" + rawPath]
        }
        for candidate in candidates {
            let path = (candidate as NSString).standardizingPath
            if path.hasPrefix(root + "/"), exists(path) {
                return ArchitectureSourceLocation(path: path, line: line, column: column)
            }
        }
        return nil
    }

    private static func lineFromFragment(_ fragment: String?) -> Int? {
        guard let fragment, fragment.hasPrefix("L") else { return nil }
        return Int(fragment.dropFirst().prefix(while: \.isNumber))
    }
}

struct ArchitectureChange: Equatable {
    enum Kind { case added, removed, changed }
    let kind: Kind
    let isEdge: Bool
    let id: String
    let label: String
    let sourcePath: String?
    let line: Int?
}

/// Id-matched diff of two `*.architecture.json` documents. Nodes are `components` (Archify)
/// or `nodes`; edges are `connections` or `edges` (id, else `from->to`).
enum ArchitectureDiff {
    private static let layoutKeys: Set<String> = [
        "row", "col", "pos", "size", "via", "labelAt", "labelDx", "labelDy", "labelSegment",
        "fromSide", "toSide", "route",
    ]

    /// nil when either document is not a JSON object.
    static func changes(old: Data, new: Data) -> [ArchitectureChange]? {
        guard let oldDoc = (try? JSONSerialization.jsonObject(with: old)) as? [String: Any],
              let newDoc = (try? JSONSerialization.jsonObject(with: new)) as? [String: Any] else { return nil }
        var result: [ArchitectureChange] = []
        for isEdge in [false, true] {
            let before = items(oldDoc, isEdge: isEdge)
            let after = items(newDoc, isEdge: isEdge)
            func change(_ kind: ArchitectureChange.Kind, _ id: String, _ item: [String: Any]) -> ArchitectureChange {
                let source = source(item)
                return ArchitectureChange(
                    kind: kind, isEdge: isEdge, id: id, label: (item["label"] as? String) ?? id,
                    sourcePath: source?.0, line: source?.1
                )
            }
            result += after.order.filter { before.byID[$0] == nil }.map { change(.added, $0, after.byID[$0]!) }
            result += before.order.filter { after.byID[$0] == nil }.map { change(.removed, $0, before.byID[$0]!) }
            result += after.order.compactMap { id in
                guard let old = before.byID[id], let new = after.byID[id],
                      !NSDictionary(dictionary: strip(old)).isEqual(to: strip(new)) else { return nil }
                return change(.changed, id, new)
            }
        }
        return result
    }

    private static func strip(_ item: [String: Any]) -> [String: Any] {
        item.filter { !layoutKeys.contains($0.key) }
    }

    private static func items(_ doc: [String: Any], isEdge: Bool) -> (order: [String], byID: [String: [String: Any]]) {
        let keys = isEdge ? ["connections", "edges"] : ["components", "nodes"]
        let array = keys.lazy.compactMap { doc[$0] as? [[String: Any]] }.first ?? []
        var order: [String] = []
        var byID: [String: [String: Any]] = [:]
        for item in array {
            let id = (item["id"] as? String)
                ?? (isEdge ? "\(item["from"] ?? "")->\(item["to"] ?? "")" : nil)
            guard let id else { continue }
            if byID[id] == nil { order.append(id) }
            byID[id] = item
        }
        return (order, byID)
    }

    private static func source(_ item: [String: Any]) -> (String, Int?)? {
        if let first = (item["sources"] as? [[String: Any]])?.first, let path = first["path"] as? String {
            return (path, first["line"] as? Int)
        }
        if let path = item["file"] as? String { return (path, item["line"] as? Int) }
        return nil
    }
}

/// Where the Changes tab takes its "before" model from: git `HEAD` when the repo tracks
/// `.architecture/current.architecture.json`, else `current.architecture.prev.json` (kept by the
/// generator on a full or refresh run). The fingerprint is what the delta board recorded when it was rendered.
enum ArchitectureBeforeSource: Equatable {
    case git(Data, fingerprint: String)
    case prev(Data, fingerprint: String)
    case none(noRepo: Bool)

    var data: Data? {
        switch self {
        case .git(let data, _), .prev(let data, _): return data
        case .none: return nil
        }
    }

    var fingerprint: String? {
        switch self {
        case .git(_, let fingerprint), .prev(_, let fingerprint): return fingerprint
        case .none: return nil
        }
    }

    /// `prev:` plus the first 16 hex digits of the file's SHA-256 (the same value as scripts/architecture/views/delta.py).
    static func prevFingerprint(_ data: Data) -> String {
        "prev:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    static func choose(git: (data: Data, fingerprint: String)?, noRepo: Bool, prev: Data?) -> ArchitectureBeforeSource {
        if let git { return .git(git.data, fingerprint: git.fingerprint) }
        if let prev { return .prev(prev, fingerprint: prevFingerprint(prev)) }
        return .none(noRepo: noRepo)
    }
}

/// What the Changes tab shows. One surface: the HTML delta board while it is fresh, else the native list.
enum ArchitectureChangesPlan: Equatable {
    /// `current.html#delta` in the web view.
    case board
    /// The native list, from this "before" document.
    case native(Data)
    case unavailable(noRepo: Bool)

    /// The `data-before-fp` the delta board recorded, nil when the page has no delta board.
    static func boardFingerprint(inHTML html: String) -> String? {
        guard let board = html.range(of: #"id="b-delta""#),
              let key = html.range(of: #"data-before-fp=""#, range: board.upperBound..<html.endIndex),
              let end = html[key.upperBound...].firstIndex(of: "\"") else { return nil }
        return String(html[key.upperBound..<end])
    }

    static func plan(html: String?, before: ArchitectureBeforeSource) -> ArchitectureChangesPlan {
        guard let data = before.data, let fingerprint = before.fingerprint else {
            if case .none(let noRepo) = before { return .unavailable(noRepo: noRepo) }
            return .unavailable(noRepo: false)
        }
        if let html, boardFingerprint(inHTML: html) == fingerprint { return .board }
        return .native(data)
    }
}

// MARK: - Entry points and popover

/// Routes the Architecture entry points (tab bar button, ctrl+4 / palette action, socket,
/// workspace follow hooks) to an `NSPopover` anchored to the pane's Architecture button.
/// It opens below the button with an arrow, never covers the shell editor textbox, closes on
/// Esc or an outside click. The popover is resizable (`TabBarPopoverSession`).
/// The web view, watchers, diff and export live in `ArchitectureViewModel`.
@MainActor
final class ArchitectureWindowController: NSObject {
    static let shared = ArchitectureWindowController()

    private final class Popup {
        let session: TabBarPopoverSession
        let model: ArchitectureViewModel
        var cancellables = Set<AnyCancellable>()
        init(session: TabBarPopoverSession, model: ArchitectureViewModel) {
            self.session = session
            self.model = model
        }
    }

    private var popups: [Popup] = []
    /// A transient popover closes on the mouse-down of the click that then fires the button's
    /// action; without this guard that action would reopen it at once.
    private var lastTransientCloseAt: CFTimeInterval = 0

    private func context(for workspace: Workspace) -> AppDelegate.MainWindowContext? {
        workspace.owningTabManager.flatMap { AppDelegate.shared?.mainWindowContext(for: $0) }
    }

    /// Opens the popover under the Architecture button, or closes it when already open.
    /// `openOnly`: never closes (socket `right_sidebar set`).
    func toggle(from workspace: Workspace, openOnly: Bool = false) {
        guard let context = context(for: workspace), let state = context.fileExplorerState,
              let parent = context.window else {
            NSSound.beep()
            return
        }
        let model = ArchitectureViewModel.model(for: state)
        if let popup = popups.first(where: { $0.model === model }) {
            if !openOnly { popup.session.close() }
            return
        }
        if !openOnly, let event = NSApp.currentEvent,
           [.leftMouseDown, .leftMouseUp].contains(event.type),
           CACurrentMediaTime() - lastTransientCloseAt < 0.3 {
            return
        }
        // One attached popover at a time; a detached one stays where the user put it.
        BreeOverlays.closeOthers(than: .architecture)
        open(model: model, workspace: workspace, parent: parent)
    }

    /// Closes the popover when it is open in the workspace's window.
    func close(for workspace: Workspace) {
        guard let state = context(for: workspace)?.fileExplorerState,
              let model = ArchitectureViewModel.existingModel(for: state) else { return }
        popups.first { $0.model === model }?.session.close()
    }

    func closeAllAttached() {
        for popup in popups where !popup.session.isDetached { popup.session.close() }
    }

    /// Closes the popover unless the user detached it into its own panel.
    func closeAttached(for workspace: Workspace) {
        guard let state = context(for: workspace)?.fileExplorerState,
              let model = ArchitectureViewModel.existingModel(for: state),
              let popup = popups.first(where: { $0.model === model }), !popup.session.isDetached else { return }
        popup.session.close()
    }

    /// Opens the popup on the boards view (the Current tab). Used by wiki `board:` links.
    func openBoards(from workspace: Workspace) {
        toggle(from: workspace, openOnly: true)
        guard let state = context(for: workspace)?.fileExplorerState else { return }
        ArchitectureViewModel.existingModel(for: state)?.select(.current)
    }

    /// Whether the popover is open in the workspace's window (drives the tab bar button's selected state).
    func isShowing(for workspace: Workspace) -> Bool {
        guard let state = context(for: workspace)?.fileExplorerState else { return false }
        return ArchitectureViewModel.existingModel(for: state)?.isPoppedOut == true
    }

    /// Re-targets a showing view to the focused workspace's project root: called when the
    /// selected workspace changes. Does nothing while Architecture is not on screen.
    func follow(_ workspace: Workspace) {
        guard let state = context(for: workspace)?.fileExplorerState,
              let model = ArchitectureViewModel.existingModel(for: state) else { return }
        model.follow(workspace)
    }

    /// The followed workspace changed directory (e.g. `cd` into another repo).
    func workspaceDirectoryChanged(_ workspace: Workspace) {
        guard let state = context(for: workspace)?.fileExplorerState,
              let model = ArchitectureViewModel.existingModel(for: state) else { return }
        model.workspaceDirectoryChanged(workspace)
    }

    // MARK: Open

    private static let toolbarHeight: CGFloat = 36

    /// Default content size for what the model shows, within `maxHeight` / `maxWidth`.
    private static func contentSize(
        content: ArchitectureContent, tab: ArchitectureTab, maxHeight: CGFloat, maxWidth: CGFloat
    ) -> NSSize {
        let size: NSSize
        switch content {
        case .empty where tab == .current:
            size = NSSize(width: 340, height: 120 + toolbarHeight)
        case .empty, .message:
            size = NSSize(width: 380, height: 160 + toolbarHeight)
        case .changes:
            size = NSSize(width: 520, height: 360)
        case .web:
            size = NSSize(width: 760, height: 760)
        }
        return NSSize(width: min(size.width, max(maxWidth, 280)), height: min(size.height, max(maxHeight, 120)))
    }

    private func open(model: ArchitectureViewModel, workspace: Workspace, parent: NSWindow) {
        guard let session = TabBarPopoverSession(
            workspace: workspace,
            parent: parent,
            slot: 0,
            sizeName: "architecture",
            preferredSize: { [weak model] maxWidth, maxHeight in
                Self.contentSize(content: model?.content ?? .empty, tab: model?.tab ?? .current, maxHeight: maxHeight, maxWidth: maxWidth)
            },
            content: ArchitecturePopoverView(
                model: model,
                onClose: { [weak self, weak model] in
                    guard let self, let model else { return }
                    self.popups.first { $0.model === model }?.session.close()
                }
            )
        ) else { return }
        let popup = Popup(session: session, model: model)
        session.onWillClose = { [weak self, weak model] in
            self?.lastTransientCloseAt = CACurrentMediaTime()
            model?.popoverWillClose()
        }
        // Esc: a source page goes back, the board closes its node card or contents list, else the popover closes.
        session.onEscape = { [weak model, weak session] in
            model?.handleEscape { session?.close() }
        }
        session.focusInitial = { [weak model] in model?.focusKeyboard() }
        session.onClosed = { [weak self, weak popup] in
            guard let self, let popup else { return }
            self.popups.removeAll { $0 === popup }
            popup.cancellables.removeAll()
            popup.model.setPoppedOut(false)
            NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
        }
        Publishers.CombineLatest(model.$content, model.$tab)
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak session] content, tab in
                session?.setPreferredSize { maxWidth, maxHeight in
                    Self.contentSize(content: content, tab: tab, maxHeight: maxHeight, maxWidth: maxWidth)
                }
            }
            .store(in: &popup.cancellables)

        popups.append(popup)
        model.setPoppedOut(true, workspace: workspace)
        model.popoverDidOpen()
        session.show()
        NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
    }
}

/// Architecture content inside the popover: no header and no close button (Esc or a click outside closes).
/// A source file opened from a diagram link covers the diagram (still alive underneath) until "back".
private struct ArchitecturePopoverView: View {
    @ObservedObject var model: ArchitectureViewModel
    let onClose: () -> Void
    @Environment(\.breePalette) private var palette

    var body: some View {
        ZStack {
            ArchitectureContentView(model: model)
                .allowsHitTesting(!model.showsSource)
                .accessibilityHidden(model.showsSource)
            if let pages = model.filePages {
                ArchitectureSourceOverlay(pages: pages, model: model)
            }
        }
        .background(palette.surfaceOverlay)
        .breeSurfaceColorScheme()
    }
}

/// The file page over the diagram: chevron Back (tooltip: the board or previous file), the file title, Quick View, then the page.
private struct ArchitectureSourceOverlay: View {
    @ObservedObject var pages: WikiPopoverModel
    @ObservedObject var model: ArchitectureViewModel
    @Environment(\.breePalette) private var palette

    var body: some View {
        if !pages.stack.isEmpty {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    WikiBackAndTitle(model: pages, backTitle: backLabel)
                    Spacer(minLength: 0)
                    if pages.canOpenInQuickView {
                        Button { pages.openInQuickView() } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .accessibilityLabel(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
                        }
                        .buttonStyle(BreeIconButtonStyle())
                        .accessibilityLabel(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
                        .help(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 36)
                Divider()
                WikiPageView(model: pages)
            }
            .background(palette.surfaceOverlay)
        }
    }

    private var backLabel: String {
        pages.stack.previousTitle
            ?? (model.diagramTitle.isEmpty
                ? String(localized: "architecture.source.backFallback", defaultValue: "Diagram")
                : model.diagramTitle)
    }
}
