import AppKit
import Combine
import BreeFoundation
import SwiftUI

// The Wiki popover: topic list ("This project" / "General"), and pages shown in place with a back stack.
// Pure logic is in WikiPopoverSupport.swift, link routing in WikiRouter, rendering in the shared markdown viewer.

@MainActor
final class WikiPopoverModel: ObservableObject {
    @Published private(set) var project: WikiIndex?
    @Published private(set) var general: WikiIndex?
    /// Unusable index.json files that concern this project; shown as error rows.
    @Published private(set) var issues: [WikiIssue] = []
    @Published private(set) var loaded = false
    /// The wiki's own text size in px (12...18), kept across launches.
    @Published private(set) var fontSize = WikiFontSize.resolved()
    @Published private(set) var scope: WikiScope = .project
    @Published private(set) var stack = WikiBackStack()
    @Published private(set) var markdown = ""
    /// Set when the page on top cannot be shown (too large, binary, unreadable, raw capture text).
    @Published private(set) var unsupported: WikiFilePage.Reason?
    // Search (pure logic in WikiSearch.swift).
    @Published private(set) var isSearching = false
    @Published private(set) var query = ""
    @Published private(set) var results: [WikiSearchHit] = []
    @Published private(set) var selection = 0
    @Published private(set) var searchAll = true
    @Published private(set) var recentSearches: [String] = []
    @Published private(set) var recentPages: [WikiRecents.Page] = []
    /// Whether the page's own H1 is on screen: the header title stays empty meanwhile (the page reports it).
    @Published private(set) var pageHeadingVisible = false
    /// Height of the topic list's content, reported by the list (0 until measured).
    @Published private(set) var listHeight: CGFloat = 0

    let session = MarkdownRendererSession()
    let panelId = UUID()
    let root: String
    private(set) weak var workspace: Workspace?
    private var userScope: WikiScope?
    private let recents = WikiRecents()
    private var allIndexes: [WikiIndex] = []
    private var searchIndex = WikiSearchIndex()
    private var indexBuilt = false
    private var searchTask: Task<Void, Never>?
    private var buildTask: Task<Void, Never>?
    private var highlightToken: String?
    /// Chip pages (`WikiMemory`) already loaded, by pseudo path; and the code root a commit chip was clicked under.
    private var memoryPages: [String: (title: String, markdown: String)] = [:]
    /// Shared by every popover: the trust dialog closes the popover, and the restored chip page must still find its config.
    private static var sharedMemoryRoots: [String: String] = [:]
    private static var sharedMemoryConfigs: [String: WikiConfig] = [:]
    private var memoryRoots: [String: String] {
        get { Self.sharedMemoryRoots }
        set { Self.sharedMemoryRoots = newValue }
    }
    private var memoryConfigs: [String: WikiConfig] {
        get { Self.sharedMemoryConfigs }
        set { Self.sharedMemoryConfigs = newValue }
    }
    // The page on top, as the web view must present it once it has rendered.
    private var isSource = false
    private var isInert = false
    private var pageLine: Int?
    /// Offset to restore after the next render (back, or reopening); nil = top / target line.
    private var pendingScroll: Double?
    /// The reader's current offset, reported by the page.
    private var liveScroll: Double = 0
    private var lastEscapeTimestamp: TimeInterval = -1
    /// Called to close the popover (a `board:` link hands over to the Architecture popover).
    var close: () -> Void = {}

    init(workspace: Workspace, root: String) {
        self.workspace = workspace
        self.root = root
        session.onMarkdownRendered = { [weak self] in self?.pageRendered() }
    }

    /// ⌘= (+1), ⌘− (-1), ⌘0 (0 = default).
    func zoom(_ step: Int) {
        fontSize = step == 0 ? WikiFontSize.defaultSize : WikiFontSize.clamp(fontSize + Double(step))
        WikiFontSize.set(fontSize)
    }

    var scopes: [WikiScope] { WikiBrowse.scopes(project: project, general: general) }
    var listIndex: WikiIndex? { WikiBrowse.index(for: scope, project: project, general: general) }

    /// Reads the indexes off the main actor. `slug`: open that page when the indexes are in.
    func load(openSlug slug: String? = nil) {
        let root = self.root
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { WikiLibrary.load(repoRoot: root) }.value
            guard let self else { return }
            let project = loaded.project(for: root)
            let general = loaded.general
            self.allIndexes = loaded.searchable
            self.issues = loaded.issues
            self.project = project
            self.general = general
            self.scope = WikiBrowse.resolvedScope(self.userScope, project: project, general: general)
            self.loaded = true
            if let slug { self.openSlug(slug) }
        }
    }

    func select(_ scope: WikiScope) {
        userScope = scope
        self.scope = scope
    }

    func open(_ page: WikiPage, in index: WikiIndex) {
        guard let path = index.pagePath(for: page), FileManager.default.fileExists(atPath: path) else { return }
        if !index.root.isEmpty { WikiOpeners.roots[WikiOpeners.key(path)] = index.root }
        push(path: path, title: page.title)
    }

    /// Opens a page by slug: the matched project's entry first, then `[[slug]]` resolution in the project folder.
    private func openSlug(_ slug: String) {
        for index in [project, general].compactMap({ $0 }) {
            if let page = index.pages.first(where: { $0.slug == slug }) { return open(page, in: index) }
        }
        if let dir = project?.dir, let path = WikiPaths.resolveSlug(slug, pageDir: dir) {
            if let root = project?.root, !root.isEmpty { WikiOpeners.roots[WikiOpeners.key(path)] = root }
            push(path: path, title: slug)
        }
    }

    private func push(path: String, title: String, line: Int? = nil) {
        highlightToken = nil
        let depth = stack.depth
        stack.push(.init(path: path, title: title, line: line), leavingScrollY: liveScroll)
        guard stack.depth != depth, let entry = stack.current else { return }
        if WikiPaths.isWikiPage(path) { recents.addPage(path: path, title: title) }
        show(entry, scroll: nil)
    }

    func back() {
        highlightToken = nil
        stack.pop()
        if let entry = stack.current {
            show(entry, scroll: entry.scrollY)
        } else {
            markdown = ""
            unsupported = nil
        }
    }

    func reportScroll(_ y: Double) { liveScroll = y }

    func reportListHeight(_ height: CGFloat) {
        if abs(listHeight - height) > 0.5 { listHeight = height }
    }

    func reportHeading(visible: Bool) {
        if pageHeadingVisible != visible { pageHeadingVisible = visible }
    }

    /// The header title: empty while the H1 shows, always shown when there is no page to scroll (fallback text).
    var headerTitle: String {
        WikiTitle.header(title: stack.current?.title ?? "", pageHeadingVisible: pageHeadingVisible && unsupported == nil)
    }

    /// The full path of a file page (header tooltip); nil for wiki pages and memory pages.
    var headerTooltip: String? {
        guard let path = stack.current?.path, WikiMemory.chip(fromPath: path) == nil, !WikiPaths.isWikiPage(path) else { return nil }
        return path
    }

    private var wantsPageFocus = false

    /// The popover became key: the page takes the keys (`[`, `]`, arrows, Tab, ⌘F); search focuses its own field.
    func focusPage() {
        wantsPageFocus = true
        applyPageFocus()
    }

    private func applyPageFocus() {
        guard wantsPageFocus, !isSearching, unsupported == nil, !stack.isEmpty,
              let webView = session.webView, let window = webView.window else { return }
        wantsPageFocus = false
        window.makeFirstResponder(webView)
    }

    /// Loads the page on top into the view state. `scroll`: restore this offset after the render.
    private func show(_ entry: WikiBackStack.Entry, scroll: Double?) {
        pendingScroll = scroll
        liveScroll = scroll ?? 0
        pageHeadingVisible = false
        pageLine = entry.line
        isSource = false
        isInert = false
        unsupported = nil
        if let chip = WikiMemory.chip(fromPath: entry.path) {
            showMemory(entry, kind: chip.kind, value: chip.value)
            return
        }
        switch WikiFilePage.load(path: entry.path, line: entry.line) {
        case .markdown(let text): markdown = text
        case .card(let text): markdown = text; isInert = true
        case .source(let text, _): markdown = text; isSource = true
        case .unsupported(let reason): markdown = ""; unsupported = reason
        }
    }

    /// A chip page: from the cache, else loaded off the main thread (the page shows "…" meanwhile).
    private func showMemory(_ entry: WikiBackStack.Entry, kind: String, value: String) {
        isInert = true
        if let page = memoryPages[entry.path] {
            markdown = page.markdown
            stack.retitleCurrent(page.title)
            return
        }
        markdown = "…"
        let path = entry.path
        let config = memoryConfigs[path] ?? .empty
        var command = WikiChip.previewCommand(kind: kind, value: value, root: memoryRoots[path], config: config)
        // A repo-local wiki's declared command runs only after a one-time approval; the built-in git one never asks.
        if let chip = config.chips[kind], kind != "commit",
           command != nil, !WikiTrust.authorize(config: config, argv: chip.argv) { command = nil }
        Task { [weak self] in
            var text: String?
            if let command { text = await WikiPreview.text(for: command) }
            guard let self else { return }
            let page = WikiMemory.page(kind: kind, value: value, text: text, config: config)
            // Failures are not cached, so reopening the chip tries again.
            if text != nil { self.memoryPages[path] = page }
            guard self.stack.current?.path == path else { return }
            self.stack.retitleCurrent(page.title)
            self.markdown = page.markdown
        }
    }

    /// A click on an `m:`, a declared or a `commit:` chip: the memory or commit opens as a page on top of the stack.
    private func pushMemory(kind: String, value: String, from page: WikiBackStack.Entry) {
        let path = WikiMemory.pseudoPath(kind: kind, value: value)
        memoryRoots[path] = WikiRouter.codeRoot(pagePath: page.path)
        memoryConfigs[path] = WikiConfig.forPage(page.path)
        push(path: path, title: WikiMemory.label(.note))
    }

    /// The stack to keep while the popover is closed (the top page with its live offset).
    func snapshot() -> WikiBackStack {
        var copy = stack
        copy.recordScroll(liveScroll)
        return copy
    }

    /// Shows a remembered stack again, at the remembered offset.
    func restore(_ saved: WikiBackStack) {
        stack = saved
        if let entry = saved.current { show(entry, scroll: entry.scrollY) }
    }

    /// The ↗ button: the page on top in a Quick View window (opt-in; links stay in the popover).
    func openInQuickView() {
        guard let entry = stack.current, let workspace, WikiMemory.chip(fromPath: entry.path) == nil,
              !WikiPaths.isBlockedSource(entry.path) else { return }
        QuickViewResource.file(path: entry.path, line: entry.line).open(from: workspace)
    }

    var canOpenInQuickView: Bool {
        guard let entry = stack.current, WikiMemory.chip(fromPath: entry.path) == nil else { return false }
        return unsupported != .forbidden && unsupported != .unreadable && !WikiPaths.isBlockedSource(entry.path)
    }

    /// Shows a file as a page on top of the stack (the Architecture popover's code links).
    func pushFile(path: String, line: Int?) {
        push(path: path, title: WikiTitle.file(path: path), line: line)
    }

    /// After a render: number source lines, restore the offset or go to the target line, then flash a search match.
    private func pageRendered() {
        guard unsupported == nil, let webView = session.webView else { return }
        let js = WikiPageScript.afterRender(source: isSource, line: pageLine, scrollY: pendingScroll, inert: isInert)
        pendingScroll = nil
        webView.evaluateJavaScript(js, completionHandler: nil)
        applyHighlight()
        applyPageFocus()
    }

    /// A click on an internal link of the shown page.
    func route(href: String, quickView: Bool = false) {
        guard let page = stack.current else { return }
        if case .chip(let kind, let value)? = WikiLink.parse(href),
           kind == "commit" || WikiConfig.forPage(page.path).chips[kind] != nil {
            return pushMemory(kind: kind, value: value, from: page)
        }
        let workspace = self.workspace
        WikiRouter.route(href: href, pagePath: page.path, actions: .init(
            workspace: workspace,
            openResource: { resource in if let workspace { resource.open(from: workspace) } },
            openPage: { [weak self] path in
                self?.push(path: path, title: self?.title(forPath: path) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension)
            },
            pushFile: { [weak self] path, line in
                self?.push(path: path, title: WikiTitle.file(path: path), line: line)
            }
        ), quickView: quickView)
    }

    // MARK: Search

    /// The indexes search covers: the matched project first, then General, then every other project.
    private var searchableIndexes: [WikiIndex] {
        let others = allIndexes.filter { $0.project != project?.project }
        return [project, general].compactMap { $0 } + others
    }

    func startSearch() {
        isSearching = true
        indexBuilt = false
        query = ""
        results = []
        selection = 0
        recentSearches = recents.searches
        recentPages = recents.pages
        // Rebuilt on every open, so edits to the wiki show up without a watcher.
        let indexes = searchableIndexes
        buildTask?.cancel()
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { WikiSearchIndex.build(indexes: indexes) }.value
            guard let self, !Task.isCancelled else { return }
            self.searchIndex = built
            self.indexBuilt = true
            self.runSearch()
        }
    }

    func closeSearch() {
        searchTask?.cancel()
        buildTask?.cancel()
        isSearching = false
        query = ""
        results = []
    }

    /// First Esc clears the field, the second closes search. The field and the root both
    /// receive Esc, so one key event is handled once.
    func escapeInSearch() {
        if let ts = NSApp.currentEvent?.timestamp {
            if ts == lastEscapeTimestamp { return }
            lastEscapeTimestamp = ts
        }
        switch WikiSearchEscape.action(query: query) {
        case .clearQuery: setQuery("")
        case .closeSearch: closeSearch()
        }
    }

    func setQuery(_ text: String) {
        guard text != query else { return }
        query = text
        searchTask?.cancel()
        if text.isEmpty {
            results = []
            selection = 0
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled else { return }
            self?.runSearch()
        }
    }

    func setSearchAll(_ all: Bool) {
        searchAll = all
        runSearch()
    }

    private func runSearch() {
        let scope: WikiSearchScope = searchAll ? .all : (project.map { .project($0.project) } ?? .all)
        results = searchIndex.search(query, scope: scope, preferredProject: project?.project)
        selection = 0
        if !query.isEmpty {
            let count = results.count
            let text = count == 1
                ? String(localized: "wiki.search.count.one", defaultValue: "1 result")
                : String(format: String(localized: "wiki.search.count.other", defaultValue: "%lld results"), count)
            AccessibilityNotification.Announcement(text).post()
        }
    }

    private var showsRecents: Bool { query.trimmingCharacters(in: .whitespaces).isEmpty }

    var searchState: WikiSearchState {
        WikiSearchState.resolve(query: query, resultCount: results.count, recentCount: recentPages.count + recentSearches.count,
                                indexIsEmpty: loaded && searchIndex.entries.isEmpty && indexBuilt)
    }

    func moveSelection(_ delta: Int) {
        let count = showsRecents ? recentPages.count + recentSearches.count : results.count
        selection = WikiSearchSelection.move(selection, by: delta, count: count)
    }

    func select(row: Int) { if results.indices.contains(row) { selection = row } }

    func openSelected() {
        if showsRecents {
            let rows = recentPages.map(WikiRecentRow.page) + recentSearches.map(WikiRecentRow.search)
            guard rows.indices.contains(selection) else { return }
            switch rows[selection] {
            case .page(let page): open(recent: page)
            case .search(let text): useRecentSearch(text)
            }
            return
        }
        guard results.indices.contains(selection) else { return }
        open(hit: results[selection])
    }

    func open(hit: WikiSearchHit) {
        let token = WikiSearchText.fold(query).split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
        recents.addSearch(query)
        openRecorded(path: hit.entry.path, title: hit.entry.title)
        highlightToken = token
    }

    func open(recent page: WikiRecents.Page) {
        guard FileManager.default.fileExists(atPath: page.path) else { return }
        openRecorded(path: page.path, title: page.title)
    }

    func useRecentSearch(_ text: String) {
        setQuery(text)
        selection = 0
    }

    func clearRecentSearches() {
        recents.clearSearches()
        recentSearches = []
    }

    private func openRecorded(path: String, title: String) {
        if let index = allIndexes.first(where: { i in i.pages.contains { i.pagePath(for: $0) == path } }) ?? general,
           !index.root.isEmpty {
            WikiOpeners.roots[WikiOpeners.key(path)] = index.root
        }
        closeSearch()
        push(path: path, title: title)
    }

    /// Scrolls to the first match of the searched word and flashes it. Runs after the page renders.
    private func applyHighlight() {
        guard let token = highlightToken, let webView = session.webView else { return }
        highlightToken = nil
        let quoted = (try? JSONSerialization.data(withJSONObject: [token]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        webView.evaluateJavaScript(WikiSearchHighlight.script(tokenJSONArray: quoted), completionHandler: nil)
    }

    private func title(forPath path: String) -> String? {
        for index in [project, general].compactMap({ $0 }) {
            if let page = index.pages.first(where: { index.pagePath(for: $0) == WikiOpeners.key(path) }) { return page.title }
        }
        return nil
    }
}

/// Entry points: the tab bar Wiki button, the shortcut, and the Architecture board's `openWiki` message.
@MainActor
final class WikiPopoverController: NSObject {
    static let shared = WikiPopoverController()

    private final class Popup {
        let session: TabBarPopoverSession
        let model: WikiPopoverModel
        let window: ObjectIdentifier
        var sizeObserver: AnyCancellable?
        init(session: TabBarPopoverSession, model: WikiPopoverModel, window: ObjectIdentifier) {
            self.session = session
            self.model = model
            self.window = window
        }
    }

    private var popups: [Popup] = []
    private var lastTransientCloseAt: CFTimeInterval = 0

    private func window(for workspace: Workspace) -> NSWindow? {
        workspace.owningTabManager.flatMap { AppDelegate.shared?.mainWindowContext(for: $0) }?.window
    }

    func isShowing(for workspace: Workspace) -> Bool {
        guard let window = window(for: workspace) else { return false }
        return popups.contains { $0.window == ObjectIdentifier(window) }
    }

    func close(for workspace: Workspace) {
        guard let window = window(for: workspace) else { return }
        popups.first { $0.window == ObjectIdentifier(window) }?.session.close()
    }

    func closeAllAttached() {
        for popup in popups where !popup.session.isDetached { popup.session.close() }
    }

    /// Closes the popover unless the user detached it into its own panel.
    func closeAttached(for workspace: Workspace) {
        guard let window = window(for: workspace) else { return }
        if let popup = popups.first(where: { $0.window == ObjectIdentifier(window) }), !popup.session.isDetached {
            popup.session.close()
        }
    }

    func toggle(from workspace: Workspace, openOnly: Bool = false) {
        guard let parent = window(for: workspace) else {
            NSSound.beep()
            return
        }
        if let popup = popups.first(where: { $0.window == ObjectIdentifier(parent) }) {
            if !openOnly { popup.session.close() }
            return
        }
        if !openOnly, let event = NSApp.currentEvent, [.leftMouseDown, .leftMouseUp].contains(event.type),
           CACurrentMediaTime() - lastTransientCloseAt < 0.3 {
            return
        }
        open(workspace: workspace, parent: parent, slug: nil)
    }

    /// Opens (or reuses) the popover on the page `slug`. Used by the Architecture board.
    func open(slug: String, from workspace: Workspace) {
        guard let parent = window(for: workspace) else { return }
        if let popup = popups.first(where: { $0.window == ObjectIdentifier(parent) }) {
            popup.model.load(openSlug: slug)
            return
        }
        open(workspace: workspace, parent: parent, slug: slug)
    }

    private func open(workspace: Workspace, parent: NSWindow, slug: String?) {
        // One overlay at a time; a detached popover stays where the user put it.
        BreeOverlays.closeOthers(than: .wiki)
        let model = WikiPopoverModel(workspace: workspace, root: ArchitectureViewModel.projectRoot(for: workspace.currentDirectory))
        guard let session = TabBarPopoverSession(
            workspace: workspace,
            parent: parent,
            slot: 2,
            sizeName: "wiki",
            preferredSize: { maxWidth, maxHeight in
                NSSize(width: min(560, max(maxWidth, 280)), height: min(520, max(maxHeight, 120)))
            },
            content: WikiPopoverView(model: model)
        ) else { return }
        let popup = Popup(session: session, model: model, window: ObjectIdentifier(parent))
        model.close = { [weak session] in session?.close() }
        // Esc: the search field first (clear, then leave search), then the popover itself.
        session.onEscape = { [weak model, weak session] in
            guard let model else { return }
            if model.isSearching { model.escapeInSearch() } else { session?.close() }
        }
        session.focusInitial = { [weak model] in model?.focusPage() }
        if let saved = WikiPopoverMemory.shared.stack(for: workspace.id) { model.restore(saved) }
        session.onWillClose = { [weak self] in self?.lastTransientCloseAt = CACurrentMediaTime() }
        session.onClosed = { [weak self, weak popup] in
            guard let self, let popup else { return }
            if let id = popup.model.workspace?.id { WikiPopoverMemory.shared.save(popup.model.snapshot(), for: id) }
            popup.model.session.close()
            self.popups.removeAll { $0 === popup }
            NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
        }
        // The topic list fits its content; a page or search uses the full size again.
        let applySize = { [weak model, weak session] in
            guard let model, let session else { return }
            let fits = model.stack.isEmpty && !model.isSearching && model.loaded && model.listHeight > 0
            session.setSurfaceSize(fits ? NSSize(width: 560, height: WikiPopoverSizing.homeHeight(content: model.listHeight)) : nil)
        }
        popup.sizeObserver = model.objectWillChange.sink { _ in DispatchQueue.main.async { applySize() } }
        popups.append(popup)
        model.load(openSlug: slug)
        session.show()
        NotificationCenter.default.post(name: .surfaceTabBarDynamicStateDidChange, object: nil)
    }
}

// MARK: - Views

struct WikiPopoverView: View {
    @ObservedObject var model: WikiPopoverModel
    @Environment(\.breePalette) private var palette
    @Environment(\.breeAccentColor) private var breeAccent

    var body: some View {
        VStack(spacing: 0) {
            if model.isSearching {
                WikiSearchHeader(model: model)
            } else {
                header
            }
            Divider()
            if model.isSearching {
                WikiSearchResultsView(model: model)
            } else if model.stack.isEmpty { list } else { page }
        }
        .background(palette.surfaceOverlay)
        .breeSurfaceColorScheme()
        .background(
            // ⌘F is local to this popover: it exists only while the popover's view is in the key window.
            Button("") { if !model.isSearching { model.startSearch() } }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 8) {
            if model.stack.isEmpty {
                Text(String(localized: "wiki.popover.title", defaultValue: "Wiki"))
                    .breeFont(.title)
                    .foregroundStyle(palette.textPrimary)
                Spacer(minLength: 0)
                if model.scopes.count > 1 {
                    Picker("", selection: Binding(get: { model.scope }, set: { model.select($0) })) {
                        Text(String(localized: "wiki.scope.project", defaultValue: "This project")).tag(WikiScope.project)
                        Text(String(localized: "wiki.scope.general", defaultValue: "General")).tag(WikiScope.general)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    .tint(breeAccent.selectedFillColor)
                }
                searchButton
            } else {
                WikiBackAndTitle(model: model, backTitle: model.stack.previousTitle ?? String(localized: "wiki.popover.title", defaultValue: "Wiki"))
                Spacer(minLength: 0)
                if model.canOpenInQuickView { quickViewButton }
                searchButton
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
    }

    private var quickViewButton: some View {
        Button { model.openInQuickView() } label: {
            Image(systemName: "arrow.up.forward.square")
                .accessibilityLabel(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
        }
        .buttonStyle(BreeIconButtonStyle())
        .accessibilityLabel(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
        .help(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View"))
    }

    private var searchButton: some View {
        Button { model.startSearch() } label: {
            Image(systemName: "magnifyingglass")
                .accessibilityLabel(String(localized: "wiki.search.button", defaultValue: "Search wiki"))
        }
        .buttonStyle(BreeIconButtonStyle())
        .accessibilityLabel(String(localized: "wiki.search.button", defaultValue: "Search wiki"))
        .help(String(localized: "wiki.search.button", defaultValue: "Search wiki"))
    }

    @ViewBuilder
    private var list: some View {
        if let index = model.listIndex, !index.pages.isEmpty {
            WikiListView(index: index, issues: model.issues, onHeight: { model.reportListHeight($0) }) { model.open($0, in: index) }
        } else if model.loaded {
            WikiEmptyState(issues: model.issues)
        }
    }

    private var page: some View {
        WikiPageView(model: model)
    }
}

/// The leading part of a page header on every wiki page and on the Architecture source overlay:
/// a chevron-only Back (the previous title is its tooltip and accessibility label), then the page title.
/// The title fades in once the page's own H1 has scrolled under the header.
struct WikiBackAndTitle: View {
    @ObservedObject var model: WikiPopoverModel
    let backTitle: String
    @Environment(\.breePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let backLabel = String(format: String(localized: "wiki.popover.backTo", defaultValue: "Back to %@"), backTitle)
        let shown = !model.headerTitle.isEmpty
        Button { model.back() } label: {
            Image(systemName: "chevron.left")
                .breeFont(.body, weight: .medium)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(backLabel)
        .keyboardShortcut("[", modifiers: .command)
        .accessibilityLabel(backLabel)
        Text(model.stack.current?.title ?? "")
            .breeFont(.body, weight: .medium)
            .foregroundStyle(palette.textPrimary)
            .lineLimit(1)
            .truncationMode(model.headerTooltip == nil ? .tail : .middle)
            .opacity(shown ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: shown)
            .accessibilityHidden(!shown)
            .help(model.headerTooltip ?? "")
    }
}

struct WikiPageView: View {
    @ObservedObject var model: WikiPopoverModel
    @Environment(\.breePalette) private var palette

    var body: some View {
        if let reason = model.unsupported { fallback(reason) } else { renderer }
    }

    private func fallback(_ reason: WikiFilePage.Reason) -> some View {
        VStack(spacing: 10) {
            Text(message(reason))
                .breeFont(.body)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
            if model.canOpenInQuickView {
                Button(String(localized: "wiki.file.quickView", defaultValue: "Open in Quick View")) { model.openInQuickView() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ reason: WikiFilePage.Reason) -> String {
        switch reason {
        case .tooLarge: String(localized: "wiki.file.tooLarge", defaultValue: "Too large to show here (over 2 MB).")
        case .binary: String(localized: "wiki.file.binary", defaultValue: "Binary file, not shown.")
        case .unreadable: String(localized: "wiki.file.unreadable", defaultValue: "This file can't be read.")
        case .forbidden: String(localized: "wiki.file.forbidden", defaultValue: "Raw captured text is never shown.")
        }
    }

    private var renderer: some View {
        let background = palette.ns.surfaceOverlay
        return MarkdownWebRenderer(
            markdown: model.markdown,
            theme: MarkdownWebTheme.resolve(backgroundColor: background),
            backgroundColor: background,
            isVisibleInUI: true,
            panelId: model.panelId,
            workspaceId: model.workspace?.id ?? model.panelId,
            filePath: model.stack.current?.path ?? "",
            fontSize: WikiFontSize.rendererSize(model.fontSize),
            fontFamily: MarkdownFontFamily.resolvedDefault(),
            maxContentWidth: MarkdownMaxWidthSettings.resolvedDefault(),
            session: model.session,
            onRequestPanelFocus: {},
            wikiLinkHandler: { [weak model] href, meta in model?.route(href: href, quickView: meta) },
            wikiStyle: true,
            onWikiScroll: { [weak model] y in model?.reportScroll(y) },
            onWikiHeading: { [weak model] visible in model?.reportHeading(visible: visible) },
            onWikiZoom: { [weak model] step in model?.zoom(step) }
        )
    }
}

/// Topic cards grouped by title. A click opens the page in place.
private struct WikiListView: View {
    let index: WikiIndex
    var issues: [WikiIssue] = []
    let onHeight: (CGFloat) -> Void
    let open: (WikiPage) -> Void
    @Environment(\.breePalette) private var palette

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(issues) { WikiIssueRow(issue: $0) }
                ForEach(Array(index.groups.enumerated()), id: \.offset) { _, group in
                    Text(group.title)
                        .breeFont(.title)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.top, 8)
                        .padding(.horizontal, 8)
                    ForEach(group.pages) { page in
                        WikiCard(page: page, isMissing: index.isMissing(page)) { open(page) }
                    }
                }
            }
            .padding(8)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: WikiListHeightKey.self, value: proxy.size.height)
            })
        }
        .onPreferenceChange(WikiListHeightKey.self) { onHeight($0) }
    }
}

/// An index.json that could not be used: the file and what is wrong with it.
private struct WikiIssueRow: View {
    let issue: WikiIssue
    @Environment(\.breePalette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(palette.signalAttention)
            Text(String(format: String(localized: "wiki.problem.row", defaultValue: "%@ — %@"),
                        (issue.path as NSString).abbreviatingWithTildeInPath, issue.message))
                .breeFont(.secondary)
                .foregroundStyle(palette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// No wiki for this project: what a wiki is for and how an agent creates one.
private struct WikiEmptyState: View {
    let issues: [WikiIssue]
    @Environment(\.breePalette) private var palette

    var body: some View {
        VStack(spacing: 10) {
            ForEach(issues) { WikiIssueRow(issue: $0) }
            Spacer(minLength: 0)
            Text(String(localized: "wiki.empty", defaultValue: "No wiki for this project"))
                .breeFont(.body, weight: .medium)
                .foregroundStyle(palette.textPrimary)
            Text(String(localized: "wiki.empty.purpose", defaultValue: "The wiki holds short pages your coding agent writes about this project: concepts, decisions, how things work."))
                .breeFont(.secondary)
                .foregroundStyle(palette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Text(String(localized: "wiki.empty.hint", defaultValue: "Ask your agent: bree guide wiki"))
                .breeFont(.secondary)
                .foregroundStyle(palette.textSecondary)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct WikiListHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct WikiCard: View {
    let page: WikiPage
    var isMissing = false
    let action: () -> Void
    @Environment(\.breePalette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(page.title)
                    .breeFont(.body, weight: .medium)
                    .foregroundStyle(palette.textPrimary)
                Text(page.oneLiner)
                    .breeFont(.secondary)
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Text(WikiTitle.shortDate(page.updated))
                        .breeFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
                    if isMissing {
                        Text(String(localized: "architecture.wiki.missing", defaultValue: "missing"))
                            .breeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    } else if page.isStale {
                        Text(String(localized: "architecture.wiki.stale", defaultValue: "stale"))
                            .breeFont(.caption)
                            .foregroundStyle(palette.textSecondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                    .fill(isHovering ? palette.hoverFill : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Search views

/// The header turned into a search field: magnifier, text, clear button, scope menu.
private struct WikiSearchHeader: View {
    @ObservedObject var model: WikiPopoverModel
    @Environment(\.breePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.textSecondary)
                TextField(
                    String(localized: "wiki.search.placeholder", defaultValue: "Search topics"),
                    text: Binding(get: { model.query }, set: { model.setQuery($0) })
                )
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(palette.textPrimary)
                .focused($focused)
                .onSubmit { model.openSelected() }
                .onKeyPress(.upArrow) { model.moveSelection(-1); return .handled }
                .onKeyPress(.downArrow) { model.moveSelection(1); return .handled }
                if !model.query.isEmpty {
                    Button { model.setQuery("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(palette.textSecondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: "wiki.search.clearField", defaultValue: "Clear search"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous).fill(palette.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous)
                    .strokeBorder(focused ? palette.focusRing : palette.separator, lineWidth: focused ? 2 : 1)
            )
            if model.project != nil {
                Menu {
                    Button(String(localized: "wiki.search.scope.all", defaultValue: "All")) { model.setSearchAll(true) }
                    Button(String(localized: "wiki.scope.project", defaultValue: "This project")) { model.setSearchAll(false) }
                } label: {
                    Text(model.searchAll
                         ? String(localized: "wiki.search.scope.all", defaultValue: "All")
                         : String(localized: "wiki.scope.project", defaultValue: "This project"))
                        .breeFont(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .transition(reduceMotion ? .identity : .opacity)
        // The field exists before the popover window is key on the very first frame; focus on the next turn.
        .onAppear { DispatchQueue.main.async { focused = true } }
    }
}

private struct WikiSearchResultsView: View {
    @ObservedObject var model: WikiPopoverModel
    @Environment(\.breePalette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            Text(String(localized: "wiki.search.footer", defaultValue: "↑↓ navigate · ↩ open · esc close"))
                .breeFont(.caption)
                .foregroundStyle(palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.searchState {
        case .recents:
            recents
        case .noRecentsHint:
            hint(String(localized: "wiki.search.hint", defaultValue: "Type to search topics and pages"))
        case .noTopics:
            hint(String(localized: "wiki.search.noTopics", defaultValue: "No topics yet"))
        case .noMatches:
            VStack(spacing: 10) {
                Text(String(format: String(localized: "wiki.search.noResults", defaultValue: "No topics match \"%@\""), model.query))
                    .breeFont(.body)
                    .foregroundStyle(palette.textSecondary)
                    .multilineTextAlignment(.center)
                if !model.searchAll {
                    Button(String(localized: "wiki.search.searchAll", defaultValue: "Search all topics")) {
                        model.setSearchAll(true)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .results:
            resultList
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .breeFont(.body)
            .foregroundStyle(palette.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let topicCount = model.results.prefix(while: { $0.kind.isTopic }).count
                    ForEach(Array(model.results.enumerated()), id: \.offset) { row, hit in
                        if row == 0 && topicCount > 0 { sectionTitle(WikiBrowse.topicsTitle(project: model.project, general: model.general) ?? String(localized: "wiki.search.topics", defaultValue: "Topics")) }
                        if row == topicCount { sectionTitle(String(localized: "wiki.search.inPages", defaultValue: "In pages")) }
                        WikiSearchRow(hit: hit, isSelected: row == model.selection) { model.open(hit: hit) }
                            .id(row)
                    }
                }
                .padding(8)
            }
            .onChange(of: model.selection) { _, row in proxy.scrollTo(row) }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .breeFont(.caption, weight: .medium)
            .foregroundStyle(palette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.top, 6)
    }

    private var recents: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if !model.recentPages.isEmpty {
                    sectionTitle(String(localized: "wiki.search.recentPages", defaultValue: "Recent"))
                    ForEach(Array(model.recentPages.enumerated()), id: \.offset) { row, page in
                        WikiRecentRowView(symbol: "doc.text", text: page.title, isSelected: model.selection == row) { model.open(recent: page) }
                    }
                }
                if !model.recentSearches.isEmpty {
                    HStack {
                        sectionTitle(String(localized: "wiki.search.recentSearches", defaultValue: "Recent searches"))
                        Spacer()
                        Button(String(localized: "wiki.search.clearRecents", defaultValue: "Clear")) { model.clearRecentSearches() }
                            .buttonStyle(.borderless)
                            .breeFont(.caption)
                            .padding(.horizontal, 8)
                    }
                    ForEach(Array(model.recentSearches.enumerated()), id: \.offset) { row, text in
                        WikiRecentRowView(symbol: "clock.arrow.circlepath", text: text,
                                          isSelected: model.selection == model.recentPages.count + row) { model.useRecentSearch(text) }
                    }
                }
            }
            .padding(8)
        }
    }
}

private struct WikiRecentRowView: View {
    let symbol: String
    let text: String
    var isSelected = false
    let action: () -> Void
    @Environment(\.breePalette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(palette.textSecondary).frame(width: 18)
                Text(text).breeFont(.body).foregroundStyle(palette.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? palette.selectedFill : (isHovering ? palette.hoverFill : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct WikiSearchRow: View {
    let hit: WikiSearchHit
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.breePalette) private var palette
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(hit.entry.title)
                        .breeFont(.body, weight: .medium)
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                    Text(hit.entry.project)
                        .breeFont(.caption)
                        .foregroundStyle(palette.textSecondary)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(palette.surfaceRaised))
                    Spacer(minLength: 0)
                    Text(WikiTitle.shortDate(hit.entry.updated))
                        .breeFont(.caption)
                        .monospacedDigit()
                        .foregroundStyle(palette.textSecondary)
                }
                Text(snippet)
                    .breeFont(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(minHeight: 56, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? palette.selectedFill : (isHovering ? palette.hoverFill : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    /// Muted snippet with the match in primary text, semibold.
    private var snippet: AttributedString {
        var text = AttributedString(hit.snippet.text)
        text.foregroundColor = palette.textSecondary
        if let range = hit.snippet.highlight {
            let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let end = text.index(start, offsetByCharacters: range.count)
            text[start..<end].foregroundColor = palette.textPrimary
            text[start..<end].inlinePresentationIntent = .stronglyEmphasized
        }
        return text
    }
}
