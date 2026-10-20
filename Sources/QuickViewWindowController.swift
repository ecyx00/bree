import AppKit
import BreeFoundation
import SwiftUI

/// A Quick View window. `shared` is the reusable one: showing another resource
/// replaces its content. `openInNewWindow` makes a separate controller that lives
/// until its window closes. Pin promotes the content to a tab in the originating workspace.
@MainActor
final class QuickViewWindowController: NSObject, NSWindowDelegate {
    static let shared = QuickViewWindowController()
    /// Non-reused windows, retained until they close.
    private static var extras: [QuickViewWindowController] = []
    private var isExtra = false

    static func openInNewWindow(resource: QuickViewResource, from workspace: Workspace, activate: Bool = true) {
        let controller = QuickViewWindowController()
        controller.isExtra = true
        extras.append(controller)
        controller.show(resource: resource, from: workspace, activate: activate)
    }

    private static var visibleControllers: [QuickViewWindowController] {
        ([shared] + extras).filter { $0.window?.isVisible == true }
    }

    /// Whether any Quick View window is on screen.
    static var hasVisibleWindow: Bool { !visibleControllers.isEmpty }

    /// Title and full path or URL of what each visible Quick View window shows (socket `quick_view.status`).
    static var visibleSummaries: [(title: String, detail: String)] {
        visibleControllers.compactMap { controller in
            controller.resource.map { (title: $0.title, detail: $0.detail) }
        }
    }

    /// Closes every visible Quick View window and returns how many were open (socket `quick_view.close`).
    @discardableResult
    static func closeAllVisibleWindows() -> Int {
        let controllers = visibleControllers
        for controller in controllers { controller.window?.close() }
        return controllers.count
    }

    /// The visible Quick View window that has key focus, if any.
    static var keyWindow: NSWindow? {
        visibleControllers.compactMap(\.window).first { $0.isKeyWindow }
    }

    /// Makes the most recent visible Quick View window key. False when none is open.
    @discardableResult
    static func focusVisibleWindow() -> Bool {
        guard let window = visibleControllers.compactMap(\.window).last else { return false }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Keyboard toggle. Closes the key Quick View window; otherwise focuses the
    /// most recent visible one. False when no Quick View window is open.
    @discardableResult
    static func focusOrCloseVisibleWindow() -> Bool {
        if let keyed = keyWindow {
            keyed.close()
            return true
        }
        return focusVisibleWindow()
    }

    private var window: QuickViewWindow?
    private var panel: (any Panel)?
    private var resource: QuickViewResource?
    private weak var workspace: Workspace?
    private weak var returnWindow: NSWindow?

    private var history = QuickViewHistory()

    /// `activate: false` orders the window front without making it key, so a socket
    /// caller does not take keyboard focus from the user.
    func show(resource: QuickViewResource, from workspace: Workspace, activate: Bool = true) {
        if activate, let current = NSApp.keyWindow, current !== window { returnWindow = current }
        if self.resource == resource, self.workspace === workspace, let window {
            if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
            return
        }
        history.push(resource)
        display(resource, from: workspace, activate: activate)
    }

    /// Opens a markdown link clicked inside a Quick View panel in that same window, so history works.
    /// False when `panelId` is not a Quick View panel. Deferred: the clicked web view is torn down.
    static func openLink(_ path: String, fromPanelId panelId: UUID) -> Bool {
        open(.file(path: path), fromPanelId: panelId)
    }

    /// Same as `openLink` for any resource (a file at a line, ...).
    static func open(_ resource: QuickViewResource, fromPanelId panelId: UUID) -> Bool {
        guard let controller = ([shared] + extras).first(where: { $0.panel?.id == panelId }),
              let workspace = controller.workspace else { return false }
        Task { controller.show(resource: resource, from: workspace) }
        return true
    }

    /// The workspace behind the Quick View window showing panel `panelId`.
    static func workspace(forPanelId panelId: UUID) -> Workspace? {
        ([shared] + extras).first(where: { $0.panel?.id == panelId })?.workspace
    }

    func goBack() {
        guard let workspace, let resource = history.back() else { return }
        display(resource, from: workspace)
    }

    func goForward() {
        guard let workspace, let resource = history.forward() else { return }
        display(resource, from: workspace)
    }

    /// Rendered/Source toggle for artifact panels and Markdown. False when the content has no source view.
    func toggleSource() -> Bool {
        if let artifact = panel as? ArtifactPanel, artifact.supportsSourceToggle {
            artifact.toggleSource()
            return true
        }
        if let markdown = panel as? MarkdownPanel {
            markdown.setDisplayMode(markdown.displayMode == .preview ? .text : .preview)
            return true
        }
        return false
    }

    /// Cmd+ / Cmd- thumbnail size in the folder grid. False for any other content.
    func zoomGrid(by step: Int) -> Bool {
        guard let artifact = panel as? ArtifactPanel, artifact.kind == .folder else { return false }
        artifact.zoom(by: step)
        return true
    }

    /// Opens the current resource in the default app (files) or browser (URLs).
    func openExternally() {
        switch resource {
        case .file(let path, _, _): _ = FileExternalOpenAction.openDefault(fileURL: URL(fileURLWithPath: path))
        case .url(let url): _ = NSWorkspace.shared.open(url)
        case .folder(let path): _ = NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
        case nil: break
        }
    }

    /// Prompts for `line` or `line:col`. False when the content is not a text editor.
    @discardableResult
    func promptGoToLine() -> Bool {
        let filePanel = panel as? FilePreviewPanel
        let markdownPanel = panel as? MarkdownPanel
        guard let window, filePanel?.previewMode == .text || markdownPanel != nil else { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "quickView.goToLine.title", defaultValue: "Go to Line")
        alert.informativeText = String(localized: "quickView.goToLine.message", defaultValue: "Enter a line number, or line:column.")
        alert.addButton(withTitle: String(localized: "quickView.goToLine.go", defaultValue: "Go"))
        alert.addButton(withTitle: String(localized: "common.cancel", defaultValue: "Cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, let target = parseGoToLine(field.stringValue) else { return }
            filePanel?.revealLine(target.line, column: target.column)
            markdownPanel?.revealLine(target.line, column: target.column)
        }
        return true
    }

    /// Swaps the window content to `resource`; unsaved edits of the old panel are saved first.
    private func display(_ resource: QuickViewResource, from workspace: Workspace, activate: Bool = true) {
        discardPanel()
        let window = window ?? makeWindow()
        let panel = resource.makePanel(for: workspace)
        self.window = window
        self.panel = panel
        self.resource = resource
        self.workspace = workspace
        window.title = resource.title
        window.contentView = NSHostingView(rootView: QuickViewWindowContent(
            resource: resource,
            panel: panel,
            initialAppearance: PanelAppearance.fromConfig(
                WorkspaceContentView.resolveGhosttyAppearanceConfig(reason: "quickView")
            ),
            canGoBack: history.canGoBack,
            canGoForward: history.canGoForward,
            onBack: { [weak self] in self?.goBack() },
            onForward: { [weak self] in self?.goForward() },
            onPin: { [weak self] in self?.pin() },
            onOpenExternally: { [weak self] in self?.openExternally() },
            onClose: { [weak self] in self?.window?.close() }
        ).breeFontMagnificationEnvironment())
        if activate { window.makeKeyAndOrderFront(nil) } else { window.orderFront(nil) }
    }

    /// Closes the window if it shows content for `workspace` (workspace teardown).
    func close(ifOwnedBy workspace: Workspace) {
        if self.workspace === workspace { window?.close() }
        if self === Self.shared { for extra in Self.extras { extra.close(ifOwnedBy: workspace) } }
    }

    func pin() {
        guard let resource, let workspace else { return }
        if case .folder = resource { return } // a grid has no tab form
        let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first
        window?.close()
        guard let paneId else { return }
        switch resource {
        case .file(let path, _, _):
            let panels = workspace.openFileSurfaces(inPane: paneId, filePaths: [path], focus: true, reuseExisting: true)
            if ObsidianVault.isVaultMarkdown(path) || WikiPaths.isWikiPage(path) { for case let panel as MarkdownPanel in panels { panel.isReadOnly = true } }
        case .url(let url):
            _ = workspace.newBrowserSurface(inPane: paneId, url: url, focus: true)
        case .folder:
            break
        }
    }

    func windowWillClose(_ notification: Notification) {
        discardPanel()
        resource = nil
        history = QuickViewHistory()
        // Drop grid thumbnails and remembered grid positions with the window.
        ArtifactThumbnailCache.shared.removeAll()
        ArtifactGridMemory.shared.removeAll()
        window?.contentView = nil
        returnWindow?.makeKeyAndOrderFront(nil)
        if let workspace, let panelId = workspace.focusedPanelId { workspace.focusPanel(panelId) }
        if isExtra { Self.extras.removeAll { $0 === self } }
    }

    /// Releases file watchers / the web view. Unsaved edits are saved first.
    private func discardPanel() {
        if let panel = panel as? FilePreviewPanel, panel.isDirty { _ = panel.saveTextContent() }
        if let panel = panel as? MarkdownPanel, panel.isDirty { _ = panel.saveTextContent() }
        panel?.close()
        panel = nil
    }

    func makeWindow() -> QuickViewWindow {
        let window = QuickViewWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // Show over a native-fullscreen main window instead of switching to the desktop Space.
        window.collectionBehavior.formUnion([.fullScreenAuxiliary, .moveToActiveSpace])
        BreeSurfaceAppearance.follow(window)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self
        window.onPin = { [weak self] in self?.pin() }
        window.onShortcut = { [weak self] key in
            switch key {
            case "[": self?.goBack()
            case "]": self?.goForward()
            case "l": return self?.promptGoToLine() ?? false
            case "u": return self?.toggleSource() ?? false
            case "=", "+": return self?.zoomGrid(by: 1) ?? false
            case "-": return self?.zoomGrid(by: -1) ?? false
            default: return false
            }
            return true
        }
        window.center()
        if isExtra {
            // Own history/frame: offset from center per open window instead of the shared autosave frame.
            let offset = CGFloat(28 * Self.extras.count)
            window.setFrameOrigin(NSPoint(x: window.frame.origin.x + offset, y: window.frame.origin.y - offset))
        } else {
            window.setFrameAutosaveName("QuickViewWindow")
        }
        return window
    }
}

/// Handles Cmd+W (the configured Close Tab shortcut), Cmd+Return, Cmd+[/], Cmd+L, Cmd+U, Cmd+/- and Esc here,
/// before the main menu's Close Tab can act on the main window's tab.
final class QuickViewWindow: NSWindow {
    var onPin: (() -> Void)?
    /// Cmd+[ / Cmd+] / Cmd+L; returns whether the key was handled.
    var onShortcut: ((String) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Focus-region cycling and the Quick View toggle must work from here too: this
        // window is not a main terminal window, so the main-window router may skip it.
        if event.type == .keyDown,
           AppDelegate.shared?.handleKeyboardNavigationShortcut(event: event, preferredWindow: nil) == true {
            return true
        }
        if event.type == .keyDown,
           let key = event.charactersIgnoringModifiers,
           // Cmd+ needs Shift on US layouts; every other shortcut is plain Cmd.
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == Self.shortcutModifiers(for: key),
           onShortcut?(key) == true {
            return true
        }
        if event.type == .keyDown, event.keyCode == 36,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            onPin?()
            return true
        }
        if AppDelegate.shared?.handleBrowserPopupCloseShortcutKeyEquivalent(event: event, popupWindow: self) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func shortcutModifiers(for key: String) -> NSEvent.ModifierFlags {
        key == "+" ? [.command, .shift] : .command
    }

    override func cancelOperation(_ sender: Any?) { close() }
}
