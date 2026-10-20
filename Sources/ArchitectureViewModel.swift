import AppKit
import BreeFoundation
import Combine
import UniformTypeIdentifiers
import WebKit

/// What the Architecture view is showing right now.
enum ArchitectureContent: Equatable {
    /// No `.architecture/current.html` in the project.
    case empty
    /// The diagram in the web view.
    case web
    /// The git "Changes" list.
    case changes
    /// A one-line status (changes unavailable, nothing changed, ...).
    case message(String)
}

enum ArchitectureTab: Hashable {
    case current, changes
}

/// State and work behind the Architecture view: `<project>/.architecture/current.html` in a
/// web view, a git-HEAD comparison of `current.architecture.json`, and HTML/PNG export.
///
/// One model per main window (`model(for:)`). It is hosted either by the right sidebar or by the
/// pop-out window, never both. While neither shows it (`isActive == false`) it owns no file
/// watchers and no web view, so a hidden Architecture mode costs no CPU or WebKit process.
@MainActor
final class ArchitectureViewModel: NSObject, ObservableObject, WKNavigationDelegate {
    @Published private(set) var content: ArchitectureContent = .empty
    @Published private(set) var tab: ArchitectureTab = .current
    @Published private(set) var changes: [ArchitectureChange] = []
    @Published private(set) var root = ""
    @Published private(set) var isActive = false
    @Published private(set) var isPoppedOut = false
    /// Source files opened from a diagram link: shown over the diagram inside the popover (the Wiki's file page).
    @Published private(set) var filePages: WikiPopoverModel?
    @Published private(set) var showsSource = false
    /// The title of the board on screen, the label of the back control of a source page.
    @Published private(set) var diagramTitle = ""
    private var filePagesObservation: AnyCancellable?
    /// What `filePages` held when the popover closed, shown again when it reopens.
    private var savedSourceStack: WikiBackStack?
    private var focusWebViewWhenAttached = false

    private(set) weak var workspace: Workspace?
    private var sidebarActive = false
    private var watchers: [FileWatcher] = []
    private var watchTasks: [Task<Void, Never>] = []
    private var debounce: Task<Void, Never>?
    private var paletteObserver: NSObjectProtocol?
    /// Bumped on every `showCurrent`, so a slow anchor build never loads a stale page.
    private var showGeneration = 0
    private var exportPanel: NSSavePanel?
    private(set) var webView: WKWebView?

    var htmlPath: String { root + "/.architecture/current.html" }
    private var jsonPath: String { root + "/.architecture/current.architecture.json" }

    // MARK: Per-window registry

    private static let models = NSMapTable<FileExplorerState, ArchitectureViewModel>.weakToStrongObjects()

    static func model(for state: FileExplorerState) -> ArchitectureViewModel {
        if let model = models.object(forKey: state) { return model }
        let model = ArchitectureViewModel()
        models.setObject(model, forKey: state)
        return model
    }

    static func existingModel(for state: FileExplorerState) -> ArchitectureViewModel? {
        models.object(forKey: state)
    }

    // MARK: Hosting

    /// The sidebar reports whether Architecture is the visible right-sidebar mode.
    func setSidebarActive(_ active: Bool, workspace: Workspace?) {
        sidebarActive = active
        if active, let workspace { target(workspace) }
        updateActivity()
    }

    /// The pop-out window opened or closed. The web view is rebuilt because it cannot move
    /// between two hosts.
    func setPoppedOut(_ poppedOut: Bool, workspace: Workspace? = nil) {
        guard isPoppedOut != poppedOut else { return }
        isPoppedOut = poppedOut
        if poppedOut, let workspace { target(workspace) }
        tearDownWebView()
        if isActive { refresh() }
        updateActivity()
    }

    private func updateActivity() {
        let next = sidebarActive || isPoppedOut
        guard next != isActive else { return }
        isActive = next
        if next {
            startWatching()
            refresh()
        } else {
            stopWatching()
            tearDownWebView()
        }
    }

    /// Follows the focused workspace; ignored while nothing shows the view.
    func follow(_ workspace: Workspace) {
        guard isActive, self.workspace !== workspace else { return }
        target(workspace)
    }

    /// The followed workspace changed directory (e.g. `cd` into another repo).
    func workspaceDirectoryChanged(_ workspace: Workspace) {
        guard isActive, self.workspace === workspace,
              Self.projectRoot(for: workspace.currentDirectory) != root else { return }
        target(workspace)
    }

    private func target(_ workspace: Workspace) {
        let nextRoot = Self.projectRoot(for: workspace.currentDirectory)
        let unchanged = self.workspace === workspace && nextRoot == root
        self.workspace = workspace
        guard !unchanged else { return }
        root = nextRoot
        tab = .current
        dropSourcePages()
        guard isActive else { return }
        startWatching()
        refresh()
    }

    /// The nearest ancestor holding `.architecture` (or `.git`), else `dir` itself.
    /// `dir` is the focused workspace's directory, so each workspace shows its own project.
    static func projectRoot(for dir: String) -> String {
        let start = URL(fileURLWithPath: dir).standardizedFileURL
        var url = start
        while true {
            for marker in [".architecture", ".git"]
            where FileManager.default.fileExists(atPath: url.appendingPathComponent(marker).path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return start.path }
            url = parent
        }
    }

    // MARK: Web view

    func ensureWebView() -> WKWebView {
        if let webView { return webView }
        // The board does its own canvas zoom and pan (pinch, ⌘-scroll, drag), so native magnification stays off.
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(ArchitectureBridgeHandler(self), name: Self.bridgeName)
        let view = ArchitectureWKWebView(frame: .zero, configuration: configuration)
        view.allowsMagnification = false
        view.navigationDelegate = self
        view.focusWhenAttached = focusWebViewWhenAttached
        webView = view
        paletteObserver = NotificationCenter.default.addObserver(
            forName: BreeChromePaletteStore.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.webView?.evaluateJavaScript(ArchitectureWebTheme.updateScript(palette: .currentSnapshot))
            }
        }
        return view
    }

    private func tearDownWebView() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: Self.bridgeName)
        webView?.configuration.userContentController.removeAllUserScripts()
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        if let paletteObserver { NotificationCenter.default.removeObserver(paletteObserver) }
        paletteObserver = nil
    }

    /// `window.webkit.messageHandlers.bree`: messages from the board (`{type: "openWiki", slug}`).
    static let bridgeName = "bree"

    fileprivate func handleBridge(_ body: Any) {
        if let message = body as? [String: Any], message["type"] as? String == "openCode",
           let href = message["href"] as? String {
            openCodeLink(href, quickView: message["meta"] as? Bool ?? false)
            return
        }
        guard let message = body as? [String: Any], message["type"] as? String == "openWiki",
              let slug = message["slug"] as? String, WikiLink.isSafeSlug(slug), let workspace else { return }
        // One popover at a time: the Architecture popover closes and the Wiki popover opens on the page.
        ArchitectureWindowController.shared.closeAttached(for: workspace)
        WikiPopoverController.shared.open(slug: slug, from: workspace)
    }

    // MARK: Source pages and keyboard

    private func dropSourcePages() {
        filePagesObservation = nil
        filePages = nil
        showsSource = false
        savedSourceStack = nil
    }

    /// Shows `location` over the diagram as a file page: the line marked, "‹ <board>" to return.
    func showSource(_ location: ArchitectureSourceLocation) {
        guard let workspace, !WikiPaths.isBlockedSource(location.path) else { return }
        let pages = sourcePages(for: workspace)
        diagramTitle = ""
        if content == .web { refreshDiagramTitle() }
        pages.focusPage()
        pages.pushFile(path: location.path, line: location.line)
    }

    private func sourcePages(for workspace: Workspace) -> WikiPopoverModel {
        if let filePages, filePages.workspace === workspace { return filePages }
        let pages = WikiPopoverModel(workspace: workspace, root: root)
        filePages = pages
        filePagesObservation = pages.$stack.sink { [weak self] stack in
            guard let self else { return }
            let shows = !stack.isEmpty
            if self.showsSource && !shows { self.focusWebView() }
            self.showsSource = shows
        }
        return pages
    }

    private func refreshDiagramTitle() {
        webView?.evaluateJavaScript("(document.getElementById('ttl')||{}).textContent||document.title||''") { [weak self] result, _ in
            if let title = result as? String, !title.isEmpty {
                MainActor.assumeIsolated { self?.diagramTitle = title }
            }
        }
    }

    /// The popover is closing: keep the source stack (with the reader's offset) for the next open.
    func popoverWillClose() {
        savedSourceStack = filePages.map { $0.snapshot() }.flatMap { $0.isEmpty ? nil : $0 }
        focusWebViewWhenAttached = false
        (webView as? ArchitectureWKWebView)?.focusWhenAttached = false
    }

    /// The popover opened: bring a remembered source page back and give the keys to what is on screen.
    func popoverDidOpen() {
        if let saved = savedSourceStack, let workspace {
            sourcePages(for: workspace).restore(saved)
        }
        savedSourceStack = nil
    }

    /// The popover is key: the diagram (or the source page over it) takes the keyboard.
    func focusKeyboard() {
        if showsSource { filePages?.focusPage() } else { focusWebView() }
    }

    func focusWebView() {
        focusWebViewWhenAttached = true
        guard let webView = webView as? ArchitectureWKWebView else { return }
        webView.focusWhenAttached = true
        if let window = webView.window {
            webView.focusWhenAttached = false
            focusWebViewWhenAttached = false
            window.makeFirstResponder(webView)
        }
    }

    /// Esc: a source page goes back first, then the board closes its node card or contents list
    /// (`window.breeHandleEscape()`), and only then `close` runs.
    func handleEscape(close: @escaping () -> Void) {
        if let pages = filePages, !pages.stack.isEmpty {
            pages.back()
            return
        }
        guard let webView, content == .web else { return close() }
        webView.evaluateJavaScript("window.breeHandleEscape ? window.breeHandleEscape() : false") { result, _ in
            MainActor.assumeIsolated { if (result as? Bool) != true { close() } }
        }
    }

    // MARK: Content

    func select(_ tab: ArchitectureTab) {
        switch tab {
        case .current: showCurrent()
        case .changes: loadChanges()
        }
    }

    func refresh() {
        guard isActive, !root.isEmpty else { return }
        select(tab)
    }

    private func showCurrent() {
        tab = .current
        showPage(fragment: nil)
    }

    /// Loads `current.html` in the web view; `fragment` selects a board (`delta` for the Changes tab).
    private func showPage(fragment: String?) {
        guard FileManager.default.fileExists(atPath: htmlPath) else {
            content = .empty
            return
        }
        content = .web
        let webView = ensureWebView()
        showGeneration += 1
        let generation = showGeneration
        let root = self.root
        let url = URL(fileURLWithPath: htmlPath)
        Task { [weak self] in
            let anchors = await Task.detached(priority: .utility) { Self.anchorsJSON(repoRoot: root) }.value
            guard let self, self.showGeneration == generation, self.webView === webView else { return }
            // Document-start script: Bree's palette variables and `window.breeWikiAnchors` exist before the page runs.
            let controller = webView.configuration.userContentController
            controller.removeAllUserScripts()
            controller.addUserScript(WKUserScript(
                source: ArchitectureWebTheme.userScript(palette: .currentSnapshot, anchorsJSON: anchors)
                    + (fragment.map { "history.replaceState(null,'','#\($0)');" } ?? ""),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            webView.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: root))
        }
    }

    /// Code anchors of the matched project's wiki pages that point into `repoRoot`; `{}` without a wiki.
    private nonisolated static func anchorsJSON(repoRoot: String) -> String {
        guard let index = WikiLibrary.load(repoRoot: repoRoot).project(for: repoRoot) else { return "{}" }
        let map = WikiAnchors.build(index: index, repoRoot: repoRoot) { page in
            index.pagePath(for: page).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
        return WikiAnchors.json(map)
    }

    private func loadChanges() {
        tab = .changes
        let root = self.root
        Task { [weak self] in
            let (before, html) = await Task.detached(priority: .utility) {
                (Self.resolveBefore(root: root), try? String(contentsOfFile: root + "/.architecture/current.html", encoding: .utf8))
            }.value
            guard let self, self.tab == .changes, self.root == root else { return }
            self.applyChanges(ArchitectureChangesPlan.plan(html: html, before: before), before: before)
        }
    }

    private func applyChanges(_ plan: ArchitectureChangesPlan, before: ArchitectureBeforeSource) {
        switch plan {
        case .board:
            showPage(fragment: "delta")
        case .unavailable(let noRepo):
            content = noRepo
                ? .message(String(localized: "architecture.changes.noRepo", defaultValue: "This folder is not in a git repository."))
                : .message(String(localized: "architecture.changes.noHead", defaultValue: "No committed version of .architecture/current.architecture.json to compare with."))
        case .native(let old):
            guard let new = FileManager.default.contents(atPath: jsonPath),
                  let list = ArchitectureDiff.changes(old: old, new: new) else {
                content = .message(String(localized: "architecture.changes.invalid", defaultValue: "Could not read .architecture/current.architecture.json."))
                return
            }
            changes = list
            if !list.isEmpty {
                content = .changes
            } else if case .prev = before {
                content = .message(String(localized: "architecture.changes.nonePrev", defaultValue: "No changes since the previous generation."))
            } else {
                content = .message(String(localized: "architecture.changes.none", defaultValue: "No changes since the last commit."))
            }
        }
    }

    /// The "before" model: git `HEAD` when the repo tracks the file, else the previous generation. Runs off the main actor.
    private nonisolated static func resolveBefore(root: String) -> ArchitectureBeforeSource {
        let path = "./.architecture/current.architecture.json"
        let show = git(root: root, ["show", "HEAD:" + path])
        var tracked: (data: Data, fingerprint: String)?
        if show.status == 0,
           let head = git(root: root, ["rev-parse", "HEAD"]).text,
           let blob = git(root: root, ["rev-parse", "HEAD:" + path]).text {
            tracked = (show.data, "git:\(head):\(blob)")
        }
        let prev = FileManager.default.contents(atPath: root + "/.architecture/current.architecture.prev.json")
        return .choose(git: tracked, noRepo: show.message.contains("not a git repository") || show.status == nil, prev: prev)
    }

    /// Local `git -C root ...`. `status` is nil when git could not be started.
    private nonisolated static func git(root: String, _ arguments: [String]) -> (status: Int32?, data: Data, message: String, text: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root] + arguments
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, Data(), "", nil) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let message = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, data, message, process.terminationStatus == 0 && !text.isEmpty ? text : nil)
    }

    // MARK: Watching

    private func startWatching() {
        stopWatching()
        // FileWatcher also observes the nearest existing ancestor, so a missing
        // file or `.architecture` directory is picked up when it is created.
        for name in ["current.html", "current.architecture.json"] {
            let watcher = FileWatcher(path: root + "/.architecture/" + name, throttle: .milliseconds(200))
            watchers.append(watcher)
            watchTasks.append(Task { [weak self] in
                for await _ in watcher.events { self?.scheduleRefresh() }
            })
        }
    }

    private func stopWatching() {
        watchTasks.forEach { $0.cancel() }
        watchTasks = []
        debounce?.cancel()
        let stopped = watchers
        watchers = []
        Task { for watcher in stopped { await watcher.stop() } }
    }

    private func scheduleRefresh() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Actions

    /// Opens a code link: a file page in the popover (`quickView`, the ⌘-click, is the opt-in way out to Quick View).
    @discardableResult
    func openCodeLink(_ href: String, quickView: Bool) -> Bool {
        let location = ArchitectureSourceLink.resolve(href, root: root)
        breeDebugLog("architecture.link href=\(href) resolved=\(location?.path ?? "nil") root=\(root)")
        guard let location, let workspace else { return false }
        if quickView {
            QuickViewResource.file(path: location.path, line: location.line, column: location.column).open(from: workspace)
        } else {
            showSource(location)
        }
        return true
    }

    func openChange(_ change: ArchitectureChange) {
        guard workspace != nil, let path = change.sourcePath,
              let location = ArchitectureSourceLink.resolve(path, root: root) else { return }
        showSource(ArchitectureSourceLocation(path: location.path, line: change.line ?? location.line, column: location.column))
    }

    func export() {
        guard FileManager.default.fileExists(atPath: htmlPath) else { return }
        // PNG snapshots the web view, so make sure the diagram is the visible content.
        if content != .web { showCurrent() }
        let panel = NSSavePanel()
        let format = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 110, height: 26), pullsDown: false)
        format.addItems(withTitles: ["HTML", "PNG"])
        format.target = self
        format.action = #selector(exportFormatChanged(_:))
        panel.accessoryView = format
        panel.canCreateDirectories = true
        exportPanel = panel
        exportFormatChanged(format)
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        Task {
            let response: NSApplication.ModalResponse
            if let window {
                response = await panel.beginSheetModal(for: window)
            } else {
                response = await withCheckedContinuation { continuation in
                    panel.begin { continuation.resume(returning: $0) }
                }
            }
            exportPanel = nil
            guard response == .OK, let url = panel.url else { return }
            do {
                if format.indexOfSelectedItem == 0 {
                    try? FileManager.default.removeItem(at: url)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: htmlPath), to: url)
                } else {
                    try await writePNG(to: url)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func exportFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = exportPanel else { return }
        let isHTML = sender.indexOfSelectedItem == 0
        panel.allowedContentTypes = [isHTML ? .html : .png]
        panel.nameFieldStringValue = "architecture." + (isHTML ? "html" : "png")
    }

    private func writePNG(to url: URL) async throws {
        guard let webView else { throw CocoaError(.fileWriteUnknown) }
        let size = (try await webView.evaluateJavaScript(
            "[document.documentElement.scrollWidth, document.documentElement.scrollHeight]"
        )) as? [NSNumber]
        let configuration = WKSnapshotConfiguration()
        if let size, size.count == 2, size[0].doubleValue > 0, size[1].doubleValue > 0 {
            configuration.rect = CGRect(x: 0, y: 0, width: size[0].doubleValue, height: size[1].doubleValue)
            configuration.snapshotWidth = NSNumber(value: size[0].doubleValue * 2)
        }
        let image = try await webView.takeSnapshot(configuration: configuration)
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
    }

    // MARK: Links

    /// The popup is narrower than most boards: aspect-fit the board (legend included), but never below 60% of its natural size: past that it keeps 60% and scrolls (wheel/drag pan).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard isPoppedOut else { return }
        // The picker label truncates in a narrow popup: keep its full name as a tooltip.
        webView.evaluateJavaScript("""
        try{fitView();if(st.s<0.6){const r=stage.getBoundingClientRect(),[l,t,rr]=contentBox(),s=0.6,cw=(rr-l)*s;st={s,tx:(cw+2*PAD<r.width?(r.width-cw)/2:PAD)-l*s,ty:PAD-t*s,fit:false};clampPan();apply();}const t=document.getElementById('ttl'),b=document.getElementById('toc'),f=()=>{b.title=t.textContent};f();new MutationObserver(f).observe(t,{childList:true,characterData:true,subtree:true})}catch(e){}
        """)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else { return .allow }
        // The board also activates `bree-bridge:<json>`; the `bree` message handler already took that message.
        if url.scheme == "bree-bridge" { return .cancel }
        // In-page anchors and other diagram pages stay in the web view.
        if url.isFileURL, url.path == htmlPath || url.pathExtension == "html" { return .allow }
        if openCodeLink(url.absoluteString, quickView: navigationAction.modifierFlags.contains(.command)) {
            return .cancel
        } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }
}

/// Registers itself with the window's focus controller so Architecture focus lands on the
/// diagram (arrow keys scroll it) instead of the sidebar host.
final class ArchitectureWKWebView: WKWebView {
    /// ⌘=, ⌘-, ⌘0 and ⌘1 belong to the board's own canvas zoom while the board has keyboard focus. The app-wide
    /// shortcut monitor (browser/markdown zoom, workspace numbers) must not take them first.
    static func shouldReceive(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift) == .command,
              ["=", "+", "-", "0", "1"].contains(event.charactersIgnoringModifiers ?? ""),
              var view = event.window?.firstResponder as? NSView else { return false }
        while true {
            if view is ArchitectureWKWebView { return true }
            guard let parent = view.superview else { return false }
            view = parent
        }
    }

    /// Set while the popover waits for this view to enter its window so it can take the keyboard.
    var focusWhenAttached = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        if focusWhenAttached {
            focusWhenAttached = false
            DispatchQueue.main.async { [weak self, weak window] in
                guard let self, let window, self.window === window else { return }
                window.makeFirstResponder(self)
            }
        }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerArchitectureWebView(self)
    }
}

/// Keeps the web view's content controller from retaining the model.
private final class ArchitectureBridgeHandler: NSObject, WKScriptMessageHandler {
    private weak var model: ArchitectureViewModel?
    init(_ model: ArchitectureViewModel) { self.model = model }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor [weak model] in model?.handleBridge(body) }
    }
}
