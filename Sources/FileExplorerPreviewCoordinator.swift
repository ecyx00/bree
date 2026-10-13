import AppKit
import Bonsplit

/// Both sidebar entrypoints capture the displayed provider before suspending.
@MainActor
struct FileExplorerPreviewCoordinator {
    let store: FileExplorerStore

    func open(path: String, workspace: Workspace, pane: PaneID, isCurrent: @escaping @MainActor () -> Bool) {
        guard store.workspaceRootIdentity == workspace.id, let provider = store.provider,
              provider.isAvailable else { return }
        let context = store.resourceContextID
        if provider is LocalFileExplorerProvider {
            guard !workspace.usesRemoteDirectoryProvenance else { return }
            QuickViewResource.file(path: path).open(from: workspace)
            return
        }
        guard let remoteProvider = provider as? any RemoteFileExplorerProvider else { return }
        let providerIdentity = remoteProvider.remoteIdentity
        Task { [weak workspace, store] in
            guard let workspace else { return }
            do {
                guard isCurrent(), store.resourceContextID == context else { return }
                if try await Self.refreshExistingRemotePreview(
                    path: path, providerIdentity: providerIdentity, workspace: workspace, pane: pane,
                    store: store, context: context, isCurrent: isCurrent,
                    provider: remoteProvider
                ) { return }
                let lease = try await store.remotePreviewCache.materialize(path: path, provider: remoteProvider)
                guard isCurrent(), store.resourceContextID == context else { return }
                if let panel = workspace.openFilePreviewSurfaces(inPane: pane, filePaths: [lease.url.path],
                    focus: true, reuseExisting: false).first {
                    panel.remotePreviewLease = lease
                    Self.installRemotePreviewRefresh(
                        on: panel, workspace: workspace,
                        isCurrent: isCurrent, provider: remoteProvider
                    )
                    workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: panel)
                }
            } catch is CancellationError {
                return
            } catch {
                guard isCurrent(), store.resourceContextID == context else { return }
                Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
            }
        }
    }

    private static func refreshExistingRemotePreview(
        path: String,
        providerIdentity: String,
        workspace: Workspace,
        pane: PaneID,
        store: FileExplorerStore,
        context: UUID,
        isCurrent: @escaping @MainActor () -> Bool,
        provider: any RemoteFileExplorerProvider
    ) async throws -> Bool {
        guard let existing = workspace.panels.values
            .compactMap({ $0 as? FilePreviewPanel })
            .first(where: {
                !$0.isClosed &&
                    $0.remotePreviewRemotePath == path &&
                    $0.remotePreviewProviderIdentity == providerIdentity &&
                    FileManager.default.fileExists(atPath: $0.filePath)
            }) else { return false }
        guard let lease = existing.remotePreviewLease else { return false }
        guard !existing.isClosed else { return true }
        try await lease.refresh(using: provider)
        guard isCurrent(), store.resourceContextID == context, !existing.isClosed,
              workspace.panels[existing.id] != nil else { return true }
        _ = existing.reloadFromDisk()
        _ = workspace.openOrFocusFilePreviewSurface(inPane: pane, filePath: existing.filePath, focus: true)
        workspace.handKeyboardFocusFromRightSidebarAfterFileOpen(to: existing)
        return true
    }

    private static func installRemotePreviewRefresh(
        on panel: FilePreviewPanel,
        workspace: Workspace,
        isCurrent: @escaping @MainActor () -> Bool,
        provider: any RemoteFileExplorerProvider
    ) {
        panel.remotePreviewRefresh = { [weak panel, weak workspace] in
            Task { @MainActor [weak panel, weak workspace] in
                guard let panel, let workspace, let lease = panel.remotePreviewLease,
                      !panel.isClosed, isCurrent() else { return }
                do {
                    try await lease.refresh(using: provider)
                    guard isCurrent(),
                          !panel.isClosed, workspace.panels[panel.id] != nil else { return }
                    _ = panel.reloadFromDisk()
                } catch is CancellationError {
                    return
                } catch {
                    Self.present(error, window: AppDelegate.shared?.mainWindowContainingWorkspace(workspace.id))
                }
            }
        }
    }

    private static func present(_ error: Error, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "fileExplorer.preview.failedTitle", defaultValue: "Unable to open remote file")
        alert.informativeText = (error as? FileExplorerError)?.localizedDescription
            ?? String(localized: "fileExplorer.preview.genericFailure", defaultValue: "The remote file could not be downloaded. Reconnect and try again.")
        alert.addButton(withTitle: String(localized: "fileExplorer.preview.ok", defaultValue: "OK"))
        _ = alert.runBreeModal(presentingWindow: window)
    }
}
