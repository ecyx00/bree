import BreeSurfaceCatalogModel
import Foundation
import BreeTerminal
import Testing
#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// The surface catalog: one identity per resource, zero or more projections, one open path.
@MainActor
@Suite
struct SurfaceCatalogTests {
    private struct TestTimeout: Error {}
    /// Local destinations each test registers so ownership checks resolve a live workspace.
    private let live = LiveWorkspaceFixture()

    @MainActor
    private final class RenameEventRecorder {
        var events: [String] = []
    }

    /// Lets timeout behavior be tested without waiting on wall-clock time.
    private final class ImmediateClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant

        private let lock = NSLock()
        private var sleepCount = 0
        private let onSleep: @Sendable (Int) -> Void

        init(onSleep: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.onSleep = onSleep
        }

        var now: Instant { .now }
        var minimumResolution: Duration { .zero }

        func sleep(until _: Instant, tolerance _: Duration?) async throws {
            await Task.yield()
            let count = lock.withLock {
                sleepCount += 1
                return sleepCount
            }
            onSleep(count)
        }
    }

    /// Await a test signal without allowing a broken setup to hang the test process.
    private nonisolated func awaitFirst<T: Sendable>(
        _ stream: AsyncStream<T>,
        timeout: Duration = .seconds(1)
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let value = await iterator.next() else { throw TestTimeout() }
                return value
            }
            group.addTask {
                try await ContinuousClock().sleep(for: timeout)
                throw TestTimeout()
            }
            defer { group.cancelAll() }
            guard let value = try await group.next() else { throw TestTimeout() }
            return value
        }
    }

    @MainActor
    private final class MaterializeGate {
        private(set) var entered = false
        private var callerEnded = false
        private var enteredContinuation: CheckedContinuation<Bool, Never>?
        private var releaseContinuations: [CheckedContinuation<Void, Never>] = []

        /// Returns true once the provider enters `materialize`, or false when `caller`
        /// finishes first because it threw before reaching the provider. Without the
        /// second signal that setup failure parks the test until the suite time limit,
        /// and every time-limit hit relaunches the whole app host.
        func waitUntilEntered<Success: Sendable>(orEndOf caller: Task<Success, any Error>) async -> Bool {
            if entered { return true }
            Task { @MainActor [weak self] in
                _ = await caller.result
                self?.finishCaller()
            }
            return await withCheckedContinuation { continuation in
                if entered || callerEnded {
                    continuation.resume(returning: entered)
                } else {
                    enteredContinuation = continuation
                }
            }
        }

        private func finishCaller() {
            callerEnded = true
            guard !entered, let continuation = enteredContinuation else { return }
            enteredContinuation = nil
            continuation.resume(returning: false)
        }

        func block() async {
            entered = true
            enteredContinuation?.resume(returning: true)
            enteredContinuation = nil
            await withCheckedContinuation { continuation in
                releaseContinuations.append(continuation)
            }
        }

        func release() {
            let continuations = releaseContinuations
            releaseContinuations.removeAll()
            continuations.forEach { $0.resume() }
        }
    }

    private final class FakeProvider: SurfaceProvider {
        let machine: SurfaceMachineID
        var info: SurfaceMachineInfo
        var materialized: [(SurfaceResourceID, SurfaceDestination)] = []
        var ended: [SurfaceProjection] = []
        var discarded: [SurfaceProjection] = []
        var discardInvocations: [SurfaceProjection] = []
        var onDiscard: ((SurfaceProjection) -> Void)?
        var onMaterialize: (() -> Void)?
        var materializationPreserved = false
        /// Every materialize makes a new pane, as real providers do; a fixed id would let
        /// the catalog's projection set collapse a deliberate second pane into the first.
        var nextPanel = UUID()
        var materializeGate: MaterializeGate?

        init(machine: SurfaceMachineID) {
            self.machine = machine
            info = SurfaceMachineInfo(id: machine, name: machine.rawValue, status: "running", image: nil, hasDesktop: false, memoryMb: nil, diskMb: nil, linkState: .connected, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil)
        }

        func refresh() async {}

        func materialize(_ resource: SurfaceResource, at destination: SurfaceDestination, focus: Bool) async throws -> SurfaceProjection {
            materialized.append((resource.id, destination))
            await materializeGate?.block()
            let panelID = nextPanel
            nextPanel = UUID()
            onMaterialize?()
            return SurfaceProjection(resource: resource.id, workspaceID: destination.workspaceID, panelID: panelID)
        }

        var closedTerminals: [SurfaceResourceID] = []
        var closedRemoteWorkspaces: [String] = []
        var renamedRemoteWorkspaces: [(id: String, name: String)] = []
        /// Interleaved order of the remote mutations, so tests can assert terminals
        /// die BEFORE their workspace closes (the delete contract).
        var remoteMutationLog: [String] = []

        func closeTerminal(_ id: SurfaceResourceID) async throws {
            closedTerminals.append(id)
            remoteMutationLog.append("terminal:\(id.key)")
        }

        func closeRemoteWorkspace(id: String) async throws {
            closedRemoteWorkspaces.append(id)
            remoteMutationLog.append("workspace:\(id)")
        }

        func renameRemoteWorkspace(id: String, name: String) async throws {
            renamedRemoteWorkspaces.append((id: id, name: name))
        }

        func projectionDidEnd(_ projection: SurfaceProjection) { ended.append(projection) }

        var projectionsRestoredCalls = 0
        private var projectionsRestoredWaiter: CheckedContinuation<Void, Never>?
        func projectionsRestored() {
            projectionsRestoredCalls += 1
            projectionsRestoredWaiter?.resume()
            projectionsRestoredWaiter = nil
        }

        func waitForProjectionsRestored() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                projectionsRestoredWaiter = continuation
            }
        }

        @discardableResult
        func discardMaterialization(_ projection: SurfaceProjection) -> Bool {
            discardInvocations.append(projection)
            onDiscard?(projection)
            guard !materializationPreserved else { return true }
            discarded.append(projection)
            return false
        }
    }

    private func terminal(_ machine: SurfaceMachineID, _ key: String, title: String = "shell", remoteView: SurfaceRemoteView? = nil) -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: title, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: remoteView?.workspace, remoteViews: remoteView.map { [$0] }, port: nil, url: nil)
    }

    @Test func `Restoring a projection of a published resource wakes its provider`() async throws {
        // A restored device pane is a blank placeholder until its provider
        // materializes the mirror. When the provider published the resource
        // before the workspace restored (the link was already up, or a closed
        // tab is reopened), nothing else republishes, so the catalog must ask
        // the provider itself. If the resource publishes after restore, the
        // pending projection must wake the provider too, or a remote browser
        // remains stuck on the restore-time unavailable card.
        let catalog = SurfaceCatalog(live: live)
        let machine = SurfaceMachineID(rawValue: "device:6f0d1c5e-2b5a-4d6e-9c1a-1c2d3e4f5a6b@nightly")
        let provider = FakeProvider(machine: machine)
        catalog.register(provider)
        let published = terminal(machine, "6C272F23-5E1F-45DB-A7DB-874F94C34E86")
        catalog.replaceResources([published], on: machine)
        let workspaceID = live.id()
        let restoredPanelID = UUID()
        catalog.restore(
            [SurfaceProjectionRecord(panelID: restoredPanelID, resource: published.id, remoteWorkspaceID: nil, remoteTabID: nil)],
            workspaceID: workspaceID
        )
        #expect(catalog.projections(of: published.id).map(\.panelID) == [restoredPanelID])
        #expect(provider.projectionsRestoredCalls == 1)

        let unpublished = terminal(machine, "1EDA3953-15EC-43B6-9E9C-500454782170")
        let latePanelID = UUID()
        catalog.restore(
            [SurfaceProjectionRecord(panelID: latePanelID, resource: unpublished.id, remoteWorkspaceID: nil, remoteTabID: nil)],
            workspaceID: workspaceID
        )
        #expect(catalog.projections(of: unpublished.id).isEmpty)
        #expect(provider.projectionsRestoredCalls == 1)

        // The provider's first graph can arrive after restore. Resolving the
        // pending record must wake it just like the already-published path.
        let restoredWaiter = Task { await provider.waitForProjectionsRestored() }
        await Task.yield()
        catalog.replaceResources([published, unpublished], on: machine, from: provider)
        #expect(catalog.projections(of: unpublished.id).map(\.panelID) == [latePanelID])
        await restoredWaiter.value
        #expect(provider.projectionsRestoredCalls == 2)
    }

    @Test func `Resource ID round trips through the wire form`() {
        let id = SurfaceResourceID(machine: .remote("vivid-newt"), kind: .browser, key: "port:8000/https://x.y/z")
        #expect(id.rawValue == "vivid-newt/browser/port:8000/https://x.y/z")
        #expect(SurfaceResourceID(rawValue: id.rawValue) == id)
        #expect(SurfaceResourceID(rawValue: "local/terminal/ABC")?.machine == .local)
        #expect(SurfaceResourceID(rawValue: "local/nope/x") == nil)
        #expect(SurfaceResourceID(rawValue: "local/terminal/") == nil)
    }

    @Test func `Project materializes once and reuses the open pane`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))
        var focused: [SurfaceProjection] = []
        catalog.focusProjection = { focused.append($0) }

        let ws = live.id()
        let first = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split))
        #expect(!first.reused)
        #expect(provider.materialized.count == 1)
        #expect(catalog.projections(of: term.id).count == 1)
        #expect(catalog.snapshot.isOpen(term.id))

        let second = try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .tab))
        #expect(second.reused)
        #expect(second.projection == first.projection)
        #expect(provider.materialized.count == 1, "reuse must not materialize a second pane")
        #expect(focused == [first.projection])

        let third = try await catalog.project(term.id, into: .workspace(id: ws, placement: .split), reuseExisting: false)
        #expect(!third.reused)
        #expect(catalog.projections(of: term.id).count == 2)
    }

    @Test func `Workspace-scoped reuse ignores panes in other workspaces`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "display_like")
        catalog.replaceResources([term], on: .remote("vivid-newt"))
        var focused: [SurfaceProjection] = []
        catalog.focusProjection = { focused.append($0) }

        let wsA = live.id()
        let wsB = live.id()
        let a = try await catalog.project(term.id, into: .workspace(id: wsA, placement: .split), reuseInWorkspace: wsA)
        #expect(!a.reused)

        // A pane in wsA neither satisfies wsB's scoped open nor steals focus:
        // the resource materializes in wsB (the workspace-Desktop-row bug).
        let b = try await catalog.project(term.id, into: .workspace(id: wsB, placement: .split), reuseInWorkspace: wsB)
        #expect(!b.reused)
        #expect(b.projection.workspaceID == wsB)
        #expect(provider.materialized.count == 2)
        #expect(focused.isEmpty, "no jump to the other workspace's pane")

        // Scoped reuse still reuses within its own workspace…
        let again = try await catalog.project(term.id, into: .workspace(id: wsB, placement: .split), reuseInWorkspace: wsB)
        #expect(again.reused)
        #expect(again.projection == b.projection)
        #expect(focused == [b.projection])

        // …and an unscoped call keeps the global open-or-focus jump.
        let global = try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .tab))
        #expect(global.reused)
        #expect(provider.materialized.count == 2)
    }

    @Test func `Concurrent reuse waits for the in-flight materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))
        let destination = SurfaceDestination.workspace(id: live.id(), placement: .split)

        let first = Task { try await catalog.project(term.id, into: destination) }
        try #require(await gate.waitUntilEntered(orEndOf: first), "the project call ended before reaching the provider")

        let (secondStarted, secondStartedContinuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let second = Task { @MainActor in
            secondStartedContinuation.yield(())
            secondStartedContinuation.finish()
            return try await catalog.project(term.id, into: destination)
        }
        _ = try await awaitFirst(secondStarted)
        #expect(provider.materialized.count == 1, "a concurrent reuse must share the pending provider call")

        gate.release()
        let firstResult = try await first.value
        let secondResult = try await second.value
        #expect(!firstResult.reused)
        #expect(secondResult.reused)
        #expect(firstResult.projection == secondResult.projection)
        #expect(catalog.projections(of: term.id).count == 1)
    }

    @Test func `An adopted projection wins a materialization race`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))
        let destination = SurfaceDestination.workspace(id: live.id(), placement: .split)

        let project = Task { try await catalog.project(term.id, into: destination) }
        try #require(await gate.waitUntilEntered(orEndOf: project), "the project call ended before reaching the provider")
        let adopted = SurfaceProjection(resource: term.id, workspaceID: UUID(), panelID: UUID())
        catalog.record(adopted)
        gate.release()

        let result = try await project.value
        #expect(result.reused)
        #expect(result.projection == adopted)
        #expect(provider.discarded.count == 1)
        #expect(provider.discarded.first?.panelID != adopted.panelID)
        #expect(catalog.projections(of: term.id) == [adopted])
    }

    @Test func `Cancelling the last project caller detaches without leaking a late materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        let (discarded, discardedContinuation) = AsyncStream<SurfaceProjection>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        provider.onDiscard = { projection in
            discardedContinuation.yield(projection)
            discardedContinuation.finish()
        }
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))

        let project = Task { try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)) }
        try #require(await gate.waitUntilEntered(orEndOf: project), "the project call ended before reaching the provider")

        let (cancellationResult, cancellationResultContinuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let observer = Task { @MainActor in
            do {
                _ = try await project.value
                cancellationResultContinuation.yield(false)
            } catch is CancellationError {
                cancellationResultContinuation.yield(true)
            } catch {
                cancellationResultContinuation.yield(false)
            }
            cancellationResultContinuation.finish()
        }
        project.cancel()
        let cancelledBeforeRelease = try await awaitFirst(cancellationResult)
        #expect(cancelledBeforeRelease, "cancelling the caller must not wait for the provider")

        gate.release()
        await observer.value
        _ = try await awaitFirst(discarded)
        #expect(catalog.projections.isEmpty)
        #expect(provider.discarded.count == 1, "a late provider result must close the pane after the last caller cancels")
    }

    @Test func `Cancellation at provider completion discards an unclaimed projection`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))

        var project: Task<SurfaceProjectionMaterialization.Result, any Error>?
        let task = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        }
        project = task
        try #require(await gate.waitUntilEntered(orEndOf: task), "the project call ended before reaching the provider")
        provider.onMaterialize = { project?.cancel() }
        gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        provider.onMaterialize = nil
        #expect(catalog.projections.isEmpty)
        #expect(provider.discarded.count == 1)
    }

    @Test func `A removed local resource is not resurrected by a late materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .local)
        provider.materializationPreserved = true
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.local, "term_1")
        catalog.replaceResources([term], on: .local)

        provider.onMaterialize = { catalog.remove(term.id) }
        let project = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        }
        try #require(await gate.waitUntilEntered(orEndOf: project), "the project call ended before reaching the provider")
        gate.release()

        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await project.value
        }
        #expect(catalog.projections.isEmpty)
        #expect(provider.discardInvocations.count == 1)
    }

    @Test func `A preserving materialization remains recorded when its caller cancels`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .local)
        provider.materializationPreserved = true
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.local, "term_1")
        catalog.replaceResources([term], on: .local)

        var project: Task<SurfaceProjectionMaterialization.Result, any Error>?
        let task = Task { @MainActor in
            try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        }
        project = task
        try #require(await gate.waitUntilEntered(orEndOf: task), "the project call ended before reaching the provider")
        provider.onMaterialize = { project?.cancel() }
        gate.release()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
        provider.onMaterialize = nil
        #expect(catalog.projections(of: term.id).count == 1)
        #expect(provider.discardInvocations.count == 1)
        #expect(provider.discarded.isEmpty)
    }

    @Test func `Unregistering cancels in-flight materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        provider.materializeGate = gate
        catalog.register(provider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))

        let project = Task { try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)) }
        try #require(await gate.waitUntilEntered(orEndOf: project), "the project call ended before reaching the provider")
        catalog.unregister(machine: .remote("vivid-newt"))
        gate.release()

        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await project.value
        }
        #expect(catalog.projections.isEmpty)
    }

    @Test func `Registering a replacement provider retires its old materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let oldProvider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))

        let oldProject = Task {
            try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        }
        try #require(await gate.waitUntilEntered(orEndOf: oldProject), "the project call ended before reaching the provider")

        let replacementProvider = FakeProvider(machine: .remote("vivid-newt"))
        catalog.register(replacementProvider)
        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await oldProject.value
        }

        let newProject = Task {
            try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        }
        gate.release()
        let result = try await newProject.value
        #expect(replacementProvider.materialized.count == 1)
        #expect(oldProvider.discarded.count == 1)
        #expect(result.projection == catalog.projections(of: term.id).first)
    }

    @Test func `A replacement provider does not join retired materialization`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let oldProvider = FakeProvider(machine: .remote("vivid-newt"))
        let gate = MaterializeGate()
        oldProvider.materializeGate = gate
        catalog.register(oldProvider)
        let term = terminal(.remote("vivid-newt"), "term_1")
        catalog.replaceResources([term], on: .remote("vivid-newt"))

        let oldProject = Task { try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)) }
        try #require(await gate.waitUntilEntered(orEndOf: oldProject), "the project call ended before reaching the provider")
        catalog.unregister(machine: .remote("vivid-newt"))
        await #expect(throws: SurfaceCatalogError.unknownResource(term.id)) {
            try await oldProject.value
        }

        let newProvider = FakeProvider(machine: .remote("vivid-newt"))
        catalog.register(newProvider)
        catalog.replaceResources([term], on: .remote("vivid-newt"))
        let newProject = Task { try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)) }

        gate.release()
        let result = try await newProject.value
        #expect(newProvider.materialized.count == 1)
        #expect(oldProvider.discarded.count == 1)
        #expect(result.projection == catalog.projections(of: term.id).first)
    }

    @Test func `Ending a projection keeps the remote resource and tells the provider`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("m"))
        catalog.register(provider)
        let term = terminal(.remote("m"), "term_1")
        catalog.replaceResources([term], on: .remote("m"))
        let projection = try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)).projection

        catalog.endProjections(panelID: projection.panelID)
        #expect(catalog.projections(of: term.id).isEmpty)
        #expect(catalog.snapshot.resources.first { $0.id == term.id } != nil, "closing a pane never destroys a remote resource")
        #expect(provider.ended == [projection])
    }

    @Test func `Moving a pane moves its projection`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .local)
        catalog.register(provider)
        let term = terminal(.local, "ABC")
        catalog.replaceResources([term], on: .local)
        let projection = try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split)).projection
        let other = UUID()
        catalog.moveProjections(panelID: projection.panelID, to: other)
        #expect(catalog.projection(forPanel: projection.panelID)?.workspaceID == other)
    }

    @Test("A second save while a Mac is disconnected preserves its remote projection")
    func pendingMacProjectionSurvivesAnotherSave() {
        let machine = SurfaceMachineID.device(SurfaceDeviceInstanceID(deviceID: UUID().uuidString, tag: "restore-test"))
        let catalog = SurfaceCatalog(live: live)
        let workspace = live.id()
        let record = SurfaceProjectionRecord(
            panelID: UUID(), resource: SurfaceResourceID(machine: machine, kind: .terminal, key: UUID().uuidString),
            remoteWorkspaceID: "mac-workspace", remoteTabID: "mac-tab"
        )
        catalog.restore([record], workspaceID: workspace)
        #expect(catalog.projectionRecords(forWorkspace: workspace) == [record])
        let secondLaunch = SurfaceCatalog(live: live)
        secondLaunch.restore(catalog.projectionRecords(forWorkspace: workspace), workspaceID: workspace)
        #expect(secondLaunch.projectionRecords(forWorkspace: workspace) == [record])
    }

    @Test func `Restored projections resolve when the provider reports the resource`() {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("m"))
        catalog.register(provider)
        let ws = live.id(), panel = UUID()
        let id = SurfaceResourceID(machine: .remote("m"), kind: .terminal, key: "term_9")
        catalog.restore([SurfaceProjectionRecord(panelID: panel, resource: id)], workspaceID: ws)
        #expect(!catalog.snapshot.isOpen(id), "unknown until the link reports it")

        catalog.replaceResources([terminal(.remote("m"), "term_9")], on: .remote("m"))
        #expect(catalog.projection(forPanel: panel) == SurfaceProjection(resource: id, workspaceID: ws, panelID: panel))
        #expect(catalog.projectionRecords(forWorkspace: ws) == [SurfaceProjectionRecord(panelID: panel, resource: id)])
    }

    @Test func `Snapshot orders local first, then by name and workspace index`() {
        let catalog = SurfaceCatalog(live: live)
        catalog.register(FakeProvider(machine: .remote("zeta")))
        catalog.register(FakeProvider(machine: .remote("alpha")))
        catalog.register(FakeProvider(machine: .local))
        var t1 = terminal(.remote("alpha"), "term_b"); t1.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_1", name: "1", index: 1, focused: false)
        var t0 = terminal(.remote("alpha"), "term_a"); t0.remoteWorkspace = SurfaceRemoteWorkspace(id: "ws_0", name: "0", index: 0, focused: true)
        catalog.replaceResources([t1, t0], on: .remote("alpha"))
        let snapshot = catalog.snapshot
        #expect(snapshot.machines.map { $0.id } == [.local, .remote("alpha"), .remote("zeta")])
        #expect(snapshot.resources(on: .remote("alpha")).map { $0.id.key } == ["term_a", "term_b"])
    }

    @Test func `Unregistering a machine drops its resources and projections`() async throws {
        let catalog = SurfaceCatalog(live: live)
        let provider = FakeProvider(machine: .remote("m"))
        catalog.register(provider)
        let term = terminal(.remote("m"), "term_1")
        catalog.replaceResources([term], on: .remote("m"))
        #expect(catalog.hasResources(on: .remote("m")))
        _ = try await catalog.project(term.id, into: .workspace(id: live.id(), placement: .split))
        catalog.unregister(machine: .remote("m"))
        #expect(catalog.snapshot.resources.isEmpty)
        #expect(!catalog.hasResources(on: .remote("m")))
        #expect(catalog.snapshot.projections.isEmpty)
        #expect(catalog.provider(for: .remote("m")) == nil)
    }

    private func workspaceTerminal(_ machine: SurfaceMachineID, _ key: String, workspace: SurfaceRemoteWorkspace?) -> SurfaceResource {
        SurfaceResource(id: SurfaceResourceID(machine: machine, kind: .terminal, key: key), title: key, detail: "/root", lifecycle: .running, agent: nil, remoteWorkspace: workspace, port: nil, url: nil)
    }

}

// MARK: - Optimistic layout open (https://github.com/ecyx00/bree/issues/12537)

extension SurfaceCatalogTests {
}
