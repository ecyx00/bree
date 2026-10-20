import AppKit
import BreeSettings
import Foundation

enum CommandClickFileOpenRouter {
    nonisolated static func shouldRouteInBree(
        path: String,
        defaults: UserDefaults = .standard
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        return store.shouldRouteMarkdown(path: path)
            || store.shouldRouteSupportedFile(path: path)
    }

    @MainActor
    static func openInBree(
        workspace: Workspace,
        sourcePanelId: UUID,
        filePath: String,
        defaults: UserDefaults = .standard,
        inQuickView: Bool = true,
        line: Int? = nil,
        column: Int? = nil
    ) -> Bool {
        let store = FileRouteSettingsStore(defaults: defaults)
        func showInQuickView() -> Bool {
            QuickViewResource.file(path: filePath, line: line, column: column).open(from: workspace)
            return true
        }
        if store.shouldRouteMarkdown(path: filePath) {
            if inQuickView { return showInQuickView() }
        }
        if store.shouldRouteMarkdown(path: filePath),
           workspace.openOrFocusMarkdownSplit(from: sourcePanelId, filePath: filePath) != nil {
            return true
        }

        guard store.shouldRouteSupportedFile(path: filePath) else {
            return false
        }

        // Quick View (same as the Files sidebar) wins over the browser tab for HTML.
        if !inQuickView, TerminalHTMLFileBrowserAction(defaults: defaults).open(
            fileURL: URL(fileURLWithPath: filePath),
            sourcePanelId: sourcePanelId,
            container: workspace
        ) {
            return true
        }

        if inQuickView { return showInQuickView() }
        return workspace.openOrFocusFilePreviewSplit(from: sourcePanelId, filePath: filePath) != nil
    }

    /// Resolve the working directory for a terminal surface, preferring the
    /// per-panel directory, then the panel's requested working directory,
    /// then the workspace-level directory.
    @MainActor
    static func resolveWorkingDirectory(
        workspace: Workspace,
        surfaceId: UUID
    ) -> String? {
        if let dir = workspace.panelDirectories[surfaceId]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        if let dir = workspace.terminalPanel(for: surfaceId)?
            .requestedWorkingDirectory?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            return dir
        }
        let dir = workspace.currentDirectory
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return dir.isEmpty ? nil : dir
    }

    /// Schedule a file open in bree, deferred to the next runloop tick.
    ///
    /// Ghostty's `Surface.openUrl` holds an internal `os_unfair_lock` when it
    /// dispatches into Swift; opening a new panel synchronously re-enters
    /// Ghostty and deadlocks (#3370). This helper defers the split creation
    /// via `DispatchQueue.main.async` and re-validates the workspace and path
    /// at dispatch time (TOCTOU). When routing fails, `fallback` is called so
    /// the caller can open the file externally.
    @MainActor
    static func deferredOpenFileInBree(
        workspace: Workspace,
        preferredWorkspaceId: UUID,
        surfaceId: UUID,
        filePath: String,
        defaults: UserDefaults = .standard,
        fallback: (@MainActor @Sendable () -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let resolvedWorkspace = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceId,
                preferredWorkspaceId: preferredWorkspaceId
            )?.workspace ?? workspace
            guard !resolvedWorkspace.isRemoteTerminalSurface(surfaceId) else {
                fallback?()
                return
            }
            guard shouldRouteInBree(path: filePath, defaults: defaults) else {
                fallback?()
                return
            }
            if openInBree(
                workspace: resolvedWorkspace,
                sourcePanelId: surfaceId,
                filePath: filePath,
                defaults: defaults
            ) {
                return
            }
            fallback?()
        }
    }
}
