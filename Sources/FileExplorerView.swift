import AppKit
import Bonsplit
import Combine
import CmuxAppKitSupportUI
import CmuxFoundation
import CmuxWorkspaces
import CmuxSettings
import SwiftUI

#if DEBUG
private func fileExplorerDebugResponder(_ responder: NSResponder?) -> String {
    guard let responder else { return "nil" }
    return String(describing: type(of: responder))
}
#endif

// MARK: - File Explorer Panel (single NSViewRepresentable)

enum FileExplorerPanelPresentation: Equatable {
    case files
    case find

    var rightSidebarMode: RightSidebarMode {
        switch self {
        // Find merged into Files: both presentations are the Files mode.
        case .files, .find: return .files
        }
    }
}

enum FileExplorerPanelPlacement: Equatable {
    case rightSidebar
    case pane
}

/// The entire file explorer panel as one AppKit view hierarchy.
/// Contains the header bar (path + controls) and NSOutlineView, with no SwiftUI intermediaries.
struct FileExplorerPanelView: NSViewRepresentable {
    @ObservedObject var store: FileExplorerStore
    @ObservedObject var state: FileExplorerState
    let onOpenFilePreview: (String) -> Void
    var presentation: FileExplorerPanelPresentation = .files
    var placement: FileExplorerPanelPlacement = .rightSidebar
    var onFocus: (() -> Void)?
    var onContainerChange: ((FileExplorerContainerView?) -> Void)?
    @Environment(\.colorScheme) private var colorScheme

    func makeCoordinator() -> Coordinator {
        Coordinator(
            store: store,
            state: state,
            onOpenFilePreview: onOpenFilePreview,
            placement: placement,
            onFocus: onFocus,
            onContainerChange: onContainerChange
        )
    }

    func makeNSView(context: Context) -> FileExplorerContainerView {
        let container = FileExplorerContainerView(coordinator: context.coordinator, presentation: presentation)
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.containerView = container
        context.coordinator.onContainerChange?(container)
        return container
    }

    func updateNSView(_ container: FileExplorerContainerView, context: Context) {
        container.appearance = WindowAppearanceSnapshot.appKitAppearance(for: colorScheme)
        context.coordinator.store = store
        context.coordinator.state = state
        context.coordinator.onOpenFilePreview = onOpenFilePreview
        context.coordinator.placement = placement
        context.coordinator.onFocus = onFocus
        context.coordinator.onContainerChange = onContainerChange
        context.coordinator.onContainerChange?(container)
        container.updateShortcutPlacement(placement)
        container.updateHeader(store: store)
        container.updatePresentation(presentation)
        context.coordinator.reloadIfNeeded()
        container.registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    static func dismantleNSView(_ nsView: FileExplorerContainerView, coordinator: Coordinator) {
        // A native source is still allowed to own the container through its
        // matching `endedAt` callback. When no session was promoted, however,
        // clear any stale delegate marker so a dismantled search table does not
        // retain an obsolete native-session identity.
        nsView.clearNativeDragMarkersIfIdle()
        coordinator.onContainerChange?(nil)
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        var store: FileExplorerStore
        var state: FileExplorerState
        var onOpenFilePreview: (String) -> Void
        var placement: FileExplorerPanelPlacement
        var onFocus: (() -> Void)?
        var onContainerChange: ((FileExplorerContainerView?) -> Void)?
        weak var containerView: FileExplorerContainerView?
        weak var outlineView: NSOutlineView?
        private var lastRootNodeCount: Int = -1
        /// Folder rows last configured with a loading spinner (to refresh only rows whose spinner state changed).
        private var loadingRowPaths: Set<String> = []
        private var lastContentRevision: Int = -1
        private var observationCancellable: AnyCancellable?
        private var styleObserver: Any?
        private var isUpdatingOutlineProgrammatically = false
        private var needsReloadAfterContextMenu = false
        // Keep one coordinator-level record for the promoted native source.
        // The source view can be replaced during SwiftUI reconstruction, so
        // view-local markers alone cannot reclaim a lost endedAt callback.
        private weak var activeNativeDragSourceView: NSView?
        private weak var activeNativeDragWriter: FilePreviewDragPasteboardWriter?
        private var activeNativeDragSession: NSDraggingSession?
        private var activeNativeDragOwnerships: [FilePreviewNativeDragOwnership] = []
        private lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
            self?.previewWriterDidDeallocate(tokenID: tokenID)
        }

        init(
            store: FileExplorerStore,
            state: FileExplorerState,
            onOpenFilePreview: @escaping (String) -> Void,
            placement: FileExplorerPanelPlacement = .rightSidebar,
            onFocus: (() -> Void)? = nil,
            onContainerChange: ((FileExplorerContainerView?) -> Void)? = nil
        ) {
            self.store = store
            self.state = state
            self.onOpenFilePreview = onOpenFilePreview
            self.placement = placement
            self.onFocus = onFocus
            self.onContainerChange = onContainerChange
            super.init()
            observeStore()
            styleObserver = NotificationCenter.default.addObserver(
                forName: .fileExplorerStyleDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let outlineView = self.outlineView else { return }
                    let style = FileExplorerStyle.current
                    self.withProgrammaticOutlineUpdate {
                        outlineView.indentationPerLevel = style.indentation
                        outlineView.noteHeightOfRows(withIndexesChanged: IndexSet(0..<outlineView.numberOfRows))
                        outlineView.reloadData()
                        self.restoreExpansionState(self.store.expandedPaths, in: outlineView)
                        self.applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
                    }
                }
            }
        }

        @MainActor
        @discardableResult
        func handleModeShortcut(_ mode: RightSidebarMode, in window: NSWindow?) -> Bool {
            guard placement == .rightSidebar else { return false }
            _ = AppDelegate.shared?.focusRightSidebarInActiveMainWindow(
                mode: mode,
                focusFirstItem: true,
                preferredWindow: window
            )
            return true
        }

        @MainActor
        func noteKeyboardFocus(mode: RightSidebarMode, in window: NSWindow?) {
            switch placement {
            case .rightSidebar:
                guard let window else { return }
                AppDelegate.shared?.noteRightSidebarKeyboardFocusIntent(mode: mode, in: window)
            case .pane:
                onFocus?()
            }
        }

        deinit {
            if let observer = styleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        private func observeStore() {
            observationCancellable = store.objectWillChange
                .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.reloadIfNeeded()
                    }
                }
        }

        @MainActor
        func reloadIfNeeded() {
            guard let outlineView else { return }

            // Update empty state vs tree visibility
            containerView?.updateVisibility(
                hasContent: !store.rootPath.isEmpty,
                isLoading: store.isRootLoading,
                statusMessage: store.rootStatusMessage,
                showsRemoteTarget: store.provider is any RemoteFileExplorerProvider
            )

            // Reloading rows under an open context menu crashes AppKit's
            // highlight drawing (#12914). Catch up once the menu closes.
            if (outlineView as? FileExplorerNSOutlineView)?.isContextMenuOpen == true {
                needsReloadAfterContextMenu = true
                return
            }
            needsReloadAfterContextMenu = false

            let newCount = store.rootNodes.count
            let newContentRevision = store.contentRevision
            let structuralChanges = store.takePendingStructuralChanges()
            let gitChangedPaths = store.takePendingGitChangedPaths()
            withProgrammaticOutlineUpdate {
                if newContentRevision != lastContentRevision
                    || (structuralChanges.isEmpty && newCount != lastRootNodeCount) {
                    lastRootNodeCount = newCount
                    lastContentRevision = newContentRevision
                    let expandedPaths = store.expandedPaths
                    outlineView.reloadData()
                    restoreExpansionState(expandedPaths, in: outlineView)
                } else {
                    lastRootNodeCount = newCount
                    applyStructuralChanges(structuralChanges, in: outlineView)
                    refreshLoadedNodes(in: outlineView)
                    reloadRowsForGitStatus(gitChangedPaths, in: outlineView)
                }
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: false)
            }
        }

        /// Applies watcher diffs as row removes/inserts so untouched rows keep their cells,
        /// selection and scroll position.
        private func applyStructuralChanges(_ changes: [FileExplorerStructuralChange], in outlineView: NSOutlineView) {
            #if DEBUG
            if !changes.isEmpty { dlog("file.explorer.apply.structural changes=\(changes.count)") }
            #endif
            for change in changes {
                let parent: FileExplorerNode?
                if let parentPath = change.parentPath {
                    guard let node = store.nodesByPath[parentPath] else { continue }
                    parent = node
                    // Collapsed (or not yet shown) parents re-query the data source on expand.
                    guard outlineView.row(forItem: node) >= 0, outlineView.isItemExpanded(node) else {
                        if outlineView.row(forItem: node) >= 0 { outlineView.reloadItem(node, reloadChildren: true) }
                        continue
                    }
                } else {
                    parent = nil
                }
                // The diff only applies when the outline still mirrors the pre-change list.
                let expectedCount = outlineView.numberOfChildren(ofItem: parent) - change.removed.count + change.inserted.count
                let modelCount = parent.map { $0.children?.count ?? 0 } ?? store.rootNodes.count
                guard expectedCount == modelCount else {
                    if let parent { outlineView.reloadItem(parent, reloadChildren: true) } else { outlineView.reloadData() }
                    continue
                }
                if !change.removed.isEmpty {
                    outlineView.removeItems(at: change.removed, inParent: parent, withAnimation: [])
                }
                if !change.inserted.isEmpty {
                    outlineView.insertItems(at: change.inserted, inParent: parent, withAnimation: [])
                }
            }
            if !changes.isEmpty {
                // Inserted folders that were expanded before need their expansion restored.
                restoreExpansionState(store.expandedPaths, in: outlineView)
            }
        }

        private func reloadRowsForGitStatus(_ paths: Set<String>, in outlineView: NSOutlineView) {
            for path in paths {
                guard let node = store.nodesByPath[path], outlineView.row(forItem: node) >= 0 else { continue }
                outlineView.reloadItem(node, reloadChildren: false)
            }
        }

        @MainActor
        func contextMenuDidClose() {
            guard needsReloadAfterContextMenu else { return }
            // Let AppKit finish tearing down the menu highlight first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsReloadAfterContextMenu else { return }
                self.reloadIfNeeded()
            }
        }

        private func restoreExpansionState(_ expandedPaths: Set<String>, in outlineView: NSOutlineView) {
            // Expanding a row can reveal descendants, so re-read the row count each iteration.
            var row = 0
            while row < outlineView.numberOfRows {
                if let node = outlineView.item(atRow: row) as? FileExplorerNode,
                   expandedPaths.contains(node.path),
                   outlineView.isExpandable(node) {
                    outlineView.expandItem(node)
                }
                row += 1
            }
        }

        private func refreshLoadedNodes(in outlineView: NSOutlineView) {
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.isDirectory {
                    let isCurrentlyExpanded = outlineView.isItemExpanded(node)
                    let shouldBeExpanded = store.expandedPaths.contains(node.path)

                    if shouldBeExpanded && !isCurrentlyExpanded && node.children != nil {
                        outlineView.reloadItem(node, reloadChildren: true)
                        outlineView.expandItem(node)
                    } else if !shouldBeExpanded && isCurrentlyExpanded {
                        outlineView.collapseItem(node)
                    } else if let children = node.children {
                        // Only touch folders whose row count or loading spinner disagrees with the model.
                        let countMismatch = isCurrentlyExpanded && outlineView.numberOfChildren(ofItem: node) != children.count
                        let spinnerMismatch = loadingRowPaths.contains(node.path) != node.isLoading
                        if countMismatch {
                            outlineView.reloadItem(node, reloadChildren: true)
                            if shouldBeExpanded { outlineView.expandItem(node) }
                        } else if spinnerMismatch {
                            outlineView.reloadItem(node, reloadChildren: false)
                        }
                    }
                }
            }
        }

        // MARK: - NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            if item == nil {
                return store.rootNodes.count
            }
            guard let node = item as? FileExplorerNode else { return 0 }
            return node.sortedChildren?.count ?? 0
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if item == nil {
                return store.rootNodes[index]
            }
            guard let node = item as? FileExplorerNode,
                  let children = node.sortedChildren else {
                return FileExplorerNode(name: "", path: "", isDirectory: false)
            }
            return children[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            return node.isExpandable
        }

        // MARK: - NSOutlineViewDelegate

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let node = item as? FileExplorerNode else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileExplorerCell")
            let cellView: FileExplorerCellView
            if let existing = outlineView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerCellView {
                cellView = existing
            } else {
                cellView = FileExplorerCellView(identifier: identifier)
            }

            let gitStatus = store.gitStatusByPath[node.path]
            if node.isLoading { loadingRowPaths.insert(node.path) } else { loadingRowPaths.remove(node.path) }
            cellView.configure(with: node, gitStatus: gitStatus)
            cellView.onHover = { [weak self] isHovering in
                guard let self else { return }
                if isHovering {
                    self.store.prefetchChildren(for: node)
                } else {
                    self.store.cancelPrefetch(for: node)
                }
            }

            return cellView
        }

        func outlineView(_ outlineView: NSOutlineView, shouldExpandItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode, node.isDirectory else { return false }
            // Capture intent at the click: unloaded folders expand later, outside the event.
            if isUserToggle(in: outlineView) {
                store.breadcrumbOverridePath = node.path
                containerView?.updateHeader(store: store)
            }
            store.expand(node: node)
            return node.children != nil
        }

        func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
            guard let node = item as? FileExplorerNode else { return false }
            userCollapseBreadcrumb = isUserToggle(in: outlineView) ? store.breadcrumbPath(afterCollapsing: node.path) : nil
            store.collapse(node: node)
            // Set now too: DidCollapse re-applies after any selection fallout.
            if let target = userCollapseBreadcrumb {
                store.breadcrumbOverridePath = target
                containerView?.updateHeader(store: store)
            }
            return true
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isUpdatingOutlineProgrammatically,
                  let outlineView = notification.object as? NSOutlineView else {
                return
            }
            let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            guard !nodes.isEmpty else { store.select(node: nil); containerView?.updateHeader(store: store); return }
            let anchor = outlineView.selectedRow >= 0 ? outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode : nil
            store.select(nodes: nodes, anchor: anchor ?? nodes.first)
            containerView?.updateHeader(store: store)
        }
        /// User toggles arrive inside a mouse/key event on the outline view; programmatic
        /// expandItem/collapseItem calls (restore, hydrate, reload, search reveal) do not.
        private func isUserToggle(in outlineView: NSOutlineView) -> Bool {
            guard !isUpdatingOutlineProgrammatically, let event = NSApp.currentEvent,
                  event.window === outlineView.window else { return false }
            return [.leftMouseDown, .leftMouseUp, .keyDown].contains(event.type)
        }

        private var userCollapseBreadcrumb: String?

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            if !store.isExpanded(node) {
                store.expand(node: node)
            }
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard let node = notification.userInfo?["NSObject"] as? FileExplorerNode else { return }
            // Applied here, after AppKit's own selection fallout, which would clear the override.
            if let target = userCollapseBreadcrumb {
                userCollapseBreadcrumb = nil
                store.breadcrumbOverridePath = target
                containerView?.updateHeader(store: store)
            }
            if store.isExpanded(node) {
                store.collapse(node: node)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
            FileExplorerRowView()
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            FileExplorerStyle.current.rowHeight
        }

        // MARK: - Path-Owned Navigation

        func ensureSelection(in outlineView: NSOutlineView, fallbackToFirstVisible: Bool, scroll: Bool) {
            withProgrammaticOutlineUpdate {
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: fallbackToFirstVisible, scroll: scroll)
            }
        }

        func moveSelection(in outlineView: NSOutlineView, by delta: Int) {
            guard outlineView.numberOfRows > 0 else {
                store.select(node: nil)
                return
            }
            let currentRow = resolvedSelectionRow(in: outlineView) ?? (delta >= 0 ? -1 : outlineView.numberOfRows)
            let targetRow = min(max(currentRow + delta, 0), outlineView.numberOfRows - 1)
            selectRow(targetRow, in: outlineView, scroll: true)
        }

        func performDisclosureAction(
            _ action: RightSidebarKeyboardNavigation.DisclosureAction,
            in outlineView: NSOutlineView
        ) {
            switch action {
            case .collapse:
                collapseSelectedItemOrMoveToParent(in: outlineView)
            case .expand:
                expandSelectedItemOrMoveToChild(in: outlineView)
            }
        }

        func selectBestQuickSearchMatch(in outlineView: NSOutlineView, query: String) {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedQuery.isEmpty, outlineView.numberOfRows > 0 else { return }
            let lowerQuery = trimmedQuery.lowercased()
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.name.lowercased().contains(lowerQuery) {
                    selectRow(row, in: outlineView, scroll: true)
                    return
                }
            }
        }

        @MainActor func openSelectedItem(in outlineView: NSOutlineView) { openNode(in: outlineView, at: outlineView.selectedRow) }

        private func expandSelectedItemOrMoveToChild(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode,
                  node.isDirectory else {
                return
            }

            selectRow(row, in: outlineView, scroll: true)

            if !store.isExpanded(node) {
                outlineView.expandItem(node)
                applyStoredSelection(in: outlineView, fallbackToFirstVisible: false, scroll: true)
                return
            }

            guard node.children != nil else {
                store.requestDescendIntoFirstChild(of: node)
                return
            }

            if !outlineView.isItemExpanded(node) {
                outlineView.expandItem(node)
            }
            selectFirstChild(of: node, in: outlineView)
        }

        private func collapseSelectedItemOrMoveToParent(in outlineView: NSOutlineView) {
            guard let row = resolvedSelectionRow(in: outlineView),
                  let node = outlineView.item(atRow: row) as? FileExplorerNode else {
                return
            }

            if node.isDirectory, outlineView.isItemExpanded(node) || store.isExpanded(node) {
                if outlineView.isItemExpanded(node) {
                    outlineView.collapseItem(node)
                } else {
                    store.collapse(node: node)
                }
                selectRow(row, in: outlineView, scroll: true)
                return
            }

            selectParent(of: node, in: outlineView)
        }

        private func selectFirstChild(of node: FileExplorerNode, in outlineView: NSOutlineView) {
            let parentRow = outlineView.row(forItem: node)
            let childRow = parentRow + 1
            guard parentRow >= 0,
                  childRow < outlineView.numberOfRows,
                  let child = outlineView.item(atRow: childRow) as? FileExplorerNode,
                  (outlineView.parent(forItem: child) as? FileExplorerNode) === node else {
                return
            }
            selectRow(childRow, in: outlineView, scroll: true)
        }

        private func selectParent(of node: FileExplorerNode, in outlineView: NSOutlineView) {
            guard let parentNode = outlineView.parent(forItem: node) as? FileExplorerNode else {
                return
            }
            let parentRow = outlineView.row(forItem: parentNode)
            guard parentRow >= 0 else { return }
            selectRow(parentRow, in: outlineView, scroll: true)
        }

        private func applyStoredSelection(
            in outlineView: NSOutlineView,
            fallbackToFirstVisible: Bool,
            scroll: Bool
        ) {
            let exactRows = store.selectedPaths.reduce(into: IndexSet()) { if let resolution = selectionResolution(for: $1, in: outlineView), resolution.isExact { $0.insert(resolution.row) } }
            if !exactRows.isEmpty {
                withProgrammaticOutlineUpdate { outlineView.selectRowIndexes(exactRows, byExtendingSelection: false) }
                let anchorRow = store.selectedPath.flatMap { selectionResolution(for: $0, in: outlineView)?.row }
                if scroll, let row = FileExplorerSelectionRestoration.scrollRow(anchorRow: anchorRow, exactRows: exactRows) { outlineView.scrollRowToVisible(row) }; return
            }
            if let selectedPath = store.selectedPath,
               let resolution = selectionResolution(for: selectedPath, in: outlineView) {
                selectRow(
                    resolution.row,
                    in: outlineView,
                    scroll: scroll,
                    updateStore: resolution.isExact
                )
                return
            }
            guard fallbackToFirstVisible, outlineView.numberOfRows > 0 else { return }
            selectRow(0, in: outlineView, scroll: scroll)
        }

        func resolvedSelectionRow(in outlineView: NSOutlineView) -> Int? {
            if let selectedPath = store.selectedPath,
               let resolution = selectionResolution(for: selectedPath, in: outlineView) {
                return resolution.row
            }
            guard outlineView.selectedRow >= 0,
                  outlineView.selectedRow < outlineView.numberOfRows,
                  let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode else {
                return nil
            }
            store.select(node: node)
            return outlineView.selectedRow
        }

        private struct SelectionResolution {
            let row: Int
            let isExact: Bool
        }
        private func selectionResolution(for path: String, in outlineView: NSOutlineView) -> SelectionResolution? {
            var bestAncestor: (row: Int, pathLength: Int)?
            for row in 0..<outlineView.numberOfRows {
                guard let node = outlineView.item(atRow: row) as? FileExplorerNode else { continue }
                if node.path == path {
                    return SelectionResolution(row: row, isExact: true)
                }
                if Self.path(node.path, isAncestorOf: path) {
                    let length = node.path.count
                    if bestAncestor == nil || length > bestAncestor!.pathLength {
                        bestAncestor = (row, length)
                    }
                }
            }
            guard let bestAncestor else { return nil }
            return SelectionResolution(row: bestAncestor.row, isExact: false)
        }

        private func selectRow(
            _ row: Int,
            in outlineView: NSOutlineView,
            scroll: Bool,
            updateStore: Bool = true
        ) {
            guard row >= 0, row < outlineView.numberOfRows else { return }
            let node = outlineView.item(atRow: row) as? FileExplorerNode
            withProgrammaticOutlineUpdate {
                if updateStore {
                    store.select(node: node)
                }
                outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                if scroll {
                    outlineView.scrollRowToVisible(row)
                }
            }
        }

        private func withProgrammaticOutlineUpdate(_ body: () -> Void) {
            let wasUpdating = isUpdatingOutlineProgrammatically
            isUpdatingOutlineProgrammatically = true
            defer { isUpdatingOutlineProgrammatically = wasUpdating }
            body()
        }

        private static func path(_ ancestor: String, isAncestorOf descendant: String) -> Bool {
            guard ancestor != descendant else { return false }
            if ancestor == "/" {
                return descendant.hasPrefix("/")
            }
            return descendant.hasPrefix(ancestor + "/")
        }

        /// Applies the shared native-generation fence used by both file
        /// preview drag sources. A distinct `willBeginAt` session is an
        /// authoritative boundary and replaces the prior owner.
        func supersedeNativeDragIfNeeded(
            previousSession: NSDraggingSession?,
            newSession: NSDraggingSession,
            finishPrevious: () -> Void,
            clearPrevious: () -> Void
        ) {
            guard let previousSession, previousSession !== newSession else { return }
            // A distinct `willBeginAt` callback is itself an AppKit native
            // boundary. Sequence numbers are useful for terminal fencing but
            // cannot reject this promotion because the OS may reuse them.
            finishPrevious()
            clearPrevious()
        }

        fileprivate func trackNativeDrag(
            sourceView: NSView,
            session: NSDraggingSession,
            writer: FilePreviewDragPasteboardWriter?,
            ownerships: [FilePreviewNativeDragOwnership]
        ) {
            activeNativeDragSourceView = sourceView
            activeNativeDragWriter = writer
            activeNativeDragSession = session
            activeNativeDragOwnerships = ownerships
        }

        private func clearTrackedSourceState() {
            if let outlineView = activeNativeDragSourceView as? FileExplorerNSOutlineView {
                outlineView.activeNativeDragDelegateMarker = nil
                outlineView.activeNativeDragWriter?.releaseSourceGraph()
                outlineView.activeNativeDragWriter = nil
                outlineView.activeNativeDragOwnerships = []
                outlineView.activeNativeDragSession = nil
            } else if let searchResultsView = activeNativeDragSourceView as? FileExplorerSearchResultsTableView {
                searchResultsView.activeNativeDragDelegateMarker = nil
                searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
                searchResultsView.activeNativeDragWriter = nil
                searchResultsView.activeNativeDragOwnerships = []
                searchResultsView.activeNativeDragSession = nil
            }
        }

        /// Reclaims the promoted source even when its original view is no
        /// longer the coordinator's current representable.
        @discardableResult
        fileprivate func reclaimTrackedNativeDrag() -> Bool {
            guard let session = activeNativeDragSession else { return false }
            if activeNativeDragOwnerships.isEmpty {
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            } else {
                for ownership in activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            }
            let writer = activeNativeDragWriter
            clearTrackedSourceState()
            writer?.releaseSourceGraph()
            activeNativeDragSourceView = nil
            activeNativeDragWriter = nil
            activeNativeDragSession = nil
            activeNativeDragOwnerships = []
            return true
        }

        fileprivate func isTrackingNativeDrag(_ session: NSDraggingSession) -> Bool {
            activeNativeDragSession === session
        }

        fileprivate func forgetTrackedNativeDrag(matching session: NSDraggingSession) {
            guard activeNativeDragSession === session else { return }
            activeNativeDragSourceView = nil
            activeNativeDragWriter = nil
            activeNativeDragSession = nil
            activeNativeDragOwnerships = []
        }

        private func previewWriterDidDeallocate(tokenID: UUID) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView,
                  outlineView.pendingNativeDragTokenID == tokenID else { return }
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
        }

        // MARK: - Drag-to-Preview

        func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> (any NSPasteboardWriting)? {
            guard let node = item as? FileExplorerNode, !node.isDirectory else { return nil }
            guard store.provider is LocalFileExplorerProvider else { return nil }
            let writer = FilePreviewDragPasteboardWriter(
                filePath: node.path,
                displayTitle: node.name,
                nativeSourceView: outlineView,
                // Retain the exact container/delegate graph through a
                // representable rebuild; the coordinator's container edge is
                // intentionally weak.
                nativeSourceOwner: containerView ?? outlineView,
                provisionalToken: pendingPreviewDrag.makeToken()
            )
            if let outlineView = outlineView as? FileExplorerNSOutlineView {
                outlineView.pendingNativeDragWriter = writer
                pendingPreviewDrag.register(writer)
                outlineView.pendingNativeDragTokenID = writer.provisionalToken?.id
            }
            return writer
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            willBeginAt screenPoint: NSPoint,
            forItems draggedItems: [Any]
        ) {
            _ = screenPoint
            _ = draggedItems
            if let outlineView = outlineView as? FileExplorerNSOutlineView {
                if outlineView.activeNativeDragSession === session {
                    return
                }
                if activeNativeDragSession === session {
                    return
                }
                // A distinct begin is a native boundary, even when the prior
                // source belonged to a rebuilt outline view.
                _ = reclaimTrackedNativeDrag()
                let fallbackWriter = outlineView.pendingNativeDragWriter
                var promotedWriters = pendingPreviewDrag.writers(for: outlineView)
                if let fallbackWriter,
                   !promotedWriters.contains(where: { $0 === fallbackWriter }) {
                    promotedWriters.append(fallbackWriter)
                }
                pendingPreviewDrag.finishPending(preserving: promotedWriters)
                supersedeNativeDragIfNeeded(
                    previousSession: outlineView.activeNativeDragSession,
                    newSession: session,
                    finishPrevious: {
                        let pasteboard = outlineView.activeNativeDragSession?.draggingPasteboard
                            ?? session.draggingPasteboard
                        for ownership in outlineView.activeNativeDragOwnerships {
                            ownership.finish(from: pasteboard)
                        }
                    },
                    clearPrevious: {
                        outlineView.activeNativeDragWriter?.releaseSourceGraph()
                        outlineView.activeNativeDragWriter = nil
                        outlineView.activeNativeDragDelegateMarker = nil
                        outlineView.activeNativeDragOwnerships = []
                        outlineView.activeNativeDragOwnership = nil
                        outlineView.activeNativeDragSession = nil
                    }
                )
                // The ordered list mirrors AppKit's pasteboard item order; use
                // its first writer as the canonical source identity.
                let promotedWriter = promotedWriters.first ?? fallbackWriter
                let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
                promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
                let ownerships = promotedOwnerships.isEmpty
                    ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
                    : promotedOwnerships
                outlineView.activeNativeDragDelegateMarker = self
                outlineView.activeNativeDragSession = session
                outlineView.activeNativeDragWriter = promotedWriter
                outlineView.activeNativeDragOwnerships = ownerships
                outlineView.pendingNativeDragWriter = nil
                outlineView.pendingNativeDragTokenID = nil
                trackNativeDrag(
                    sourceView: outlineView,
                    session: session,
                    writer: promotedWriter,
                    ownerships: ownerships
                )
            }
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            draggingSession session: NSDraggingSession,
            endedAt screenPoint: NSPoint,
            operation: NSDragOperation
        ) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView,
                  outlineView.activeNativeDragSession === session else {
                // The delegate may have been rebuilt between writer creation
                // and the terminal callback. Use this session's own pasteboard
                // for idempotent capability cleanup; never inspect the
                // process-wide board here.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
                return
            }
            if !outlineView.activeNativeDragOwnerships.isEmpty {
                for ownership in outlineView.activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            } else {
                // The matching session identity proves this is not a stale
                // callback. Keep a compatibility fallback for an AppKit path
                // that released the plain writer before promotion.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            }
            outlineView.activeNativeDragDelegateMarker = nil
            outlineView.activeNativeDragWriter?.releaseSourceGraph()
            outlineView.activeNativeDragWriter = nil
            outlineView.activeNativeDragOwnerships = []
            outlineView.activeNativeDragOwnership = nil
            outlineView.activeNativeDragSession = nil
            forgetTrackedNativeDrag(matching: session)
        }

        /// Reclaims an outline drag at the next pointer boundary when AppKit
        /// omitted its native terminal callback during reconstruction. The
        /// exact outline argument matters because ``Coordinator.outlineView``
        /// may already point at a newly built view.
        func prepareForNativeDragBoundary(on outlineView: NSOutlineView) {
            guard let outlineView = outlineView as? FileExplorerNSOutlineView else { return }
            if reclaimTrackedNativeDrag() {
                // The tracked source may be an older outline retained by the
                // writer. Clear only this view's pending request; its active
                // state, if any, belongs to a separate generation.
                pendingPreviewDrag.finishPending()
                outlineView.pendingNativeDragWriter = nil
                outlineView.pendingNativeDragTokenID = nil
                return
            }
            guard let session = outlineView.activeNativeDragSession else {
                outlineView.activeNativeDragDelegateMarker = nil
                pendingPreviewDrag.finishPending()
                outlineView.pendingNativeDragWriter = nil
                if let tokenID = outlineView.pendingNativeDragTokenID {
                    pendingPreviewDrag.remove(tokenID: tokenID)
                }
                outlineView.pendingNativeDragTokenID = nil
                outlineView.activeNativeDragOwnership = nil
                return
            }
            for ownership in outlineView.activeNativeDragOwnerships {
                ownership.finish(from: session.draggingPasteboard)
            }
            pendingPreviewDrag.finishPending()
            outlineView.activeNativeDragDelegateMarker = nil
            outlineView.pendingNativeDragWriter = nil
            outlineView.pendingNativeDragTokenID = nil
            outlineView.activeNativeDragWriter?.releaseSourceGraph()
            outlineView.activeNativeDragWriter = nil
            outlineView.activeNativeDragOwnerships = []
            outlineView.activeNativeDragOwnership = nil
            outlineView.activeNativeDragSession = nil
        }

        /// The workspace this explorer currently shows (local or remote).
        var currentWorkspace: Workspace? {
            store.workspaceRootIdentity.flatMap { AppDelegate.shared?.workspaceFor(tabId: $0) }
        }

        /// Opens `path` as a persistent center tab (same result as Quick View Pin).
        func openAsTab(_ path: String) {
            guard let workspace = currentWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else {
                onOpenFilePreview(path)
                return
            }
            QuickViewWindowController.shared.close(ifOwnedBy: workspace)
            _ = workspace.openFileSurfaces(inPane: paneId, filePaths: [path], focus: true, reuseExisting: true)
        }

        /// Single click on a local file shows it in the Quick View; Cmd+Option+click opens a
        /// new Quick View window; folders and other modified clicks (multi-select) keep plain selection.
        @MainActor
        @objc func handleSingleClick(_ sender: NSOutlineView) {
            let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]) ?? []
            if modifiers == [.command, .option], store.provider is LocalFileExplorerProvider,
               sender.clickedRow >= 0, let workspace = currentWorkspace,
               let node = sender.item(atRow: sender.clickedRow) as? FileExplorerNode, !node.isDirectory,
               node.resourceContextID == nil || node.resourceContextID == store.resourceContextID {
                QuickViewResource.file(path: node.path).open(from: workspace, newWindow: true)
                return
            }
            guard store.provider is LocalFileExplorerProvider,
                  NSApp.currentEvent?.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty ?? true,
                  sender.clickedRow >= 0, sender.selectedRowIndexes.count == 1,
                  let node = sender.item(atRow: sender.clickedRow) as? FileExplorerNode,
                  !node.isDirectory,
                  node.resourceContextID == nil || node.resourceContextID == store.resourceContextID else { return }
            onOpenFilePreview(node.path)
        }

        @MainActor
        @objc func handleDoubleClick(_ sender: NSOutlineView) {
            let row = sender.clickedRow >= 0 ? sender.clickedRow : sender.selectedRow
            openNode(in: sender, at: row)
        }

        // MARK: - Context Menu (NSMenuDelegate)

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            defer {
                if !menu.items.isEmpty { menu.addItem(.separator()) }
                let hiddenItem = NSMenuItem(
                    title: String(localized: "fileExplorer.contextMenu.showHiddenFiles", defaultValue: "Show Hidden Files"),
                    action: #selector(contextMenuToggleHiddenFiles(_:)),
                    keyEquivalent: ""
                )
                hiddenItem.target = self
                hiddenItem.state = store.showHiddenFiles ? .on : .off
                menu.addItem(hiddenItem)
            }
            guard let outlineView else { return }
            let clickedRow = outlineView.clickedRow
            guard clickedRow >= 0,
                  let node = outlineView.item(atRow: clickedRow) as? FileExplorerNode else { return }

            let isLocal = store.provider is LocalFileExplorerProvider

            if !node.isDirectory && isLocal {
                FileExplorerExternalOpenMenuItems(
                    fileURL: URL(fileURLWithPath: node.path),
                    target: self,
                    action: #selector(contextMenuOpenExternally(_:))
                ).add(to: menu)
            }

            if isLocal {
                let revealItem = NSMenuItem(
                    title: FileExternalOpenText.revealInFinder,
                    action: #selector(contextMenuRevealInFinder(_:)),
                    keyEquivalent: ""
                )
                revealItem.target = self
                revealItem.representedObject = node
                menu.addItem(revealItem)

                if node.isDirectory {
                    let gridItem = NSMenuItem(
                        title: String(localized: "fileExplorer.contextMenu.showImagesAsGrid", defaultValue: "Show Images as Grid"),
                        action: #selector(contextMenuShowImagesAsGrid(_:)),
                        keyEquivalent: ""
                    )
                    gridItem.target = self
                    gridItem.representedObject = node
                    menu.addItem(gridItem)
                }

                menu.addItem(.separator())
            }

            menu.addFileExplorerInsertPathItems(target: self, representedObject: node, insertAction: #selector(contextMenuInsertPath(_:)), insertRelativeAction: #selector(contextMenuInsertRelativePath(_:)))

            let copyPathItem = NSMenuItem(
                title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
                action: #selector(contextMenuCopyPath(_:)),
                keyEquivalent: ""
            )
            copyPathItem.target = self
            copyPathItem.representedObject = node
            menu.addItem(copyPathItem)

            let copyRelItem = NSMenuItem(
                title: String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
                action: #selector(contextMenuCopyRelativePath(_:)),
                keyEquivalent: ""
            )
            copyRelItem.target = self
            copyRelItem.representedObject = node
            menu.addItem(copyRelItem)

            if isLocal, !node.isDirectory, let root = pinnedProjectRoot,
               PinnedFilesStore.relativePath(for: node.path, root: root) != nil {
                let pinned = PinnedFilesStore().isPinned(path: node.path, root: root)
                let pinItem = NSMenuItem(
                    title: pinned
                        ? String(localized: "fileExplorer.contextMenu.unpin", defaultValue: "Unpin")
                        : String(localized: "fileExplorer.contextMenu.pin", defaultValue: "Pin"),
                    action: #selector(contextMenuTogglePin(_:)),
                    keyEquivalent: ""
                )
                pinItem.target = self
                pinItem.representedObject = node
                menu.addItem(pinItem)
            }

            // File operations are local-only; the remote explorer providers have no write API.
            guard isLocal else { return }
            let targets = outlineView.selectedRowIndexes.contains(clickedRow)
                ? outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
                : [node]
            func add(_ title: String, _ action: Selector, _ object: Any?) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.representedObject = object
                menu.addItem(item)
            }
            menu.addItem(.separator())
            add(String(localized: "fileExplorer.contextMenu.openTerminalHere", defaultValue: "Open Terminal Here"),
                #selector(contextMenuOpenTerminalHere(_:)), node)
            if node.isDirectory {
                add(String(localized: "fileExplorer.contextMenu.setAsRoot", defaultValue: "Set as Files Root"),
                    #selector(contextMenuSetAsRoot(_:)), node)
            }
            if store.isRootOverridden {
                add(String(localized: "fileExplorer.contextMenu.resetRoot", defaultValue: "Reset Files Root"),
                    #selector(contextMenuResetRoot(_:)), nil)
            }
            menu.addItem(.separator())
            if targets.count == 1 {
                add(String(localized: "fileExplorer.contextMenu.rename", defaultValue: "Rename…"),
                    #selector(contextMenuRename(_:)), node)
            }
            add(String(localized: "fileExplorer.contextMenu.copy", defaultValue: "Copy"),
                #selector(contextMenuCopy(_:)), targets)
            if pasteboardHasFileURLs() {
                add(String(localized: "fileExplorer.contextMenu.paste", defaultValue: "Paste"),
                    #selector(contextMenuPaste(_:)), node)
            }
            add(String(localized: "fileExplorer.contextMenu.duplicate", defaultValue: "Duplicate"),
                #selector(contextMenuDuplicate(_:)), targets)
            add(String(localized: "fileExplorer.contextMenu.moveTo", defaultValue: "Move To…"),
                #selector(contextMenuMoveTo(_:)), targets)
            add(String(localized: "fileExplorer.contextMenu.moveToTrash", defaultValue: "Move to Trash"),
                #selector(contextMenuMoveToTrash(_:)), targets)
        }

        /// The project the explorer's workspace belongs to, for pins; nil for
        /// remote providers or when no directory is known.
        var pinnedProjectRoot: String? {
            guard store.provider is LocalFileExplorerProvider else { return nil }
            let directory = currentWorkspace?.currentDirectory ?? store.rootPath
            return directory.isEmpty ? nil : PinnedFilesStore.projectRoot(forDirectory: directory)
        }

        @objc private func contextMenuTogglePin(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode,
                  let root = pinnedProjectRoot else { return }
            let pins = PinnedFilesStore()
            if pins.isPinned(path: node.path, root: root) {
                pins.unpin(path: node.path, root: root)
            } else {
                pins.pin(path: node.path, root: root)
            }
        }

        @objc private func contextMenuToggleHiddenFiles(_ sender: NSMenuItem) {
            store.toggleShowHiddenFiles()
        }

        @objc private func contextMenuOpenTerminalHere(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode, let workspace = currentWorkspace,
                  let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first else { return }
            let directory = node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
            _ = workspace.newTerminalSurface(inPane: paneId, focus: true, workingDirectory: directory)
        }

        @objc private func contextMenuSetAsRoot(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode, node.isDirectory else { return }
            store.setRootPath(node.path)
        }

        @objc private func contextMenuResetRoot(_ sender: NSMenuItem) {
            store.resetRootToWorkspace()
        }

        @objc private func contextMenuRename(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            let alert = NSAlert()
            alert.messageText = String(localized: "fileExplorer.rename.title", defaultValue: "Rename")
            alert.informativeText = String(
                format: String(localized: "fileExplorer.rename.message", defaultValue: "Enter a new name for \"%@\"."),
                node.name
            )
            alert.addButton(withTitle: String(localized: "fileExplorer.rename.title", defaultValue: "Rename"))
            alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
            let field = NSTextField(string: node.name)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            guard alert.runCmuxModal(presentingWindow: outlineView?.window) == .alertFirstButtonReturn else { return }
            do {
                let target = try FileExplorerFileOperations.renameTarget(oldPath: node.path, newName: field.stringValue)
                guard target != node.path else { return }
                try FileManager.default.moveItem(atPath: node.path, toPath: target)
                store.selectPath(target)
                store.reload()
            } catch {
                presentFileOperationError(error)
            }
        }

        @objc private func contextMenuDuplicate(_ sender: NSMenuItem) {
            guard let nodes = sender.representedObject as? [FileExplorerNode] else { return }
            var created: [String] = []
            defer {
                store.selectPaths(created)
                store.reload()
            }
            for node in nodes {
                do { created.append(try FileExplorerFileOperations.duplicate(path: node.path, isDirectory: node.isDirectory)) } catch {
                    presentFileOperationError(error)
                    return
                }
            }
        }

        // MARK: Copy / Paste / Move

        private func pasteboardHasFileURLs() -> Bool {
            NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
        }

        /// The folder a paste or move lands in: a directory node itself, a file's parent, or the root.
        private func destinationFolder(for node: FileExplorerNode?) -> String {
            guard let node else { return store.rootPath }
            return node.isDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
        }

        /// Writes the selected rows as file URLs, so Finder and other apps can paste them.
        func copySelection(in outlineView: NSOutlineView) {
            guard store.provider is LocalFileExplorerProvider else { return }
            let nodes = outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            writeToPasteboard(nodes)
        }

        private func writeToPasteboard(_ nodes: [FileExplorerNode]) {
            guard !nodes.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(nodes.map { URL(fileURLWithPath: $0.path) as NSURL })
        }

        /// Pastes pasteboard file URLs into the selected folder (or the selected file's folder).
        func pasteIntoSelection(in outlineView: NSOutlineView) {
            guard store.provider is LocalFileExplorerProvider else { return }
            let selected = outlineView.selectedRowIndexes.first.flatMap { outlineView.item(atRow: $0) as? FileExplorerNode }
            paste(into: destinationFolder(for: selected))
        }

        var canPasteFiles: Bool {
            store.provider is LocalFileExplorerProvider && pasteboardHasFileURLs()
        }

        private func paste(into folder: String) {
            let urls = NSPasteboard.general.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
            ) as? [URL] ?? []
            guard !urls.isEmpty else { return }
            do {
                let created = try FileExplorerFileOperations.paste(sources: urls.map(\.path), intoFolder: folder)
                store.selectPaths(created)
                store.reload()
            } catch {
                presentFileOperationError(error)
                store.reload()
            }
        }

        @objc private func contextMenuCopy(_ sender: NSMenuItem) {
            guard let nodes = sender.representedObject as? [FileExplorerNode] else { return }
            writeToPasteboard(nodes)
        }

        @objc private func contextMenuPaste(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            paste(into: destinationFolder(for: node))
        }

        @objc private func contextMenuMoveTo(_ sender: NSMenuItem) {
            guard let nodes = sender.representedObject as? [FileExplorerNode], let first = nodes.first else { return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = String(localized: "fileExplorer.move.button", defaultValue: "Move")
            panel.directoryURL = URL(fileURLWithPath: (first.path as NSString).deletingLastPathComponent)
            let paths = nodes.map(\.path)
            let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard response == .OK, let folder = panel.url?.path else { return }
                self?.move(paths: paths, into: folder)
            }
            if let window = outlineView?.window {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                completion(panel.runModal())
            }
        }

        /// Moves items into `folder`. Same-volume moves register an undo; cross-volume moves
        /// (copy + delete) ask first and are not undoable.
        private func move(paths: [String], into folder: String) {
            let crossVolume = paths.contains { FileExplorerFileOperations.crossesVolume(source: $0, folder: folder) }
            if crossVolume {
                let alert = NSAlert()
                alert.messageText = String(localized: "fileExplorer.move.crossVolume.title", defaultValue: "Move to another volume?")
                alert.informativeText = String(
                    localized: "fileExplorer.move.crossVolume.info",
                    defaultValue: "The items are copied to the other volume and the originals are deleted. This can't be undone."
                )
                alert.addButton(withTitle: String(localized: "fileExplorer.move.button", defaultValue: "Move"))
                alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
                guard alert.runCmuxModal(presentingWindow: outlineView?.window) == .alertFirstButtonReturn else { return }
            }
            do {
                let moved = try FileExplorerFileOperations.move(sources: paths, intoFolder: folder)
                if !crossVolume { registerMoveUndo(moved) }
                store.selectPaths(moved.map(\.to))
            } catch {
                presentFileOperationError(error)
            }
            store.reload()
        }

        private func registerMoveUndo(_ moved: [(from: String, to: String)]) {
            guard !moved.isEmpty, let undoManager = outlineView?.undoManager else { return }
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated { target.reverseMove(moved) }
            }
            undoManager.setActionName(String(localized: "fileExplorer.move.button", defaultValue: "Move"))
        }

        /// Moves each item back to where it came from; registers the inverse so redo works.
        private func reverseMove(_ moved: [(from: String, to: String)]) {
            var restored: [(from: String, to: String)] = []
            for pair in moved.reversed() where !FileManager.default.fileExists(atPath: pair.from) {
                do {
                    try FileManager.default.moveItem(atPath: pair.to, toPath: pair.from)
                    restored.append((from: pair.to, to: pair.from))
                } catch {
                    presentFileOperationError(error)
                    break
                }
            }
            registerMoveUndo(restored)
            store.selectPaths(restored.map(\.to))
            store.reload()
        }

        // MARK: Drag-to-move

        func outlineView(
            _ outlineView: NSOutlineView,
            validateDrop info: NSDraggingInfo,
            proposedItem item: Any?,
            proposedChildIndex index: Int
        ) -> NSDragOperation {
            guard store.provider is LocalFileExplorerProvider,
                  info.draggingSource as? NSOutlineView === outlineView,
                  let folder = item as? FileExplorerNode, folder.isDirectory else { return [] }
            outlineView.setDropItem(folder, dropChildIndex: NSOutlineViewDropOnItemIndex)
            return .move
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            acceptDrop info: NSDraggingInfo,
            item: Any?,
            childIndex index: Int
        ) -> Bool {
            guard let folder = item as? FileExplorerNode, folder.isDirectory,
                  let urls = info.draggingPasteboard.readObjects(
                      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
                  ) as? [URL], !urls.isEmpty else { return false }
            move(paths: urls.map(\.path), into: folder.path)
            return true
        }

        @objc private func contextMenuMoveToTrash(_ sender: NSMenuItem) {
            guard let nodes = sender.representedObject as? [FileExplorerNode] else { return }
            moveToTrash(nodes)
        }

        /// Cmd+Backspace: trashes the selected rows of a local tree.
        func trashSelection(in outlineView: NSOutlineView) {
            guard store.provider is LocalFileExplorerProvider else { return }
            moveToTrash(outlineView.selectedRowIndexes.compactMap { outlineView.item(atRow: $0) as? FileExplorerNode })
        }

        /// Asks first for folders or multiple items; the Finder Trash keeps it undoable.
        private func moveToTrash(_ nodes: [FileExplorerNode]) {
            guard let first = nodes.first else { return }
            if nodes.count > 1 || first.isDirectory {
                let alert = NSAlert()
                alert.messageText = nodes.count > 1
                    ? String(format: String(localized: "fileExplorer.trash.confirm.multiple", defaultValue: "Move %d items to the Trash?"), nodes.count)
                    : String(format: String(localized: "fileExplorer.trash.confirm.single", defaultValue: "Move \"%@\" to the Trash?"), first.name)
                alert.informativeText = String(localized: "fileExplorer.trash.confirm.info", defaultValue: "You can restore it from the Trash.")
                alert.addButton(withTitle: String(localized: "fileExplorer.contextMenu.moveToTrash", defaultValue: "Move to Trash"))
                alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
                guard alert.runCmuxModal(presentingWindow: outlineView?.window) == .alertFirstButtonReturn else { return }
            }
            defer { store.reload() }
            for node in nodes {
                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: node.path), resultingItemURL: nil) } catch {
                    presentFileOperationError(error)
                    return
                }
            }
        }

        private func presentFileOperationError(_ error: Error) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = String(localized: "fileExplorer.error.title", defaultValue: "The action couldn't be completed")
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: String(localized: "common.ok", defaultValue: "OK"))
            _ = alert.runCmuxModal(presentingWindow: outlineView?.window)
        }

        @objc private func contextMenuOpenExternally(_ sender: NSMenuItem) {
            guard let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
            FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
        }

        @objc private func contextMenuRevealInFinder(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            FileExternalOpenAction.revealInFinder(fileURL: URL(fileURLWithPath: node.path))
        }

        @objc private func contextMenuShowImagesAsGrid(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode, node.isDirectory,
                  let workspace = currentWorkspace else { return }
            QuickViewResource.folder(path: node.path).open(from: workspace)
        }

        @objc private func contextMenuCopyPath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            GhosttyApp.terminalPasteboard.writeString(
                node.path,
                to: .general
            )
        }

        @objc private func contextMenuCopyRelativePath(_ sender: NSMenuItem) {
            guard let node = sender.representedObject as? FileExplorerNode else { return }
            let relativePath = FileExplorerTerminalPathInsertion.relativePath(for: node.path, rootPath: store.rootPath)
            GhosttyApp.terminalPasteboard.writeString(
                relativePath,
                to: .general
            )
        }
    }
}

// MARK: - Container View (all-AppKit)

/// Pure AppKit container holding the header bar and outline view.
@MainActor
final class FileExplorerContainerView: NSView {
    private let headerView: FileExplorerHeaderView
    private let searchBarView: NSView
    private let pinnedStrip = FileExplorerPinnedStripView()
    private let searchField: FileExplorerSearchField
    private let searchStatusLabel: NSTextField
    private let scrollView: NSScrollView
    private let outlineView: FileExplorerNSOutlineView
    private let searchScrollView: NSScrollView
    let searchResultsView: FileExplorerSearchResultsTableView
    private let emptyLabel: NSTextField
    private let loadingIndicator: NSProgressIndicator
    private let searchController: any FileSearchControlling
    private var searchBarHeightConstraint: NSLayoutConstraint!
    private var searchFieldHeightConstraint: NSLayoutConstraint!
    private(set) var searchSnapshot = FileSearchSnapshot.empty
    private var currentRootPath = ""
    private var currentSearchScope: FileSearchScope = .unsupported
    var currentResourceContextID: UUID?
    private var currentWorkspaceRootIdentity: UUID?
    private var currentContentRevision = 0
    private let searchDebounceSubject = PassthroughSubject<Int, Never>()
    private var searchDebounceCancellable: AnyCancellable?
    private var searchDebounceGeneration = 0
    private var pendingSearchRefreshAfterSettled = false
    private var isSearchVisible = false {
        didSet {
            if !isSearchVisible {
                cancelPendingSearchRefresh()
                pendingSearchRefreshAfterSettled = false
            }
        }
    }
    private var presentation: FileExplorerPanelPresentation
    let coordinator: FileExplorerPanelView.Coordinator
    private var fontMagnificationObserver: GlobalFontMagnificationChangeObserver?
    private var chromeStyleObservers: Set<AnyCancellable> = []
    private lazy var pendingPreviewDrag = FilePreviewNativeDragPendingOwnership { [weak self] tokenID in
        self?.previewWriterDidDeallocate(tokenID: tokenID)
    }
    private let searchDebounceDelayMilliseconds = 200
    private var searchBarVisibleHeight: CGFloat { max(48, GlobalFontMagnification.scaled(48)) }
    private var searchFieldVisibleHeight: CGFloat { SidebarSearchField.visibleHeight }

#if DEBUG
    private var debugLastSearchTextChangeUptime: TimeInterval = 0
    private var debugLastSearchLayoutFieldWidth: CGFloat = -1
    private var debugLastSearchLayoutStatusWidth: CGFloat = -1
    private var debugLastLoggedSearchResultCount = -1
    private var debugLastLoggedSearchStatus = ""
#endif

    init(
        coordinator: FileExplorerPanelView.Coordinator,
        presentation: FileExplorerPanelPresentation,
        searchController: (any FileSearchControlling)? = nil
    ) {
        headerView = FileExplorerHeaderView()
        searchBarView = NSView()
        searchField = FileExplorerSearchField()
        searchStatusLabel = NSTextField(labelWithString: "")
        scrollView = NSScrollView()
        outlineView = FileExplorerNSOutlineView()
        searchScrollView = NSScrollView()
        searchResultsView = FileExplorerSearchResultsTableView()
        emptyLabel = NSTextField(wrappingLabelWithString: String(localized: "fileExplorer.empty", defaultValue: "No folder open"))
        loadingIndicator = NSProgressIndicator()
        self.searchController = searchController ?? FileSearchController()
        self.presentation = presentation
        self.coordinator = coordinator

        super.init(frame: .zero)
        // Direct test/fixture construction bypasses NSViewRepresentable's
        // makeNSView hook; keep the coordinator's current-container identity
        // correct for native drag ownership in both paths.
        coordinator.containerView = self
        updateShortcutPlacement(coordinator.placement)
        configureSearchDebounce()

        // Header
        headerView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerView)

        // Search bar
        searchBarView.translatesAutoresizingMaskIntoConstraints = false
        searchBarView.isHidden = true
        addSubview(searchBarView)

        // Pinned files (hidden while the project has none)
        pinnedStrip.onOpen = { [weak self] path in
            self?.coordinator.onOpenFilePreview(path)
        }
        addSubview(pinnedStrip)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityIdentifier("FileExplorerSearchField")
        searchField.placeholderString = String(localized: "fileExplorer.search.placeholder", defaultValue: "Search files")
        searchField.delegate = self
        searchField.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchField.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: true)
        }
        searchField.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchField.onFocus = { [weak self] in
            guard let self else { return }
            self.isSearchVisible = true
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
            self.updateSearchLayout()
        }
        searchBarView.addSubview(searchField)

        searchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        searchStatusLabel.textColor = FileExplorerPalette.textSecondary
        searchStatusLabel.lineBreakMode = .byTruncatingTail
        searchStatusLabel.maximumNumberOfLines = 1
        searchStatusLabel.alignment = .left
        searchStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        searchStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        searchBarView.addSubview(searchStatusLabel)

        // Empty state label
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = FileExplorerPalette.textSecondary
        emptyLabel.alignment = .center
        emptyLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        // Loading indicator
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isHidden = true
        addSubview(loadingIndicator)
        applyChromeFonts()
        fontMagnificationObserver = GlobalFontMagnificationChangeObserver { [weak self] in
            self?.reapplyChromeStyle()
        }
        // Type size and palette changes rebuild fonts, icon tints and row colours.
        for name in [InterfaceTextSize.didChangeNotification, BreeChromePaletteStore.didChangeNotification] {
            NotificationCenter.default.publisher(for: name)
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.reapplyChromeStyle() }
                .store(in: &chromeStyleObservers)
        }

        // Outline view setup
        outlineView.headerView = nil
        outlineView.usesAlternatingRowBackgroundColors = false
        outlineView.style = .plain
        outlineView.selectionHighlightStyle = .regular
        outlineView.rowSizeStyle = .default
        outlineView.indentationPerLevel = FileExplorerStyle.current.indentation
        outlineView.allowsMultipleSelection = true
        outlineView.autoresizesOutlineColumn = true
        outlineView.floatsGroupRows = false
        outlineView.backgroundColor = .clear
        outlineView.onQuickSearchChanged = { [weak self] query in
            self?.headerView.updateQuickSearch(query: query)
        }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.isEditable = false
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column

        outlineView.dataSource = coordinator
        outlineView.delegate = coordinator
        outlineView.target = coordinator
        outlineView.onNativeDragPointerBoundary = { [weak coordinator, weak outlineView] in
            guard let outlineView else { return }
            coordinator?.prepareForNativeDragBoundary(on: outlineView)
        }
        outlineView.action = #selector(FileExplorerPanelView.Coordinator.handleSingleClick(_:))
        outlineView.doubleAction = #selector(FileExplorerPanelView.Coordinator.handleDoubleClick(_:))
        outlineView.setDraggingSourceOperationMask(.move, forLocal: true)
        outlineView.registerForDraggedTypes([.fileURL])
        coordinator.outlineView = outlineView
        outlineView.onContextMenuDidClose = { [weak coordinator] in
            coordinator?.contextMenuDidClose()
        }

        // Context menu
        let menu = NSMenu()
        menu.delegate = coordinator
        outlineView.menu = menu

        // Scroll view
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = outlineView
        addSubview(scrollView)

        // Streaming search results
        searchResultsView.headerView = nil
        searchResultsView.usesAlternatingRowBackgroundColors = false
        searchResultsView.style = .plain
        searchResultsView.selectionHighlightStyle = .regular
        searchResultsView.backgroundColor = .clear
        searchResultsView.rowHeight = FileExplorerSearchResultCellView.preferredRowHeight
        searchResultsView.allowsMultipleSelection = true
        searchResultsView.intercellSpacing = NSSize(width: 0, height: 0)
        searchResultsView.onCancel = { [weak self] in
            self?.closeSearchAndFocusOutline()
        }
        searchResultsView.onMoveSelection = { [weak self] delta in
            self?.moveSearchSelection(by: delta, focusResults: false)
        }
        searchResultsView.onCommit = { [weak self] in
            self?.openSelectedSearchResult()
        }
        searchResultsView.onFocus = { [weak self] in
            guard let self else { return }
            self.coordinator.noteKeyboardFocus(mode: self.representedRightSidebarMode(), in: self.window)
        }
        searchResultsView.onModeShortcut = { [weak coordinator] mode, window in
            coordinator?.handleModeShortcut(mode, in: window) ?? false
        }
        searchResultsView.onNativeDragPointerBoundary = { [weak self] in
            self?.prepareForNativeDragBoundary()
        }
        let searchColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("searchResult"))
        searchColumn.isEditable = false
        searchColumn.resizingMask = .autoresizingMask
        searchResultsView.addTableColumn(searchColumn)
        searchResultsView.dataSource = self
        searchResultsView.delegate = self
        searchResultsView.target = self
        searchResultsView.doubleAction = #selector(openSelectedSearchResultFromTable(_:))
        searchResultsView.setDraggingSourceOperationMask(.move, forLocal: true)
        let searchMenu = NSMenu()
        searchMenu.delegate = self
        searchResultsView.menu = searchMenu

        searchScrollView.translatesAutoresizingMaskIntoConstraints = false
        searchScrollView.hasVerticalScroller = true
        searchScrollView.hasHorizontalScroller = false
        searchScrollView.horizontalScrollElasticity = .none
        searchScrollView.autohidesScrollers = true
        searchScrollView.borderType = .noBorder
        searchScrollView.drawsBackground = false
        searchScrollView.documentView = searchResultsView
        searchScrollView.isHidden = true
        addSubview(searchScrollView)

        self.searchController.onSnapshotChanged = { [weak self] snapshot in
            self?.applySearchSnapshot(snapshot)
        }

        searchBarHeightConstraint = searchBarView.heightAnchor.constraint(equalToConstant: 0)
        searchFieldHeightConstraint = searchField.heightAnchor.constraint(equalToConstant: searchFieldVisibleHeight)
        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: topAnchor),
            headerView.leadingAnchor.constraint(equalTo: leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: trailingAnchor),

            searchBarView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            searchBarView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchBarView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchBarHeightConstraint,

            searchField.leadingAnchor.constraint(equalTo: searchBarView.leadingAnchor, constant: SidebarSearchField.leadingPadding),
            searchField.trailingAnchor.constraint(equalTo: searchBarView.trailingAnchor, constant: -8),
            searchField.topAnchor.constraint(equalTo: searchBarView.topAnchor, constant: SidebarSearchField.topPadding),
            searchFieldHeightConstraint,
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),

            searchStatusLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 4),
            searchStatusLabel.trailingAnchor.constraint(equalTo: searchField.trailingAnchor),
            searchStatusLabel.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 2),

            pinnedStrip.topAnchor.constraint(equalTo: searchBarView.bottomAnchor),
            pinnedStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            pinnedStrip.trailingAnchor.constraint(equalTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: pinnedStrip.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            searchScrollView.topAnchor.constraint(equalTo: pinnedStrip.bottomAnchor),
            searchScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            searchScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            searchScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    private func reapplyChromeStyle() {
        applyChromeFonts()
        headerView.applyHeaderState()
        outlineView.reloadData()
        searchResultsView.rowHeight = FileExplorerSearchResultCellView.preferredRowHeight
        searchResultsView.reloadData()
    }

    private func applyChromeFonts() {
        searchField.applyFontScale()
        searchStatusLabel.font = BreeType.nsFont(.caption, weight: .medium)
        emptyLabel.font = BreeType.nsFont(.body)
        searchFieldHeightConstraint?.constant = searchFieldVisibleHeight
        if isSearchVisible {
            searchBarHeightConstraint?.constant = searchBarVisibleHeight
        }
        headerView.applyFonts()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelPendingSearchRefresh()
            searchController.cancel(clear: false)
        }
        if newWindow !== window, let observed = occlusionObservedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: observed)
            occlusionObservedWindow = nil
        }
        super.viewWillMove(toWindow: newWindow)
    }

    #if DEBUG
    private var lastViewportSignature = ""
    #endif

    /// Window the occlusion observer is attached to.
    private var occlusionObservedWindow: NSWindow?

    /// Tells the store whether the tree can be seen, so it releases its watcher while hidden.
    private func updateStoreViewportVisibility() {
        var visible = false
        if let window, !isHiddenOrHasHiddenAncestor, !window.isMiniaturized, !visibleRect.isEmpty {
            visible = window.occlusionState.contains(.visible)
        }
        #if DEBUG
        // Measurement aid: a locked screen occludes every window, so allow forcing visibility.
        if ProcessInfo.processInfo.environment["BREE_FE_FORCE_VISIBLE"] == "1" { visible = window != nil }
        let signature = "visible=\(visible ? 1 : 0) win=\(window != nil ? 1 : 0) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) vis=\(NSStringFromRect(visibleRect)) occ=\(window?.occlusionState.rawValue ?? 0)"
        if signature != lastViewportSignature {
            lastViewportSignature = signature
            dlog("file.explorer.viewport.eval \(signature)")
        }
        #endif
        coordinator.store.setViewportVisible(visible)
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateStoreViewportVisibility()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateStoreViewportVisibility()
    }

    @objc private func windowOcclusionDidChange(_ notification: Notification) {
        updateStoreViewportVisibility()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window, occlusionObservedWindow == nil {
            NotificationCenter.default.addObserver(
                self, selector: #selector(windowOcclusionDidChange(_:)),
                name: NSWindow.didChangeOcclusionStateNotification, object: window)
            occlusionObservedWindow = window
        }
        updateStoreViewportVisibility()
        guard let window else { return }
        if coordinator.placement == .rightSidebar {
            AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
        }
#if DEBUG
        dlog(
            "file.focus.host.attach win=\(window.windowNumber) canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
    }

    func registerWithKeyboardFocusCoordinatorIfNeeded() {
        guard coordinator.placement == .rightSidebar else { return }
        guard let window else { return }
        AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.registerFileExplorerHost(self)
    }

    override func layout() {
#if DEBUG
        let debugLayoutStart = ProcessInfo.processInfo.systemUptime
#endif
        super.layout()
        // Collapsed/clipped sidebars change geometry without hide notifications.
        updateStoreViewportVisibility()
        registerWithKeyboardFocusCoordinatorIfNeeded()
#if DEBUG
        logSearchLayoutIfNeeded(startedAt: debugLayoutStart, reason: "layout")
#endif
    }

    func updateHeader(store: FileExplorerStore) {
        let nextRootPath = store.rootPath, nextSearchScope = FileSearchScope(provider: store.provider)
        let nextWorkspaceRootIdentity = store.workspaceRootIdentity, nextContentRevision = store.contentRevision
        let workspaceRootChanged = nextWorkspaceRootIdentity != currentWorkspaceRootIdentity || currentResourceContextID != store.resourceContextID, contentRevisionChanged = nextContentRevision != currentContentRevision
        let searchScopeChanged = workspaceRootChanged || nextRootPath != currentRootPath || nextSearchScope != currentSearchScope
        currentRootPath = nextRootPath; currentSearchScope = nextSearchScope
        currentResourceContextID = store.resourceContextID
        currentWorkspaceRootIdentity = nextWorkspaceRootIdentity; currentContentRevision = nextContentRevision
        headerView.onNavigate = { [weak store] path in store?.setRootPath(path) }
        pinnedStrip.update(root: coordinator.pinnedProjectRoot)
        headerView.update(displayPath: store.displayRootPath,
            localRootPath: store.provider is LocalFileExplorerProvider ? store.breadcrumbPath : nil,
            retry: nil)
        if workspaceRootChanged { cancelPendingSearchRefresh(); pendingSearchRefreshAfterSettled = false; searchController.cancel(clear: true); searchField.stringValue = ""; applySearchSnapshot(.empty) }
        if searchScopeChanged {
            pendingSearchRefreshAfterSettled = false
            refreshSearchIfNeeded()
        } else if contentRevisionChanged {
            refreshSearchAfterContentRevisionIfNeeded()
        }
    }

    func representedRightSidebarMode() -> RightSidebarMode {
        presentation.rightSidebarMode
    }

    func updateShortcutPlacement(_ placement: FileExplorerPanelPlacement) {
        searchField.fileExplorerPanelPlacement = placement
        outlineView.fileExplorerPanelPlacement = placement
        searchResultsView.fileExplorerPanelPlacement = placement
    }

    func updatePresentation(_ nextPresentation: FileExplorerPanelPresentation) {
        guard presentation != nextPresentation else {
            // Re-selecting the active presentation is a no-op unless visibility drifted.
            if presentation == .find, !isSearchVisible {
                isSearchVisible = true
                updateSearchLayout()
            }
            return
        }

        presentation = nextPresentation
        switch presentation {
        case .files:
            isSearchVisible = false
            searchController.cancel(clear: false)
        case .find:
            isSearchVisible = true
            refreshSearchIfNeeded()
        }
        updateSearchLayout()
        registerWithKeyboardFocusCoordinatorIfNeeded()
    }

    func updateVisibility(
        hasContent: Bool,
        isLoading: Bool,
        statusMessage: String?,
        showsRemoteTarget: Bool = false
    ) {
        let normalizedStatus = statusMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasStatus = normalizedStatus?.isEmpty == false
        let canShowTree = hasContent && !hasStatus
        applyHidden(headerView, !hasContent && !hasStatus && !showsRemoteTarget)
        updateSearchLayout(hasContent: canShowTree, isLoading: isLoading)
        let searchCanShow = isSearchVisible && canShowTree && !isLoading
        let nextEmptyText = hasStatus
            ? normalizedStatus!
            : String(localized: "fileExplorer.empty", defaultValue: "No folder open")
        if emptyLabel.stringValue != nextEmptyText {
            emptyLabel.stringValue = nextEmptyText
        }
        applyHidden(emptyLabel, canShowTree || searchCanShow || isLoading)
        // Toggle the spinner only when the loading state actually changes.
        if applyHidden(loadingIndicator, !isLoading) {
            if isLoading {
                loadingIndicator.startAnimation(nil)
            } else {
                loadingIndicator.stopAnimation(nil)
            }
        }
    }

    @discardableResult
    func focusSearchField() -> Bool {
        guard let window, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.search.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        isSearchVisible = true
        updateSearchLayout()
        refreshSearchIfNeeded()
        let result = window.makeFirstResponder(searchField)
        searchField.selectText(nil)
#if DEBUG
        dlog(
            "file.focus.search.end result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "queryLen=\(searchField.stringValue.count) fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }

    /// Path and owning workspace of the single selected file row (never a folder),
    /// used by the Quick View shortcut. Nil with no selection, a multi-selection
    /// or a stale row from another resource context.
    func selectedFileForQuickView() -> (path: String, workspaceId: UUID?)? {
        guard outlineView.selectedRowIndexes.count == 1,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? FileExplorerNode,
              !node.isDirectory,
              node.resourceContextID == nil || node.resourceContextID == currentResourceContextID else {
            return nil
        }
        return (node.path, currentWorkspaceRootIdentity)
    }

    @discardableResult
    func focusOutline() -> Bool {
#if DEBUG
        dlog(
            "file.focus.outline.begin win=\(window?.windowNumber ?? -1) " +
            "canAccept=\(cmuxCanAcceptRightSidebarKeyboardFocus ? 1 : 0) " +
            "hostHidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0) scrollHidden=\(scrollView.isHidden ? 1 : 0) " +
            "outlineHidden=\(outlineView.isHiddenOrHasHiddenAncestor ? 1 : 0) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        guard let window, cmuxCanAcceptRightSidebarKeyboardFocus else {
#if DEBUG
            dlog(
                "file.focus.outline.end result=0 reason=unavailable " +
                "win=\(window?.windowNumber ?? -1) hidden=\(isHiddenOrHasHiddenAncestor ? 1 : 0)"
            )
#endif
            return false
        }
        if isSearchVisible {
            isSearchVisible = false
            searchController.cancel(clear: true)
            searchField.stringValue = ""
            searchSnapshot = .empty
            searchResultsView.reloadData()
            updateSearchLayout()
        }
        (outlineView.dataSource as? FileExplorerPanelView.Coordinator)?
            .ensureSelection(in: outlineView, fallbackToFirstVisible: true, scroll: true)
        let result = window.makeFirstResponder(outlineView)
#if DEBUG
        dlog(
            "file.focus.outline.end result=\(result ? 1 : 0) win=\(window.windowNumber) " +
            "rows=\(outlineView.numberOfRows) selected=\(outlineView.selectedRow) " +
            "fr=\(fileExplorerDebugResponder(window.firstResponder))"
        )
#endif
        return result
    }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === outlineView || responder === searchResultsView || responder === searchField {
            return true
        }
        if let editor = searchField.currentEditor(), responder === editor {
            return true
        }
        var view = responder as? NSView
        while let candidate = view {
            if candidate === searchBarView || candidate === searchScrollView || candidate === searchResultsView {
                return true
            }
            view = candidate.superview
        }
        return false
    }

    private func refreshSearchIfNeeded() {
        guard isSearchVisible else { return }
        cancelPendingSearchRefresh()
#if DEBUG
        dlog(
            "file.search.request queryLen=\(searchField.stringValue.count) " +
            "rootReady=\(currentRootPath.isEmpty ? 0 : 1) scope=\(currentSearchScope.debugName) " +
            "revision=\(currentContentRevision) results=\(searchSnapshot.results.count) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width))"
        )
#endif
        searchController.search(
            query: searchField.stringValue,
            rootPath: currentRootPath,
            scope: currentSearchScope,
            contentRevision: currentContentRevision
        )
    }

    private func refreshSearchAfterContentRevisionIfNeeded() {
        guard isSearchVisible else {
            pendingSearchRefreshAfterSettled = false
            return
        }
        guard searchSnapshot.isSearching else {
            pendingSearchRefreshAfterSettled = false
            refreshSearchIfNeeded()
            return
        }
        pendingSearchRefreshAfterSettled = true
#if DEBUG
        dlog(
            "file.search.contentRevision.defer queryLen=\(searchField.stringValue.count) " +
            "revision=\(currentContentRevision) results=\(searchSnapshot.results.count)"
        )
#endif
    }

    private func configureSearchDebounce() {
        searchDebounceCancellable = searchDebounceSubject
            .debounce(for: .milliseconds(searchDebounceDelayMilliseconds), scheduler: RunLoop.main)
            .sink { [weak self] debounceGeneration in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.isSearchVisible,
                          self.searchDebounceGeneration == debounceGeneration else { return }
#if DEBUG
                    dlog(
                        "file.search.debounce.fire queryLen=\(self.searchField.stringValue.count) " +
                        "delayMs=\(self.searchDebounceDelayMilliseconds)"
                    )
#endif
                    self.refreshSearchIfNeeded()
                }
            }
    }

    private func scheduleSearchRefresh() {
        guard isSearchVisible else { return }
        pendingSearchRefreshAfterSettled = false
        searchDebounceGeneration += 1
        let debounceGeneration = searchDebounceGeneration
#if DEBUG
        dlog(
            "file.search.debounce.schedule queryLen=\(searchField.stringValue.count) " +
            "delayMs=\(searchDebounceDelayMilliseconds)"
        )
#endif
        searchDebounceSubject.send(debounceGeneration)
    }

    private func cancelPendingSearchRefresh() {
        searchDebounceGeneration += 1
    }

    private func updateSearchLayout(hasContent: Bool? = nil, isLoading: Bool? = nil) {
        let effectiveHasContent = hasContent ?? !currentRootPath.isEmpty
        let effectiveIsLoading = isLoading ?? coordinator.store.isRootLoading
        let showSearchResults = isSearchVisible && effectiveHasContent && !effectiveIsLoading
        let nextSearchBarHeight = isSearchVisible ? searchBarVisibleHeight : 0

        // Assigning isHidden/constraints unconditionally fires KVO even when unchanged,
        // which re-enters updateNSView and spins the main thread on macOS 26 (#4931).
        var changed = false
        // Loading changes the results, not the editor's lifetime. Hiding the
        // active search bar makes AppKit end editing and drops shortcut focus.
        if applyHidden(searchBarView, !isSearchVisible) { changed = true }
        if searchBarHeightConstraint.constant != nextSearchBarHeight {
            searchBarHeightConstraint.constant = nextSearchBarHeight
            changed = true
        }
        if applyHidden(searchScrollView, !showSearchResults) { changed = true }
        if applyHidden(scrollView, isSearchVisible || !effectiveHasContent || effectiveIsLoading) { changed = true }
        if changed {
            needsLayout = true
        }
    }

    /// Sets `isHidden` only when it changes (a redundant write still fires KVO), returning whether it changed.
    @discardableResult
    private func applyHidden(_ view: NSView, _ hidden: Bool) -> Bool {
        guard view.isHidden != hidden else { return false }
        view.isHidden = hidden
        return true
    }

    private func applySearchSnapshot(_ snapshot: FileSearchSnapshot) {
#if DEBUG
        let debugApplyStart = ProcessInfo.processInfo.systemUptime
        let previousStatusName = debugSearchStatusName(searchSnapshot.status)
        let previousStatusTextLength = searchStatusLabel.stringValue.count
#endif
        let previousSelectedRow = searchResultsView.selectedRow
        let previousResults = searchSnapshot.results
        searchSnapshot = snapshot
        searchStatusLabel.stringValue = statusText(for: snapshot)
        applySearchResultsUpdate(previousResults: previousResults, nextResults: snapshot.results)
#if DEBUG
        logSearchSnapshot(
            snapshot,
            startedAt: debugApplyStart,
            previousStatusName: previousStatusName,
            previousStatusTextLength: previousStatusTextLength
        )
#endif

        let shouldRunDeferredContentRefresh = !snapshot.isSearching && pendingSearchRefreshAfterSettled
        if shouldRunDeferredContentRefresh {
            pendingSearchRefreshAfterSettled = false
        }

        if !snapshot.results.isEmpty {
            let selectedRow = previousSelectedRow >= 0
                ? min(previousSelectedRow, snapshot.results.count - 1)
                : 0
            searchResultsView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }

        if shouldRunDeferredContentRefresh {
            refreshSearchIfNeeded()
        }
    }

    private func applySearchResultsUpdate(previousResults: [FileSearchResult], nextResults: [FileSearchResult]) {
        if previousResults == nextResults {
            return
        }

        if nextResults.count > previousResults.count &&
            nextResults.starts(with: previousResults) {
            let insertedRange = previousResults.count..<nextResults.count
            searchResultsView.insertRows(at: IndexSet(integersIn: insertedRange), withAnimation: [])
            return
        }

        if nextResults.count == previousResults.count {
            let changedRows = IndexSet(
                nextResults.indices.filter { nextResults[$0] != previousResults[$0] }
            )
            if !changedRows.isEmpty {
                searchResultsView.reloadData(forRowIndexes: changedRows, columnIndexes: IndexSet(integer: 0))
            }
            return
        }

        searchResultsView.reloadData()
    }


#if DEBUG
    private func debugSearchNumber(_ value: CGFloat) -> String {
        String(format: "%.1f", Double(value))
    }

    private func debugSearchNumber(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    private func debugSearchStatusName(_ status: FileSearchSnapshot.Status) -> String {
        switch status {
        case .idle:
            return "idle"
        case .unsupported:
            return "unsupported"
        case .searching:
            return "searching"
        case .noMatches:
            return "noMatches"
        case .matches:
            return "matches"
        case .limited(let limit):
            return "limited(\(limit))"
        case .failed:
            return "failed"
        }
    }

    private func logSearchLayoutIfNeeded(startedAt: TimeInterval, reason: String) {
        guard isSearchVisible else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let fieldWidth = searchField.frame.width
        let statusWidth = searchStatusLabel.frame.width
        let firstLayout = debugLastSearchLayoutFieldWidth < 0 || debugLastSearchLayoutStatusWidth < 0
        let fieldDelta = debugLastSearchLayoutFieldWidth >= 0
            ? abs(fieldWidth - debugLastSearchLayoutFieldWidth)
            : 0
        let statusDelta = debugLastSearchLayoutStatusWidth >= 0
            ? abs(statusWidth - debugLastSearchLayoutStatusWidth)
            : 0
        let layoutMs = max(0, (now - startedAt) * 1000)
        let widthChanged = fieldDelta > 0.5 || statusDelta > 0.5
        let slowLayout = layoutMs >= 8
        guard firstLayout || widthChanged || slowLayout else { return }

        debugLastSearchLayoutFieldWidth = fieldWidth
        debugLastSearchLayoutStatusWidth = statusWidth
        let sinceKeyMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        dlog(
            "file.search.layout reason=\(reason) fieldW=\(debugSearchNumber(fieldWidth)) " +
            "statusW=\(debugSearchNumber(statusWidth)) fieldDelta=\(debugSearchNumber(fieldDelta)) " +
            "statusDelta=\(debugSearchNumber(statusDelta)) layoutMs=\(debugSearchNumber(layoutMs)) " +
            "sinceKeyMs=\(sinceKeyMs) queryLen=\(searchField.stringValue.count) " +
            "results=\(searchSnapshot.results.count) status=\(debugSearchStatusName(searchSnapshot.status))"
        )
    }

    private func logSearchSnapshot(
        _ snapshot: FileSearchSnapshot,
        startedAt: TimeInterval,
        previousStatusName: String,
        previousStatusTextLength: Int
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        let applyMs = max(0, (now - startedAt) * 1000)
        let statusName = debugSearchStatusName(snapshot.status)
        let resultDelta = debugLastLoggedSearchResultCount >= 0
            ? abs(snapshot.results.count - debugLastLoggedSearchResultCount)
            : snapshot.results.count
        let shouldLog = statusName != debugLastLoggedSearchStatus ||
            resultDelta >= 50 ||
            applyMs >= 4
        guard shouldLog else { return }

        debugLastLoggedSearchStatus = statusName
        debugLastLoggedSearchResultCount = snapshot.results.count
        let sinceKeyMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        dlog(
            "file.search.snapshot status=\(statusName) previousStatus=\(previousStatusName) " +
            "results=\(snapshot.results.count) isSearching=\(snapshot.isSearching ? 1 : 0) " +
            "applyMs=\(debugSearchNumber(applyMs)) sinceKeyMs=\(sinceKeyMs) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width)) " +
            "statusIntrinsicW=\(debugSearchNumber(searchStatusLabel.intrinsicContentSize.width)) " +
            "statusTextLen=\(searchStatusLabel.stringValue.count) previousStatusTextLen=\(previousStatusTextLength)"
        )
    }
#endif

    private func closeSearchAndFocusOutline() {
        if presentation == .find {
            let hadQuery = !searchField.stringValue.isEmpty
            cancelPendingSearchRefresh()
            pendingSearchRefreshAfterSettled = false
            searchController.cancel(clear: true)
            searchField.stringValue = ""
            applySearchSnapshot(.empty)
            updateSearchLayout()
            if hadQuery {
                _ = focusSearchField()
                return
            }
            if AppDelegate.shared?.keyboardFocusCoordinator(for: window)?.focusTerminal() == true {
                return
            }
            window?.makeFirstResponder(nil)
            return
        }

        isSearchVisible = false
        searchController.cancel(clear: true)
        searchField.stringValue = ""
        pendingSearchRefreshAfterSettled = false
        searchSnapshot = .empty
        searchResultsView.reloadData()
        updateSearchLayout()
        _ = focusOutline()
    }

    private func moveSearchSelection(by delta: Int, focusResults: Bool) {
        guard !searchSnapshot.results.isEmpty else { return }
        let currentRow = searchResultsView.selectedRow >= 0
            ? searchResultsView.selectedRow
            : (delta >= 0 ? -1 : searchSnapshot.results.count)
        let targetRow = min(max(currentRow + delta, 0), searchSnapshot.results.count - 1)
        searchResultsView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        searchResultsView.scrollRowToVisible(targetRow)
        if focusResults, let window {
            _ = window.makeFirstResponder(searchResultsView)
        }
    }

    private func searchResult(forMenuItem sender: NSMenuItem) -> FileSearchResult? {
        guard currentResourceContextID == coordinator.store.resourceContextID,
              let row = (sender.representedObject as? NSNumber)?.intValue,
              row >= 0,
              row < searchSnapshot.results.count else {
            return nil
        }
        return searchSnapshot.results[row]
    }

    @MainActor
    fileprivate func openSelectedSearchResult() {
        let row = searchResultsView.selectedRow
        guard currentResourceContextID == coordinator.store.resourceContextID, row >= 0, row < searchSnapshot.results.count else { return }
        let path = searchSnapshot.results[row].path
        // Editor/preferred-editor actions operate on local file paths via
        // NSWorkspace; for non-local providers fall back to the cmux preview.
        guard coordinator.store.provider is LocalFileExplorerProvider else {
            coordinator.onOpenFilePreview(path)
            return
        }
        performFileExplorerFileOpen(path: path, onOpenFilePreview: coordinator.openAsTab)
    }

    @objc private func openSelectedSearchResultFromTable(_ sender: NSTableView) {
        openSelectedSearchResult()
    }

    @objc private func contextMenuOpenSearchResultInCmux(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        coordinator.onOpenFilePreview(result.path)
    }

    @objc private func contextMenuOpenSearchResultExternally(_ sender: NSMenuItem) {
        guard coordinator.store.provider is LocalFileExplorerProvider,
              let request = sender.representedObject as? FileExplorerExternalOpenRequest else { return }
        FileExternalOpenAction.open(fileURL: request.fileURL, applicationURL: request.applicationURL)
    }
    @objc private func contextMenuRevealSearchResultInFinder(_ sender: NSMenuItem) {
        guard coordinator.store.provider is LocalFileExplorerProvider,
              let result = searchResult(forMenuItem: sender) else { return }
        FileExternalOpenAction.revealInFinder(fileURL: URL(fileURLWithPath: result.path))
    }
    @objc private func contextMenuCopySearchResultPath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        GhosttyApp.terminalPasteboard.writeString(
            result.path,
            to: .general
        )
    }

    @objc private func contextMenuCopySearchResultRelativePath(_ sender: NSMenuItem) {
        guard let result = searchResult(forMenuItem: sender) else { return }
        GhosttyApp.terminalPasteboard.writeString(
            result.relativePath,
            to: .general
        )
    }
}

extension FileExplorerContainerView: NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === searchField else { return }
        scrollSearchFieldEditorToInsertionPoint()
        Task { @MainActor [weak self] in
            self?.scrollSearchFieldEditorToInsertionPoint()
        }
#if DEBUG
        let now = ProcessInfo.processInfo.systemUptime
        let gapMs = debugLastSearchTextChangeUptime > 0
            ? debugSearchNumber((now - debugLastSearchTextChangeUptime) * 1000)
            : "n/a"
        debugLastSearchTextChangeUptime = now
        dlog(
            "file.search.input.changed queryLen=\(searchField.stringValue.count) gapMs=\(gapMs) " +
            "fieldW=\(debugSearchNumber(searchField.frame.width)) statusW=\(debugSearchNumber(searchStatusLabel.frame.width)) " +
            "statusIntrinsicW=\(debugSearchNumber(searchStatusLabel.intrinsicContentSize.width)) " +
            "results=\(searchSnapshot.results.count) status=\(debugSearchStatusName(searchSnapshot.status)) " +
            "fr=\(fileExplorerDebugResponder(window?.firstResponder))"
        )
#endif
        scheduleSearchRefresh()
    }

    private func scrollSearchFieldEditorToInsertionPoint() {
        guard let editor = searchField.currentEditor() else { return }
        let selection = editor.selectedRange
        let textLength = (editor.string as NSString).length
        let cursorLocation = min(selection.location + selection.length, textLength)
        editor.scrollRangeToVisible(NSRange(location: cursorLocation, length: 0))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField, !textView.hasMarkedText() else { return false }
        if let event = NSApp.currentEvent, searchField.handleOpenSelectionShortcut(event) { return true }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            guard !textView.hasMarkedText() else { return false }
            openSelectedSearchResult()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            closeSearchAndFocusOutline()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSearchSelection(by: 1, focusResults: true)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSearchSelection(by: -1, focusResults: true)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        searchSnapshot.results.count
    }

    private func previewWriterDidDeallocate(tokenID: UUID) {
        guard searchResultsView.pendingNativeDragTokenID == tokenID else { return }
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0, row < searchSnapshot.results.count else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileSearchResultCell")
        let cellView: FileExplorerSearchResultCellView
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? FileExplorerSearchResultCellView {
            cellView = existing
        } else {
            cellView = FileExplorerSearchResultCellView(identifier: identifier)
        }
        cellView.configure(with: searchSnapshot.results[row])
        return cellView
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === searchResultsView, coordinator.store.provider is LocalFileExplorerProvider,
              row >= 0,
              row < searchSnapshot.results.count else {
            return nil
        }
        let result = searchSnapshot.results[row]
        let writer = FilePreviewDragPasteboardWriter(
            filePath: result.path,
            displayTitle: (result.relativePath as NSString).lastPathComponent,
            nativeSourceView: tableView,
            nativeSourceOwner: self,
            provisionalToken: pendingPreviewDrag.makeToken()
        )
        searchResultsView.pendingNativeDragWriter = writer
        searchResultsView.pendingNativeDragTokenID = writer.provisionalToken?.id
        pendingPreviewDrag.register(writer)
        return writer
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint,
        forRowIndexes rowIndexes: IndexSet
    ) {
        _ = screenPoint
        _ = rowIndexes
        guard tableView === searchResultsView else { return }
        if let previousSession = searchResultsView.activeNativeDragSession,
           previousSession === session {
            return
        }
        if coordinator.isTrackingNativeDrag(session) {
            return
        }
        // A distinct begin is a native boundary, including when the previous
        // source belonged to a container replaced by SwiftUI reconstruction.
        _ = coordinator.reclaimTrackedNativeDrag()
        let fallbackWriter = searchResultsView.pendingNativeDragWriter
        var promotedWriters = pendingPreviewDrag.writers(for: tableView)
        if let fallbackWriter,
           !promotedWriters.contains(where: { $0 === fallbackWriter }) {
            promotedWriters.append(fallbackWriter)
        }
        pendingPreviewDrag.finishPending(preserving: promotedWriters)
        coordinator.supersedeNativeDragIfNeeded(
            previousSession: searchResultsView.activeNativeDragSession,
            newSession: session,
            finishPrevious: {
                let pasteboard = searchResultsView.activeNativeDragSession?.draggingPasteboard
                    ?? session.draggingPasteboard
                for ownership in searchResultsView.activeNativeDragOwnerships {
                    ownership.finish(from: pasteboard)
                }
            },
            clearPrevious: {
                searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
                searchResultsView.activeNativeDragWriter = nil
                searchResultsView.activeNativeDragDelegateMarker = nil
                searchResultsView.activeNativeDragOwnerships = []
                searchResultsView.activeNativeDragOwnership = nil
                searchResultsView.activeNativeDragSession = nil
            }
        )
        // The ordered list mirrors AppKit's pasteboard item order; use its
        // first writer as the canonical source identity.
        let promotedWriter = promotedWriters.first ?? fallbackWriter
        let promotedOwnerships = pendingPreviewDrag.promote(writers: promotedWriters)
        promotedWriter?.materializeRegisteredPayload(to: session.draggingPasteboard)
        let ownerships = promotedOwnerships.isEmpty
            ? (promotedWriter?.nativeDragOwnership()).map { [$0] } ?? []
            : promotedOwnerships
        // The pasteboard writer retains this exact container through the native
        // terminal callback. Keep only a weak marker on the table: a strong
        // table → container edge would create a retain cycle.
        searchResultsView.activeNativeDragDelegateMarker = self
        searchResultsView.activeNativeDragWriter = promotedWriter
        searchResultsView.activeNativeDragOwnerships = ownerships
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
        searchResultsView.activeNativeDragSession = session
        coordinator.trackNativeDrag(
            sourceView: searchResultsView,
            session: session,
            writer: promotedWriter,
            ownerships: ownerships
        )
    }

    func tableView(
        _ tableView: NSTableView,
        draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        guard tableView === searchResultsView else { return }
        if searchResultsView.activeNativeDragSession === session {
            if !searchResultsView.activeNativeDragOwnerships.isEmpty {
                for ownership in searchResultsView.activeNativeDragOwnerships {
                    ownership.finish(from: session.draggingPasteboard)
                }
            } else {
                // This is the matching generation, so the fallback cannot
                // accidentally parse a newer session's shared pasteboard.
                FilePreviewDragPasteboardWriter.discardRegisteredDrag(from: session)
            }
            searchResultsView.activeNativeDragDelegateMarker = nil
            searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
            searchResultsView.activeNativeDragWriter = nil
            searchResultsView.activeNativeDragOwnerships = []
            searchResultsView.activeNativeDragOwnership = nil
            searchResultsView.activeNativeDragSession = nil
            coordinator.forgetTrackedNativeDrag(matching: session)
        }
    }

    /// Reclaims a search drag whose native terminal callback was lost before a
    /// subsequent pointer gesture. AppKit cannot deliver this `mouseDown`
    /// while the prior native drag loop is active, making the boundary safe to
    /// use for releasing the intentional container/table retain cycle.
    func prepareForNativeDragBoundary() {
        if coordinator.reclaimTrackedNativeDrag() {
            // The coordinator may be tracking an outline or search table from
            // an older container. Finish pending writers owned by this
            // container as well, without touching a new active generation.
            pendingPreviewDrag.finishPending()
            searchResultsView.pendingNativeDragWriter = nil
            searchResultsView.pendingNativeDragTokenID = nil
            return
        }
        guard let session = searchResultsView.activeNativeDragSession else {
            searchResultsView.activeNativeDragDelegateMarker = nil
            pendingPreviewDrag.finishPending()
            if let tokenID = searchResultsView.pendingNativeDragTokenID {
                pendingPreviewDrag.remove(tokenID: tokenID)
            }
            searchResultsView.pendingNativeDragWriter = nil
            searchResultsView.pendingNativeDragTokenID = nil
            searchResultsView.activeNativeDragOwnership = nil
            return
        }
        for ownership in searchResultsView.activeNativeDragOwnerships {
            ownership.finish(from: session.draggingPasteboard)
        }
        pendingPreviewDrag.finishPending()
        searchResultsView.pendingNativeDragWriter = nil
        searchResultsView.pendingNativeDragTokenID = nil
        searchResultsView.activeNativeDragDelegateMarker = nil
        searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
        searchResultsView.activeNativeDragWriter = nil
        searchResultsView.activeNativeDragOwnerships = []
        searchResultsView.activeNativeDragOwnership = nil
        searchResultsView.activeNativeDragSession = nil
        coordinator.forgetTrackedNativeDrag(matching: session)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let searchMenu = searchResultsView.menu, menu === searchMenu else { return }
        menu.removeAllItems()
        let clickedRow = searchResultsView.clickedRow
        let row = clickedRow >= 0 ? clickedRow : searchResultsView.selectedRow
        guard currentResourceContextID == coordinator.store.resourceContextID, row >= 0, row < searchSnapshot.results.count else { return }
        if clickedRow >= 0 && !searchResultsView.selectedRowIndexes.contains(clickedRow) {
            searchResultsView.selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }

        let openInCmuxItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.openInCmux", defaultValue: "Open in Bree"),
            action: #selector(contextMenuOpenSearchResultInCmux(_:)),
            keyEquivalent: ""
        )
        openInCmuxItem.target = self
        openInCmuxItem.representedObject = NSNumber(value: row)
        menu.addItem(openInCmuxItem)

        if coordinator.store.provider is LocalFileExplorerProvider {
            FileExplorerExternalOpenMenuItems(
                fileURL: URL(fileURLWithPath: searchSnapshot.results[row].path),
                target: self,
                action: #selector(contextMenuOpenSearchResultExternally(_:))
            ).add(to: menu)
            let revealItem = NSMenuItem(
                title: FileExternalOpenText.revealInFinder,
                action: #selector(contextMenuRevealSearchResultInFinder(_:)),
                keyEquivalent: ""
            )
            revealItem.target = self
            revealItem.representedObject = NSNumber(value: row)
            menu.addItem(revealItem)
        }
        menu.addItem(.separator())

        menu.addFileExplorerInsertPathItems(target: self, representedObject: NSNumber(value: row), insertAction: #selector(contextMenuInsertSearchResultPath(_:)), insertRelativeAction: #selector(contextMenuInsertSearchResultRelativePath(_:)))

        let copyPathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.copyPath", defaultValue: "Copy Path"),
            action: #selector(contextMenuCopySearchResultPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = NSNumber(value: row)
        menu.addItem(copyPathItem)

        let copyRelativePathItem = NSMenuItem(
            title: String(localized: "fileExplorer.contextMenu.copyRelativePath", defaultValue: "Copy Relative Path"),
            action: #selector(contextMenuCopySearchResultRelativePath(_:)),
            keyEquivalent: ""
        )
        copyRelativePathItem.target = self
        copyRelativePathItem.representedObject = NSNumber(value: row)
        menu.addItem(copyRelativePathItem)
    }
}

private extension FileExplorerContainerView {
    func clearNativeDragMarkersIfIdle() {
        guard searchResultsView.activeNativeDragSession == nil,
              outlineView.activeNativeDragSession == nil else { return }
        for ownership in searchResultsView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        for ownership in outlineView.activeNativeDragOwnerships {
            ownership.revokeRouting()
        }
        searchResultsView.activeNativeDragDelegateMarker = nil
        searchResultsView.activeNativeDragWriter?.releaseSourceGraph()
        searchResultsView.activeNativeDragWriter = nil
        searchResultsView.activeNativeDragOwnerships = []
        searchResultsView.activeNativeDragOwnership = nil
        outlineView.activeNativeDragDelegateMarker = nil
        outlineView.activeNativeDragWriter?.releaseSourceGraph()
        outlineView.activeNativeDragWriter = nil
        outlineView.activeNativeDragOwnerships = []
        outlineView.activeNativeDragOwnership = nil
    }
}
