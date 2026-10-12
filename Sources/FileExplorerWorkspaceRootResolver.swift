import Foundation

/// Both Files presentations resolve through the same workspace authority.
@MainActor
struct FileExplorerWorkspaceRootResolver {
    func resolve(_ workspace: Workspace) -> FileExplorerWorkspaceRoot {
        if workspace.usesRemoteDirectoryProvenance {
            guard let configuration = workspace.remoteConfiguration,
                  configuration.transport == .ssh else { return .none }
            return .remoteSSH(
                workspaceId: workspace.id,
                connection: SSHFileExplorerConnection(destination: configuration.destination,
                    port: configuration.port, identityFile: configuration.identityFile, sshOptions: configuration.sshOptions),
                displayTarget: configuration.displayTarget,
                rootPath: workspace.trustedRemoteCurrentDirectory,
                isAvailable: workspace.remoteConnectionState == .connected,
                unavailableDetail: workspace.remoteConnectionDetail ?? workspace.remoteDaemonStatus.detail
            )
        }
        let path = workspace.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        // A local workspace may not have reported a cwd yet (fresh and
        // restored workspaces do this briefly).  Files still belongs to this
        // Mac; use its home directory instead of dropping the root entirely.
        let localPath = path.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : path
        return .local(workspaceId: workspace.id, path: localPath)
    }
}
