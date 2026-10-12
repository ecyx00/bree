import Foundation

/// One cancellable observation of the current workspace's root; equal roots do no I/O.
@MainActor
final class FileExplorerWorkspaceObservation {
    weak var workspace: Workspace?
    private let resolver: FileExplorerWorkspaceRootResolver
    private let apply: (FileExplorerWorkspaceRoot) -> Void
    private var previous: FileExplorerWorkspaceRoot?
    private var directoryObserver: NSObjectProtocol?

    init(workspace: Workspace, resolver: FileExplorerWorkspaceRootResolver,
         apply: @escaping (FileExplorerWorkspaceRoot) -> Void) {
        self.workspace = workspace
        self.resolver = resolver
        self.apply = apply
        directoryObserver = NotificationCenter.default.addObserver(
            forName: .workspaceCurrentDirectoryDidChange,
            object: nil,
            queue: .main
        ) { [weak self, weak workspace] notification in
            MainActor.assumeIsolated {
                guard let self, let workspace,
                      (notification.object as? Workspace) === workspace ||
                        (notification.userInfo?["workspaceId"] as? UUID) == workspace.id else { return }
                self.refresh()
            }
        }
    }

    func refresh(force: Bool = false) {
        guard let workspace else { return }
        let root = resolver.resolve(workspace)
        guard force || previous != root else { return }
        previous = root
        apply(root)
    }

    func stop() {
        if let directoryObserver {
            NotificationCenter.default.removeObserver(directoryObserver)
            self.directoryObserver = nil
        }
        workspace = nil
    }

    deinit {
        if let directoryObserver { NotificationCenter.default.removeObserver(directoryObserver) }
    }
}
