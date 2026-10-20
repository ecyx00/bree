import BreeCore
import BreePanes
import BreeSurfaceCatalogModel
import Foundation

extension Workspace: TerminalLinkOpenContainer {
    var terminalLinkContainerDebugName: String {
        "workspace:\(id.uuidString)"
    }

    func terminalLinkWorkingDirectory(for sourcePanelId: UUID) -> String? {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return nil }
        return CommandClickFileOpenRouter.resolveWorkingDirectory(
            workspace: self,
            surfaceId: target.surfaceID
        )
    }

    func terminalLinkIsRemoteTerminal(_ sourcePanelId: UUID) -> Bool {
        let surfaceID = surfaceOwnershipTarget(for: sourcePanelId)?.surfaceID
            ?? sourcePanelId
        return !canResolveTerminalPathsAgainstLocalFilesystem(
            surfaceID: surfaceID
        )
    }

    /// Resolve the connection from the terminal's authoritative owner, including native SSH projections.
    func remoteTerminalFilePreviewConfiguration(for surfaceID: UUID) -> WorkspaceRemoteConfiguration? {
        guard let configuration = remoteConfiguration else { return nil }
        guard isRemoteTerminalSurface(surfaceID) else { return nil }
        return configuration
    }

    func deferRemoteTerminalFileLinkOpen(sourcePanelId: UUID, rawValue: String) -> Bool {
        guard remoteConfiguration != nil,
              let target = surfaceOwnershipTarget(for: sourcePanelId),
              terminalLinkIsRemoteTerminal(target.surfaceID),
              let panel = terminalPanel(for: target.surfaceID) else { return false }
        _ = panel.hostedView.openRemoteFilePreview(tokens: [rawValue])
        return true
    }

    func deferTerminalFileLinkOpen(
        sourcePanelId: UUID,
        filePath: String,
        fallback: @escaping @MainActor @Sendable () -> Void
    ) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        CommandClickFileOpenRouter.deferredOpenFileInBree(
            workspace: self,
            preferredWorkspaceId: id,
            surfaceId: target.containerPanelID,
            filePath: filePath,
            fallback: fallback
        )
        return true
    }

    func openTerminalBrowserLink(url: URL, sourcePanelId: UUID, focus: Bool = true) -> Bool {
        guard let target = surfaceOwnershipTarget(for: sourcePanelId) else { return false }
        if let targetPane = preferredRightSideTargetPane(fromPanelId: target.containerPanelID) {
            return newBrowserSurface(inPane: targetPane, url: url, focus: focus) != nil
        }
        return newBrowserSplit(
            from: target.containerPanelID,
            orientation: .horizontal,
            url: url,
            focus: focus
        ) != nil
    }
}
