import Foundation
import Testing
import BreeGit
@testable import BreeSidebarGit

@MainActor
@Suite struct RemoteDirectoryProvenanceTests {
    @Test func repeatedTrustedDirectoryPreservesMetadataUntilPathChanges() async {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: nil)
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main"))
        let clock = ManualGitPollClock()
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/project", displayLabel: nil
        )
        service.updateSurfaceGitBranch(
            workspaceId: workspaceId, panelId: panelId,
            branch: "remote-main", isDirty: false
        )

        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/project", displayLabel: nil
        )
        #expect(host.workspaces[0].state.panels[panelId]?.branch?.branch == "remote-main")
        #expect(!host.events.contains(.clearGitBranch(workspaceId, panelId)))

        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId, panelId: panelId,
            directory: "/srv/other", displayLabel: nil
        )
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(host.events.contains(.clearGitBranch(workspaceId, panelId)))
        #expect(await clock.recordedDurations.isEmpty)
        #expect(await reader.probedDirectories.isEmpty)
    }
}
