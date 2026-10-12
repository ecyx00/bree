import AppKit
import CmuxFoundation
import CmuxTerminal
import WebKit

@MainActor
final class MainWindowFocusController {
    private enum EffectiveFocusOwner {
        case mainPanel
        case rightSidebar
        case unknown
    }

    private enum RightSidebarFocusTarget: Equatable {
        case host
        case outline
        case searchField
        case firstItem
    }

    private struct RightSidebarFocusRequest: Equatable {
        let id: UInt64
        let mode: RightSidebarMode
        let target: RightSidebarFocusTarget
    }

    private enum RightSidebarFocusState: Equatable {
        case inactive
        case requested(RightSidebarFocusRequest)
        case focused(mode: RightSidebarMode, target: RightSidebarFocusTarget)

        var mode: RightSidebarMode? {
            switch self {
            case .inactive:
                return nil
            case .requested(let request):
                return request.mode
            case .focused(let mode, _):
                return mode
            }
        }

        var request: RightSidebarFocusRequest? {
            if case .requested(let request) = self {
                return request
            }
            return nil
        }
    }

    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?
    private weak var fileExplorerState: FileExplorerState?
    private weak var rightSidebarHost: RightSidebarKeyboardFocusView?
    private weak var fileExplorerHost: FileExplorerContainerView?
    private weak var dockHost: DockKeyboardFocusView?
    private weak var architectureWebView: WKWebView?

    private(set) var intent: MainWindowKeyboardFocusIntent? {
        didSet {
            syncBonsplitTabShortcutHintEligibility()
            publishRightSidebarOwnsInputFocus()
        }
    }

    /// Mirror the exclusive focus intent into `FileExplorerState` so the view
    /// layer can make main-pane vs right-sidebar (Dock) focus mutually exclusive.
    private func publishRightSidebarOwnsInputFocus() {
        let ownsFocus: Bool
        switch intent {
        case .rightSidebar, .bottomPanel: ownsFocus = true
        case .mainPanel, nil: ownsFocus = false
        }
        guard let fileExplorerState, fileExplorerState.rightSidebarOwnsInputFocus != ownsFocus else { return }
        fileExplorerState.rightSidebarOwnsInputFocus = ownsFocus
    }
    private var rememberedRightSidebarMode: RightSidebarMode?
    private var nextRightSidebarFocusRequestId: UInt64 = 0
    private var rightSidebarFocusState: RightSidebarFocusState = .inactive
    /// The right sidebar's active mode when it owns focus, else `nil`. Surfaces the
    /// private focus state for the `sidebarMode` keyboard-shortcut context key.
    var activeRightSidebarMode: RightSidebarMode? {
        rightSidebarFocusState.mode
    }

    init(
        windowId: UUID,
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.windowId = windowId
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        self.rememberedRightSidebarMode = fileExplorerState?.mode
        syncBonsplitTabShortcutHintEligibility()
    }

    func update(
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        if rememberedRightSidebarMode == nil {
            rememberedRightSidebarMode = fileExplorerState?.mode
        }
        syncBonsplitTabShortcutHintEligibility()
    }

    func registerRightSidebarHost(_ host: RightSidebarKeyboardFocusView) {
        rightSidebarHost = host
        if let mode = rightSidebarFocusState.request?.mode {
            focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
        }
    }

    func registerFileExplorerHost(_ host: FileExplorerContainerView) {
        let mode = host.representedRightSidebarMode()
        switch mode {
        case .files:
            fileExplorerHost = host
        case .sessions, .activity, .architecture, .customSidebar:
            break
        }
        focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
    }

    /// The Architecture diagram's web view, so focusing the mode lands arrow keys on it.
    func registerArchitectureWebView(_ webView: WKWebView) {
        architectureWebView = webView
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .architecture)
        // The view can attach after focus already fell back to the sidebar host.
        if case .rightSidebar(.architecture) = intent,
           let window,
           let host = rightSidebarHost,
           window.firstResponder === host {
            _ = window.makeFirstResponder(webView)
        }
    }

    func registerDockHost(_ host: DockKeyboardFocusView) {
        dockHost = host
    }

    func noteRightSidebarInteraction(mode: RightSidebarMode) {
        rememberedRightSidebarMode = mode
        rightSidebarFocusState = .focused(mode: mode, target: .host)
        intent = .rightSidebar(mode: mode)
    }

    /// Records that the bottom panel owns keyboard focus, so main-area terminals
    /// stop reasserting focus and the focus rings swap.
    func noteBottomPanelInteraction() {
        rightSidebarFocusState = .inactive
        intent = .bottomPanel
    }

    func rememberRightSidebarMode(_ mode: RightSidebarMode) {
        rememberedRightSidebarMode = mode
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelInteraction(workspaceId: UUID, panelId: UUID) {
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
    }

    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        if GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId) {
            return true
        }
        switch intent {
        case .rightSidebar, .bottomPanel:
            return false
        case .mainPanel, nil:
            return true
        }
    }

    /// Whether the exact main-area terminal target owns this window's current
    /// input focus. A pending right-sidebar intent wins over a stale terminal
    /// first responder; otherwise the live responder is authoritative.
    func ownsMainPanelInputFocus(
        workspaceId: UUID,
        containerPanelId: UUID,
        surfaceId: UUID
    ) -> Bool {
        switch intent {
        case .rightSidebar, .bottomPanel:
            return false
        case .mainPanel, nil:
            break
        }
        guard let responder = window?.firstResponder else { return false }

        if let terminal = terminalFocusRequest(for: responder) {
            return terminal.workspaceId == workspaceId
                && (terminal.panelId == surfaceId || terminal.panelId == containerPanelId)
        }
        if rightSidebarModeOwning(responder) != nil {
            return false
        }
        guard let mainPanel = selectedFocusedPanelRequest(owning: responder) else {
            return false
        }
        return mainPanel.workspaceId == workspaceId
            && (mainPanel.panelId == containerPanelId || mainPanel.panelId == surfaceId)
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard ShortcutHintDebugSettings().modifierHoldHintsEnabled else { return false }
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .rightSidebar, .bottomPanel:
            return false
        case .mainPanel(let focusedWorkspaceId, _):
            return focusedWorkspaceId == workspaceId
        case nil:
            return true
        }
    }

    func ownsRightSidebarFocus(_ responder: NSResponder) -> Bool {
        if let host = rightSidebarHost, responder === host {
            return true
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        // The bottom panel (`dockHost`) is not the right sidebar: its focus is
        // tracked by `MainWindowKeyboardFocusIntent.bottomPanel`.
        return false
    }

    func shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: NSResponder?) -> Bool {
        if case .rightSidebar = intent {
            return true
        }
        guard let currentResponder else { return false }
        return ownsRightSidebarFocus(currentResponder)
    }

    @discardableResult
    func restoreTerminalFocusAfterRightSidebarHiddenIfNeeded() -> Bool {
        guard shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: window?.firstResponder) else {
            return false
        }
        return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
    }

    @discardableResult
    func restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: NSResponder? = nil) -> Bool {
        let responder = currentResponder ?? window?.firstResponder
        let ownsResponder = responder.map(ownsRightSidebarFocus) ?? false
        let ownsIntent: Bool = {
            if case .rightSidebar = intent {
                return true
            }
            return false
        }()
        guard ownsResponder || ownsIntent else {
            return false
        }

        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
        }

        rightSidebarFocusState = .inactive

        if panel is TerminalPanel {
            return focusTerminal()
        }

        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        if let window,
           let responder,
           ownsRightSidebarFocus(responder) {
            _ = window.makeFirstResponder(nil)
        }
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    @discardableResult
    func restoreTargetAfterWindowBecameKey() -> Bool {
        switch intent {
        case .rightSidebar(let mode):
            return restoreRightSidebarTargetAfterWindowBecameKey(mode: mode)
        case .mainPanel:
            return restoreMainPanelTargetAfterWindowBecameKey()
        case .bottomPanel, nil:
            return false
        }
    }

    @discardableResult
    private func restoreRightSidebarTargetAfterWindowBecameKey(mode: RightSidebarMode) -> Bool {
        if let responder = window?.firstResponder,
           rightSidebarModeOwning(responder) == mode {
            return true
        }
        if let request = rightSidebarFocusState.request, request.mode == mode {
            return focusRightSidebar(mode: mode, target: request.target)
        }
        return focusRightSidebar(
            mode: mode,
            focusFirstItem: false
        )
    }

    @discardableResult
    private func restoreMainPanelTargetAfterWindowBecameKey() -> Bool {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return false
        }

        if let responder = window.firstResponder {
            if panel.ownedFocusIntent(for: responder, in: window) != nil {
                noteMainPanelInteraction(workspaceId: workspace.id, panelId: panelId)
                return true
            }
            if liveRightSidebarModeOwning(responder, in: window) != nil {
                syncAfterResponderChange(responder: responder)
                return true
            }
            if terminalFocusRequest(for: responder) == nil,
               selectedFocusedPanelRequest(owning: responder) == nil,
               shouldRespectForeignFirstResponder(responder, in: window, isRightSidebarOwner: {
                   liveRightSidebarModeOwning($0, in: window) != nil
               }) {
                return false
            }
        }

        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    private func liveRightSidebarModeOwning(
        _ responder: NSResponder,
        in window: NSWindow
    ) -> RightSidebarMode? {
        guard (responder as? NSView)?.window === window else { return nil }
        return rightSidebarModeOwning(responder)
    }

    func syncAfterResponderChange() {
        syncAfterResponderChange(responder: window?.firstResponder)
    }

#if DEBUG
    var debugPendingRightSidebarFocusMode: RightSidebarMode? {
        rightSidebarFocusState.request?.mode
    }

    func debugSyncAfterResponderChange(responder: NSResponder?) {
        syncAfterResponderChange(responder: responder)
    }
#endif

    private func syncAfterResponderChange(responder: NSResponder?) {
        guard let responder else {
            return
        }
        if let terminal = terminalFocusRequest(for: responder) {
            if rightSidebarFocusState.request != nil {
                return
            }
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
            return
        }
        if let mode = rightSidebarModeOwning(responder) {
            let isFallbackSidebarHost = rightSidebarHost.map { responder === $0 } ?? false
            if !canAcceptRightSidebarResponderFocus(
                mode: mode,
                isFallbackSidebarHost: isFallbackSidebarHost
            ) {
                return
            }
            rememberedRightSidebarMode = mode
            completeRightSidebarFocusFromResponder(mode: mode, isFallbackSidebarHost: isFallbackSidebarHost)
            intent = .rightSidebar(mode: mode)
            return
        }
        if rightSidebarFocusState.request != nil {
            return
        }
        if let mainPanel = selectedFocusedPanelRequest(owning: responder) {
            noteMainPanelInteraction(workspaceId: mainPanel.workspaceId, panelId: mainPanel.panelId)
            return
        }
    }

    private func canAcceptRightSidebarResponderFocus(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) -> Bool {
        guard let request = rightSidebarFocusState.request else {
            return true
        }
        if responderMode != request.mode {
            return false
        }
        if isFallbackSidebarHost, request.target != .host {
            return false
        }
        return true
    }

    private func completeRightSidebarFocusFromResponder(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) {
        guard let request = rightSidebarFocusState.request else {
            rightSidebarFocusState = .focused(mode: responderMode, target: .host)
            return
        }
        guard request.mode == responderMode else { return }
        if isFallbackSidebarHost, request.target != .host {
            return
        }
        rightSidebarFocusState = .focused(mode: request.mode, target: request.target)
    }

    @discardableResult
    func focusRightSidebar(mode requestedMode: RightSidebarMode? = nil, focusFirstItem: Bool = true) -> Bool {
        guard let mode = resolvedRightSidebarMode(requestedMode: requestedMode) else {
            return false
        }
        let target = rightSidebarFocusTarget(mode: mode, focusFirstItem: focusFirstItem)
        return focusRightSidebar(mode: mode, target: target, terminalYieldReason: "rightSidebarFocus")
    }

    /// Whether a right-sidebar focus request has an available, window-owned
    /// state target. This preflight is intentionally nonmutating so callers can
    /// reject an unavailable request before activating or ordering its window.
    func canFocusRightSidebar(mode requestedMode: RightSidebarMode? = nil) -> Bool {
        resolvedRightSidebarMode(requestedMode: requestedMode) != nil
    }

    private func resolvedRightSidebarMode(requestedMode: RightSidebarMode?) -> RightSidebarMode? {
        guard let state = fileExplorerState else { return nil }
        let desiredMode = requestedMode ?? rememberedRightSidebarMode ?? state.mode
        if desiredMode.isAvailable() {
            return desiredMode
        }
        guard requestedMode == nil, RightSidebarMode.files.isAvailable() else {
            return nil
        }
        return .files
    }

    @discardableResult
    private func focusRightSidebar(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget,
        terminalYieldReason: String = "rightSidebarFocus"
    ) -> Bool {
        guard let state = fileExplorerState else { return false }
        guard mode.isAvailable() else { return false }
        rememberedRightSidebarMode = mode
        beginRightSidebarFocusRequest(mode: mode, target: target)
        intent = .rightSidebar(mode: mode)
        yieldCurrentTerminalSurfaceFocus(reason: terminalYieldReason)
        state.setVisible(true)
        if state.mode != mode {
            state.mode = mode
        }

        let modeResult = focusRightSidebarEndpoint(mode: mode, target: target)
        if modeResult {
            rightSidebarFocusState = .focused(mode: mode, target: target)
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        if fallbackResult, target == .host {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
        let result = modeResult || fallbackResult || rightSidebarFocusState.request?.mode == mode
        return result
    }

    @discardableResult
    func focusFileSearch() -> Bool {
        return focusRightSidebar(
            mode: .files,
            target: .searchField,
            terminalYieldReason: "fileSearchFocus"
        )
    }

    // MARK: - Focus regions (left sidebar, terminal, right sidebar, Quick View)

    /// The visible default workspace list, if the left sidebar currently shows one.
    private func leftSidebarTable() -> SidebarWorkspaceTableViewImpl? {
        guard let root = window?.contentView else { return nil }
        var pending: [NSView] = [root]
        while let view = pending.popLast() {
            if let table = view as? SidebarWorkspaceTableViewImpl,
               !table.isHiddenOrHasHiddenAncestor, !table.visibleRect.isEmpty {
                return table
            }
            pending.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Moves keyboard focus to the left sidebar's workspace list with the ring on
    /// the selected workspace. False when the sidebar is hidden or not the default list.
    @discardableResult
    func focusLeftSidebar() -> Bool {
        guard let table = leftSidebarTable() else { return false }
        // Drop any right-sidebar claim so a key-window restore does not steal focus back,
        // and so right-sidebar-scoped shortcuts (the sidebarFocus atom) stay off here.
        rightSidebarFocusState = .inactive
        if let workspace = tabManager?.selectedWorkspace, let panelId = workspace.focusedPanelId {
            intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        }
        yieldCurrentTerminalSurfaceFocus(reason: "leftSidebarFocus")
        table.keyboardDelegate = self
        return table.beginKeyboardNavigation(selectedWorkspaceId: tabManager?.selectedTabId)
    }

    /// Moves focus to the focused panel of the selected workspace (terminal, browser, editor).
    @discardableResult
    func focusMainContentRegion() -> Bool {
        leftSidebarTable()?.endKeyboardNavigation()
        var ownsRightSidebar = window?.firstResponder.map(ownsRightSidebarFocus) ?? false
        if case .rightSidebar = intent { ownsRightSidebar = true }
        if ownsRightSidebar {
            return restoreFocusedPanelFocusFromRightSidebarIfNeeded()
        }
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return focusTerminal()
        }
        if panel is TerminalPanel { return focusTerminal() }
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    /// The region that currently owns keyboard focus in this window.
    func currentFocusRegion() -> KeyboardFocusRegion {
        if leftSidebarTable()?.isKeyboardNavigationActive == true { return .leftSidebar }
        if case .bottomPanel = intent, tabManager?.selectedWorkspace?.isBottomPanelOpen == true { return .bottomPanel }
        if let responder = window?.firstResponder, rightSidebarModeOwning(responder) != nil { return .rightSidebar }
        return .terminal
    }

    func isRegionAvailable(_ region: KeyboardFocusRegion) -> Bool {
        switch region {
        case .leftSidebar:
            return leftSidebarTable() != nil
        case .terminal:
            return true
        case .bottomPanel:
            return tabManager?.selectedWorkspace?.isBottomPanelOpen == true
        case .rightSidebar:
            return fileExplorerState?.isVisible == true && canFocusRightSidebar()
        case .quickView:
            return QuickViewWindowController.hasVisibleWindow
        }
    }

    @discardableResult
    func focusRegion(_ region: KeyboardFocusRegion) -> Bool {
        switch region {
        case .leftSidebar:
            return focusLeftSidebar()
        case .terminal:
            return focusMainContentRegion()
        case .bottomPanel:
            guard let store = tabManager?.selectedWorkspace?._dockSplit,
                  store.isBottomPanelOpen,
                  store.focusFirstControl() else { return false }
            leftSidebarTable()?.endKeyboardNavigation()
            noteBottomPanelInteraction()
            return true
        case .rightSidebar:
            leftSidebarTable()?.endKeyboardNavigation()
            return focusRightSidebar()
        case .quickView:
            return QuickViewWindowController.focusVisibleWindow()
        }
    }

    /// Path and workspace of the file selected in the Files sidebar, for Quick View.
    func selectedFileForQuickView() -> (path: String, workspaceId: UUID?)? {
        fileExplorerHost?.selectedFileForQuickView()
    }

    @discardableResult
    func toggleRightSidebarOrTerminalFocus(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true
    ) -> Bool {
        switch focusToggleDestination() {
        case .terminal:
            return restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: window?.firstResponder)
        case .rightSidebar:
            return focusRightSidebar(mode: requestedMode, focusFirstItem: focusFirstItem)
        }
    }

    func focusToggleDestination(currentResponder: NSResponder? = nil) -> MainWindowFocusToggleDestination {
        switch effectiveFocusOwner(currentResponder: currentResponder) {
        case .rightSidebar:
            return .terminal
        case .mainPanel, .unknown:
            return .rightSidebar
        }
    }

    func findShortcutTarget(currentResponder: NSResponder? = nil) -> MainWindowFindShortcutTarget {
        let responder = currentResponder ?? window?.firstResponder
        if let responder {
            if let mode = rightSidebarModeOwning(responder) {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanelFind
            }
            if selectedFocusedPanelIsBrowser() {
                return .mainPanelFind
            }
            if case .rightSidebar(let mode) = intent {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            return .mainPanelFind
        }

        if case .rightSidebar(let mode) = intent {
            return findShortcutTarget(forRightSidebarMode: mode)
        }
        return .mainPanelFind
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return false
        }
        guard let terminalPanel = workspace.focusedTerminalInputTarget()?.panel else { return false }
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: terminalPanel.id)
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        return terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func findShortcutTarget(forRightSidebarMode mode: RightSidebarMode) -> MainWindowFindShortcutTarget {
        mode == .files ? .rightSidebarFileSearch : .none
    }

    private func selectedFocusedPanelIsBrowser() -> Bool {
        selectedFocusedBrowserPanelRequest() != nil
    }

    private struct FocusedPanelRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func selectedFocusedPanelRequest(owning responder: NSResponder) -> FocusedPanelRequest? {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        for (panelId, panel) in workspace.panels {
            guard panelId != workspace.focusedPanelId,
                  panel.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        return nil
    }

    private func selectedFocusedBrowserPanelRequest() -> FocusedPanelRequest? {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        guard panel is BrowserPanel else {
            return nil
        }
        return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
    }

    private func focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: Bool) -> Bool {
        let focused = focusTerminal()
        if focused {
            return true
        }

        if let window,
           let responder = window.firstResponder,
           ownsRightSidebarFocus(responder) {
            window.makeFirstResponder(nil)
        }

        rightSidebarFocusState = .inactive
        if clearUnavailableIntent, case .rightSidebar = intent {
            intent = nil
        }
        return false
    }

    private func effectiveFocusOwner(currentResponder: NSResponder? = nil) -> EffectiveFocusOwner {
        if let responder = currentResponder ?? window?.firstResponder {
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanel
            }
            if rightSidebarModeOwning(responder) != nil {
                return .rightSidebar
            }
            if selectedFocusedPanelRequest(owning: responder) != nil {
                return .mainPanel
            }
        }

        switch intent {
        case .mainPanel:
            return .mainPanel
        case .rightSidebar:
            return .rightSidebar
        case .bottomPanel, nil:
            return .unknown
        }
    }

    private func focusRegisteredRightSidebarEndpointIfNeeded(mode: RightSidebarMode) {
        guard let request = rightSidebarFocusState.request else {
            return
        }
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              request.mode == mode else {
            return
        }
        let result = focusRightSidebarEndpoint(mode: mode, target: request.target)
        if result {
            rightSidebarFocusState = .focused(mode: mode, target: request.target)
        } else if request.target == .host, focusFallbackRightSidebarHost() {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
    }

    private func beginRightSidebarFocusRequest(mode: RightSidebarMode, target: RightSidebarFocusTarget) {
        nextRightSidebarFocusRequestId &+= 1
        rightSidebarFocusState = .requested(
            RightSidebarFocusRequest(
                id: nextRightSidebarFocusRequestId,
                mode: mode,
                target: target
            )
        )
    }

    private func rightSidebarFocusTarget(
        mode: RightSidebarMode,
        focusFirstItem: Bool
    ) -> RightSidebarFocusTarget {
        switch mode {
        case .files:
            return .outline
        case .sessions, .activity, .architecture, .customSidebar:
            return .host
        }
    }

    private func focusRightSidebarEndpoint(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget
    ) -> Bool {
        switch mode {
        case .files:
            if target == .searchField {
                return fileExplorerHost?.focusSearchField() == true
            }
            return fileExplorerHost?.focusOutline() == true
        case .architecture:
            guard let window,
                  let webView = architectureWebView,
                  webView.window === window else { return false }
            return window.makeFirstResponder(webView)
        case .sessions, .activity, .customSidebar:
            return mode == .customSidebar ? focusFallbackRightSidebarHost() : false
        }
    }

    private func focusFallbackRightSidebarHost() -> Bool {
        guard let window,
              let host = rightSidebarHost else {
            return false
        }
        return window.makeFirstResponder(host)
    }

    private func yieldCurrentTerminalSurfaceFocus(reason: String) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return
        }
        workspace.focusedTerminalInputTarget()?.panel.hostedView
            .yieldTerminalSurfaceFocusForForeignResponder(reason: reason)
    }

    func syncBonsplitTabShortcutHintEligibility() {
        guard let tabManager else { return }
        for workspace in tabManager.tabs {
            let enabled = allowsBonsplitTabShortcutHints(workspaceId: workspace.id)
            if workspace.bonsplitController.tabShortcutHintsEnabled != enabled {
                workspace.bonsplitController.tabShortcutHintsEnabled = enabled
            }
        }
    }

    private func rightSidebarModeOwning(_ responder: NSResponder) -> RightSidebarMode? {
        if let host = rightSidebarHost, responder === host {
            return fileExplorerState?.mode ?? rememberedRightSidebarMode
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return .files
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return nil
        }
        if let webView = architectureWebView,
           let view = responder as? NSView,
           view === webView || view.isDescendant(of: webView) {
            return .architecture
        }
        return nil
    }

    private struct TerminalFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func terminalFocusRequest(for responder: NSResponder?) -> TerminalFocusRequest? {
        guard let ghosttyView = responder.cmuxTerminalFocusOwningGhosttyView(),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        if GhosttyApp.terminalSurfaceRegistry.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalFocusRequest(workspaceId: workspaceId, panelId: panelId)
    }
}

extension MainWindowFocusController: SidebarWorkspaceKeyboardDelegate {
    func sidebarKeyboardActivate(workspaceId: UUID) {
        if let workspace = tabManager?.tabs.first(where: { $0.id == workspaceId }) {
            tabManager?.selectWorkspace(workspace)
        }
        _ = focusMainContentRegion()
    }

    func sidebarKeyboardToggleGroup(groupId: UUID) {
        tabManager?.toggleWorkspaceGroupCollapsed(groupId: groupId)
    }

    func sidebarKeyboardCancel() {
        _ = focusMainContentRegion()
    }

    func sidebarKeyboardDidEnd() {}
}
