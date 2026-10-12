import Foundation

/// What the Quick View window can show. Add a case (and a branch in
/// ``makePanel(for:)``) to host a new surface in the window.
enum QuickViewResource: Equatable {
    /// A local file; `line`/`column` come from `file:line:col` links.
    case file(path: String, line: Int? = nil, column: Int? = nil)
    case url(URL)
    /// A local folder shown as an image grid.
    case folder(path: String)

    var title: String {
        switch self {
        case .file(let path, _, _): (path as NSString).lastPathComponent
        case .url(let url): url.host ?? url.absoluteString
        case .folder(let path): (path as NSString).lastPathComponent
        }
    }

    /// Secondary titlebar text: the containing directory, or the URL path.
    var subtitle: String {
        switch self {
        case .file(let path, _, _): ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        case .url(let url): url.host == nil ? "" : url.path
        case .folder(let path): ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath
        }
    }

    /// Full path or URL, shown as the tooltip.
    var detail: String {
        switch self {
        case .file(let path, _, _): path
        case .url(let url): url.absoluteString
        case .folder(let path): path
        }
    }

    /// The single entry point: every caller opens a resource through this.
    @MainActor
    func open(from workspace: Workspace, newWindow: Bool = false, activate: Bool = true) {
        if newWindow {
            QuickViewWindowController.openInNewWindow(resource: self, from: workspace, activate: activate)
        } else {
            QuickViewWindowController.shared.show(resource: self, from: workspace, activate: activate)
        }
    }

    /// The resolver: picks the existing panel type for the resource. The panel
    /// is not registered in the workspace, so the caller owns and closes it.
    @MainActor
    func makePanel(for workspace: Workspace) -> any Panel {
        switch self {
        case .file(let path, let line, let column):
            // Wiki source snapshots are untrusted downloads: always the plain text viewer, never rendered
            // markdown or HTML, and read-only.
            if WikiPaths.isSnapFile(path) {
                let panel = FilePreviewPanel(
                    workspaceId: workspace.id,
                    filePath: path,
                    fileContentChangeCoordinator: workspace.fileContentChangeCoordinator
                )
                panel.isReadOnly = true
                if let line { panel.revealLine(line, column: column) }
                return panel
            }
            if MarkdownPanelFileLinkResolver.isMarkdownPathLike(path) {
                let panel = MarkdownPanel(
                    workspaceId: workspace.id,
                    filePath: path,
                    fileContentChangeCoordinator: workspace.fileContentChangeCoordinator
                )
                // Obsidian and cmux have no lock between them (last writer wins): vault notes open read-only.
                // The "Read-only · Edit" button unlocks them.
                // Wiki pages (the global wiki folder) are written by a memory tool only: also read-only.
                if ObsidianVault.isVaultMarkdown(path) || WikiPaths.isWikiPage(path) { panel.isReadOnly = true }
                if let line { panel.revealLine(line, column: column) }
                return panel
            }
            // HTML, CSV/TSV and JSONL get a rendered view; file:line links want the text editor.
            if line == nil, let kind = ArtifactKind.kind(forFilePath: path) {
                return ArtifactPanel(
                    kind: kind, path: path, workspaceId: workspace.id,
                    fileContentChangeCoordinator: workspace.fileContentChangeCoordinator
                )
            }
            let panel = FilePreviewPanel(
                workspaceId: workspace.id,
                filePath: path,
                fileContentChangeCoordinator: workspace.fileContentChangeCoordinator
            )
            if let line { panel.revealLine(line, column: column) }
            return panel
        case .folder(let path):
            return ArtifactPanel(
                kind: .folder, path: path, workspaceId: workspace.id,
                fileContentChangeCoordinator: workspace.fileContentChangeCoordinator
            )
        case .url(let url):
            return BrowserPanel(
                workspaceId: workspace.id,
                initialURL: url,
                proxyEndpoint: workspace.remoteProxyEndpoint,
                isRemoteWorkspace: workspace.isRemoteWorkspace,
                remoteWebsiteDataStoreIdentifier: workspace.isRemoteWorkspace ? workspace.id : nil
            )
        }
    }
}

/// Back/forward stack for the Quick View window.
struct QuickViewHistory {
    private(set) var entries: [QuickViewResource] = []
    private var index = -1

    var canGoBack: Bool { index > 0 }
    var canGoForward: Bool { index + 1 < entries.count }

    /// Records a newly shown resource, dropping any forward entries.
    mutating func push(_ resource: QuickViewResource) {
        if entries.indices.contains(index), entries[index] == resource { return }
        entries.removeSubrange((index + 1)...)
        entries.append(resource)
        index += 1
    }

    mutating func back() -> QuickViewResource? {
        guard canGoBack else { return nil }
        index -= 1
        return entries[index]
    }

    mutating func forward() -> QuickViewResource? {
        guard canGoForward else { return nil }
        index += 1
        return entries[index]
    }
}
