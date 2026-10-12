import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeApplyRaceTests {
    private func makeService(
        host: RecordingSidebarGitHost,
        reader: GatedMetadataReader,
        clock: ManualGitPollClock
    ) -> SidebarGitMetadataService {
        let service = SidebarGitMetadataService(
            workspaceGitMetadataReader: reader,
            gitMetadataService: GitMetadataService(),
            probeLimiter: WorkspaceGitMetadataProbeLimiter(limit: 2),
            clock: clock
        )
        service.attach(host: host)
        return service
    }

    @Test(.timeLimit(.minutes(1)))
    func remoteTrustWhileProbeInFlightDropsLocalSnapshotApply() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        host.workspaces[0].state.isRemote = true
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main"), gated: true)
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForProbe())

        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        await reader.openGate()

        #expect(await waitUntil {
            service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty
        })
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(!host.events.contains { event in
            if case .gitBranch = event { return true }
            return false
        })
    }

    @Test(.timeLimit(.minutes(1)))
    func snapshotFinishingDuringTerminalTypingDefersApplyAndRetries() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "local-main", isDirty: false),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForProbe())

        host.terminalTypingActive = true
        await reader.openGate()
        #expect(await waitUntil("deferred snapshot retry sleeper") {
            await clock.recordedDurations.count >= 2
        })
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)

        host.terminalTypingActive = false
        let clockDriver = Task { @MainActor in
            while !Task.isCancelled {
                await clock.resumeNext()
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        defer { clockDriver.cancel() }
        #expect(await reader.waitForProbe(count: 2))
        #expect(await waitUntil {
            host.workspaces[0].state.panels[panelId]?.branch?.branch == "local-main"
        })
    }
}
