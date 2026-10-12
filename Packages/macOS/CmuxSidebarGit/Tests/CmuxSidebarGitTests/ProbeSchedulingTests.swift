import Foundation
import Testing
import CmuxGit
@testable import CmuxSidebarGit

@MainActor
@Suite struct ProbeSchedulingTests {
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

    /// The initial probe's retry offsets [0, 0.5, 1.5, 3, 6, 10] are absolute
    /// offsets from scheduling time, walked as sequential clock gaps. The
    /// reader gate stays closed so no snapshot applies mid-walk (an applied
    /// non-repo snapshot would legitimately finish the probe and cancel the
    /// remaining retries).
    @Test func initialProbeWalksRetryOffsetsAsSequentialGaps() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/probe-test")
        host.workspaces[0].state.isRemote = true
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .nonRepository, gated: true)
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        var durations: [TimeInterval] = []
        for _ in 0..<6 {
            await clock.waitForSleeper()
            durations = await clock.recordedDurations
            await clock.resumeNext()
        }
        #expect(durations == [0, 0.5, 1.0, 1.5, 3.0, 4.0])
        await reader.openGate()
    }

    @Test func initialProbeDefersWhileTerminalTypingIsActive() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/probe-typing")
        host.terminalTypingActive = true
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "main", isDirty: false), gated: true)
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        await clock.waitForSleeper()
        await clock.resumeNext()
        await Task.yield()
        #expect(await reader.probedDirectories.isEmpty)
        for _ in 0..<5 { await Task.yield() }
        await clock.waitForSleeper()
        #expect(await clock.recordedDurations.last == SidebarGitMetadataService.terminalTypingQuietInterval)

        host.terminalTypingActive = false
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForProbe())
        await reader.openGate()
    }

    /// A remote terminal panel never schedules the initial local probe.
    @Test func remoteTerminalPanelSkipsInitialProbe() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: clock
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )

        #expect(await clock.recordedDurations.isEmpty)
        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
    }

    @Test func remoteWorkspaceBranchReportDoesNotScheduleLocalProbe() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/remote")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(metadata: .repository(branch: "local-main", isDirty: true))
        let service = makeService(
            host: host,
            reader: reader,
            clock: clock
        )

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "remote-main",
            isDirty: false
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == SidebarPanelGitBranch(
            branch: "remote-main",
            isDirty: false
        ))
        service.refreshTrackedWorkspaceGitMetadata(reason: "manualRefresh")
        #expect(await clock.recordedDurations.isEmpty)
        #expect(await reader.probedDirectories.isEmpty)
        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
    }

    /// Metadata received before directory provenance is established cannot be
    /// attributed to the first trusted path (including a restored local fallback).
    @Test(arguments: [nil, "/local/fallback"] as [String?])
    func firstTrustedRemoteDirectoryClearsUnboundMetadata(previousDirectory: String?) async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: previousDirectory)
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "local-main")),
            clock: clock
        )

        service.updateSurfaceGitBranch(
            workspaceId: workspaceId,
            panelId: panelId,
            branch: "remote-main",
            isDirty: false
        )
        service.updateRemoteSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/srv/project",
            displayLabel: nil
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(host.events.contains(.clearGitBranch(workspaceId, panelId)))
    }

    @Test func trustedRemoteDirectoryChangeClearsStaleMetadataWithoutLocalProbe() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/srv/old")
        host.workspaces[0].state.isRemote = true
        host.workspaces[0].state.panels[panelId]?.hasTrustedRemoteDirectory = true
        host.workspaces[0].state.panels[panelId]?.isRemoteTerminal = true
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "old-main",
            isDirty: true
        )
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .repository(branch: "local-main")),
            clock: clock
        )

        service.updateSurfaceDirectory(
            workspaceId: workspaceId,
            panelId: panelId,
            directory: "/srv/new",
            displayLabel: nil
        )

        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(host.events.contains(.clearGitBranch(workspaceId, panelId)))
        service.refreshTrackedWorkspaceGitMetadata(reason: "manualRefresh")
        #expect(await clock.recordedDurations.isEmpty)
    }

    /// A filesystem event that arrives while a probe is already in flight is a
    /// freshness signal independent of whether the stale snapshot changes
    /// visible sidebar state. It should coalesce to one follow-up probe.
    @Test(.timeLimit(.minutes(1)))
    func inFlightFilesystemEventChainsOneProbeRerun() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        host.workspaces[0].state.panels[panelId]?.branch = SidebarPanelGitBranch(
            branch: "feature/x",
            isDirty: true
        )
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "feature/x", isDirty: true),
            gated: true
        )
        let service = makeService(host: host, reader: reader, clock: clock)

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await reader.waitForTrackedPathEventGenerationProbe())

        service.scheduleWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "filesystemEvent"
        )
        await clock.waitForSleeper()
        await clock.resumeNext()
        #expect(await waitUntil { service.workspaceGitProbeRerunPending(for: key) })
        #expect(service.workspaceGitProbeRerunPending(for: key))
        await reader.openGate()

        _ = await waitUntil("three immediate probe sleeps") {
            await clock.recordedDurations.filter { $0 == 0 }.count >= 3
        }
        let immediateProbeSleeps = await clock.recordedDurations.filter { $0 == 0 }.count

        #expect(immediateProbeSleeps == 3)
        service.clearWorkspaceGitProbes(workspaceId: workspaceId)
    }

    /// A probe whose panel directory changes while the snapshot is in flight
    /// is dropped: no projection lands for the stale directory.
    @Test(.timeLimit(.minutes(1)))
    func directoryChangeWhileProbeInFlightDropsTheApply() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/old")
        let clock = ManualGitPollClock()
        let reader = GatedMetadataReader(
            metadata: .repository(branch: "main"),
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

        // Wait until the snapshot probe has started reading, then move the
        // panel to a different directory before letting the read finish.
        #expect(await reader.waitForProbe())
        host.workspaces[0].state.panels[panelId]?.directory = "/tmp/new"
        await reader.openGate()

        // The stale apply must clear the probe rather than project "main".
        #expect(await waitUntil {
            service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty
        })
        #expect(host.workspaces[0].state.panels[panelId]?.branch == nil)
        #expect(!host.events.contains { event in
            if case .gitBranch = event { return true }
            return false
        })
    }

    /// Disabling the git watch setting tears the subsystem down: all sidebar
    /// git metadata cleared.
    @Test func disablingWatchSettingClearsMetadata() async throws {
        let host = RecordingSidebarGitHost()
        host.addWorkspace(panelDirectory: "/tmp/repo")
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )

        host.gitMetadataActivity = .disabled
        service.sidebarGitMetadataWatchSettingsDidChange()

        #expect(host.events.contains(.clearAllGitMetadata))
    }

    /// Closing a workspace clears its probe state.
    @Test func clearWorkspaceGitProbesDropsTrackingForThatWorkspace() async throws {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let clock = ManualGitPollClock()
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository, gated: true),
            clock: clock
        )

        service.scheduleInitialWorkspaceGitMetadataRefreshIfPossible(
            workspaceId: workspaceId,
            panelId: panelId,
            reason: "test"
        )
        await clock.waitForSleeper()
        #expect(!service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)

        service.clearWorkspaceGitProbes(workspaceId: workspaceId)

        #expect(service.activeWorkspaceGitProbePanelIds(workspaceId: workspaceId).isEmpty)
    }

    @Test func resetAllWorkspaceGitProbeTrackingClearsTrackedDirectoryAndSignaturesOnce() {
        let host = RecordingSidebarGitHost()
        let (workspaceId, panelId) = host.addWorkspace(panelDirectory: "/tmp/repo")
        let service = makeService(
            host: host,
            reader: GatedMetadataReader(metadata: .nonRepository),
            clock: ManualGitPollClock()
        )
        let key = WorkspaceGitProbeKey(workspaceId: workspaceId, panelId: panelId)
        service.workspaceGitTrackedDirectoryByKey[key] = "/tmp/repo"
        service.workspaceGitCleanIndexSignatureByKey[key] = "index"
        service.workspaceGitCleanIndexContentSignatureByKey[key] = "content"
        service.workspaceGitHeadSignatureByKey[key] = "head"

        service.resetAllWorkspaceGitProbeTracking()

        #expect(service.workspaceGitTrackedDirectoryByKey.isEmpty)
        #expect(service.workspaceGitCleanIndexSignatureByKey.isEmpty)
        #expect(service.workspaceGitCleanIndexContentSignatureByKey.isEmpty)
        #expect(service.workspaceGitHeadSignatureByKey.isEmpty)
    }
}
