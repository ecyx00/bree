import BreeSurfaceCatalogModel
import Foundation
import Observation
/// The single owner of surface identities and projections on this Mac.
///
/// Rules that hold by construction:
/// - a resource exists in exactly one provider's machine and appears once in `resources`;
/// - a projection is (resource, workspace, panel) and is recorded only by the catalog, when
///   a provider materializes a pane or when an existing pane is adopted at startup/restore;
/// - `project(_:into:)` is the only open path: if the resource is already projected and
///   the caller allows reuse, the existing pane is focused instead of duplicated.
@MainActor
@Observable
final class SurfaceCatalog {
    private typealias MaterializationKey = SurfaceProjectionMaterialization.Key
    static let shared = SurfaceCatalog()
    /// A provider call with no remaining caller must not occupy a resource forever when the
    /// provider ignores task cancellation. The deadline starts only after the last caller
    /// detaches, so a slow but observed materialization is still allowed to finish normally.
    nonisolated static let defaultAbandonedMaterializationTimeout: Duration = .seconds(30)
    nonisolated static let defaultRetiredMaterializationRetention: Duration = .seconds(30)
    nonisolated static let defaultCompletedMaterializationRetention: Duration = .seconds(30)
    /// The coordinator never allows more than this many tasks from one machine to remain tracked
    /// while cancellation is unresolved. This prevents one unhealthy machine from blocking
    /// unrelated machines while also bounding repeated provider replacements.
    nonisolated static let defaultMaximumTrackedMaterializations = 16
    static let didChangeNotification = Notification.Name("bree.surfaces.didChange")
    private(set) var machines: [SurfaceMachineID: SurfaceMachineInfo] = [:]
    private(set) var resources: [SurfaceResourceID: SurfaceResource] = [:]
    private(set) var projections: Set<SurfaceProjection> = [] { didSet { noteProjectionChanges(from: oldValue) } }
    var projectionVersions: [SurfaceMachineID: UInt64] = [:]; var projectionMachinesByWorkspace: [UUID: Set<SurfaceMachineID>] = [:]
    /// Resource IDs grouped by machine so providers can answer presence checks
    /// without sorting the full catalog snapshot on every refresh.
    private(set) var resourceIDsByMachine: [SurfaceMachineID: Set<SurfaceResourceID>] = [:]
    private var providers: [SurfaceMachineID: any SurfaceProvider] = [:]
    /// Materializations are asynchronous, so actor reentrancy can otherwise let two callers
    /// pass the reuse check before either provider has returned a projection.
    private var inFlightProjects: [MaterializationKey: SurfaceProjectionMaterialization] = [:]
    /// Tokens for operations that can still report after the catalog moved on. The provider is
    /// held by the provider task itself and passed to the late-result callback, so these sets do
    /// not keep disconnected providers alive. Every token has one bounded eviction task.
    private var retiredMaterializationTokens: Set<UUID> = []
    private var retiredMaterializationEvictionTasks: [UUID: Task<Void, Never>] = [:]
    private var trackedMaterializationTokens: Set<UUID> = []
    private var trackedMaterializationMachines: [UUID: SurfaceMachineID] = [:]
    private var trackedMaterializationCounts: [SurfaceMachineID: Int] = [:]
    private let retiredMaterializationRetention: Duration
    private let completedMaterializationRetention: Duration
    private let abandonedMaterializationTimeout: Duration
    private let maximumTrackedMaterializations: Int
    private let materializationClock: any Clock<Duration>
    var pendingRestoredProjections = SurfaceProjectionRestoreStore()
    /// Focus/select behavior the app uses to bring an existing projection forward.
    var focusProjection: ((SurfaceProjection) -> Void)?
    /// Test seam: resolves local workspaces before the app delegate does.
    @ObservationIgnored var workspaceLookup: ((UUID) -> Workspace?)?
    init(
        abandonedMaterializationTimeout: Duration = SurfaceCatalog.defaultAbandonedMaterializationTimeout,
        retiredMaterializationRetention: Duration = SurfaceCatalog.defaultRetiredMaterializationRetention,
        completedMaterializationRetention: Duration = SurfaceCatalog.defaultCompletedMaterializationRetention,
        maximumTrackedMaterializations: Int = SurfaceCatalog.defaultMaximumTrackedMaterializations,
        materializationClock: any Clock<Duration> = ContinuousClock()
    ) {
        precondition(abandonedMaterializationTimeout > .zero)
        precondition(retiredMaterializationRetention > .zero)
        precondition(completedMaterializationRetention > .zero)
        precondition(maximumTrackedMaterializations > 0)
        self.abandonedMaterializationTimeout = abandonedMaterializationTimeout
        self.retiredMaterializationRetention = retiredMaterializationRetention
        self.completedMaterializationRetention = completedMaterializationRetention
        self.maximumTrackedMaterializations = maximumTrackedMaterializations
        self.materializationClock = materializationClock
    }


    // MARK: Providers
    func register(_ provider: any SurfaceProvider) {
        if let previous = providers[provider.machine], previous !== provider {
            let inFlightKeys = inFlightProjects.keys.filter { $0.machine == provider.machine }
            for key in inFlightKeys {
                cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(key.resource))
            }
        }
        providers[provider.machine] = provider
        machines[provider.machine] = provider.info
        notifyChange(for: provider.machine)
    }

    func unregister(machine: SurfaceMachineID) {
        let inFlightKeys = inFlightProjects.keys.filter { $0.machine == machine }
        for key in inFlightKeys {
            cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(key.resource))
        }
        providers[machine] = nil
        machines[machine] = nil
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        pendingRestoredProjections.remove(machine: machine)
        projections = projections.filter { $0.resource.machine != machine }
        projectionVersions[machine] = nil
        notifyChange(for: machine)
    }

    func provider(for machine: SurfaceMachineID) -> (any SurfaceProvider)? {
        providers[machine]
    }

    /// Only the registered provider of a remote machine (or the local provider,
    /// registered at launch) may write about it. A provider the fleet has just
    /// pruned can still finish an in-flight refresh and write its machine back;
    /// accepting that write brings a machine the backend already destroyed back
    /// as a sidebar row nothing can refresh or delete.
    private func accepts(writeFor machine: SurfaceMachineID, from source: (any SurfaceProvider)? = nil) -> Bool {
        if machine.isLocal { return true }
        guard let registered = providers[machine] else {
#if DEBUG
            breeDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=unregistered")
#endif
            return false
        }
        // Remote providers refresh asynchronously. Once a replacement is
        // registered, a late callback from the retired instance must not write
        // through the replacement's catalog entry. Callers that do not have a
        // provider (legacy socket paths) retain the current-provider behavior.
        if let source,
           (source.machine != machine || ObjectIdentifier(registered) != ObjectIdentifier(source)) {
#if DEBUG
            breeDebugLog("catalog.write.ignored machine=\(machine.rawValue) reason=retired-provider")
#endif
            return false
        }
        return true
    }

    /// Refreshes one machine without waiting on unrelated remote links. A
    /// machine-scoped CLI request must not be held hostage by another VM's
    /// reconnect timeout.
    func refresh(machine: SurfaceMachineID, force: Bool = false) async {
        guard let provider = providers[machine] else { return }
        await provider.refresh(force: force)
    }
    func refreshAll(force: Bool = false) async {
        for provider in providers.values {
            await provider.refresh(force: force)
        }
    }

    // MARK: Resources (called by providers)

    /// Replace everything the catalog knows about one machine. Projections whose resource
    /// disappeared are kept only if the pane still exists (the pane shows an exited/unknown
    /// terminal until it is closed); the caller prunes dead panes through `endProjection`.
    /// `from` identifies the provider that produced the snapshot, when one is available.
    @discardableResult
    func replaceResources(_ list: [SurfaceResource], on machine: SurfaceMachineID, info: SurfaceMachineInfo? = nil, from source: (any SurfaceProvider)? = nil) -> Bool {
        guard accepts(writeFor: machine, from: source) else { return false }
        for id in resourceIDsByMachine[machine] ?? [] { resources[id] = nil }
        resourceIDsByMachine[machine] = nil
        for resource in list {
            precondition(resource.machine == machine, "resource \(resource.id) reported by the wrong provider")
            resources[resource.id] = resource
            resourceIDsByMachine[machine, default: []].insert(resource.id)
        }
        if let info { machines[machine] = info }
        let restoredProjectionIDs = resolvePendingRestoredProjections(on: machine)
        notifyChange(for: machine)
        if !restoredProjectionIDs.isEmpty { providers[machine]?.projectionsRestored(resources: restoredProjectionIDs) }
        return true
    }

    /// Insert or replace one resource. A Remote provider may identify itself with `from` so a
    /// result from a retired provider cannot overwrite a replacement registration.
    func upsert(_ resource: SurfaceResource, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: resource.machine, from: source) else { return }
        resources[resource.id] = resource
        resourceIDsByMachine[resource.machine, default: []].insert(resource.id)
        let restoredProjectionIDs = resolvePendingRestoredProjections(on: resource.machine)
        notifyChange(for: resource.machine)
        if !restoredProjectionIDs.isEmpty { providers[resource.machine]?.projectionsRestored(resources: restoredProjectionIDs) }
    }

    /// Remove a resource, optionally validating the provider that requested the mutation.
    func remove(_ id: SurfaceResourceID, from source: (any SurfaceProvider)? = nil) {
        guard accepts(writeFor: id.machine, from: source) else { return }
        resources[id] = nil
        resourceIDsByMachine[id.machine]?.remove(id)
        if resourceIDsByMachine[id.machine]?.isEmpty == true {
            resourceIDsByMachine[id.machine] = nil
        }
        notifyChange(for: id.machine)
    }


    // MARK: Projections

    /// The only open path. Reuses an existing projection when `reuseExisting` is set and one
    /// exists (focusing it), otherwise asks the provider to materialize a pane.
    ///
    /// `reuseInWorkspace` narrows reuse to projections in that local workspace: a pane
    /// showing the resource in ANOTHER workspace neither satisfies the open nor steals
    /// focus — the resource materializes at `destination` instead. A workspace's own
    /// Desktop row uses this so "open this workspace's screen" never teleports to a
    /// different workspace's VNC pane. Nil keeps the global open-or-focus jump.
    @discardableResult
    func project(_ id: SurfaceResourceID, into destination: SurfaceDestination, focus: Bool = true, reuseExisting: Bool = true, reuseInWorkspace: UUID? = nil, remoteView: SurfaceRemoteView? = nil) async throws -> (projection: SurfaceProjection, reused: Bool) {
        try validateOwnership(of: [id], at: destination)
        guard let resource = resources[id] else { throw SurfaceCatalogError.unknownResource(id) }
        // Resolve the opaque tab id against the current graph before any async
        // provider work. A stale view must fail, never silently attach to a
        // different placement after a concurrent daemon update.
        let resolvedRemoteView: SurfaceRemoteView?
        if let remoteView {
                guard let current = resource.remoteViews?.first(where: { $0.tabID == remoteView.tabID }) else {
                    throw SurfaceCatalogError.unavailable(
                        id,
                        reason: "remote tab \(remoteView.tabID) is no longer present"
                    )
                }
                guard current.workspace.id == remoteView.workspace.id else {
                    throw SurfaceCatalogError.unavailable(
                        id,
                        reason: "remote tab \(remoteView.tabID) moved to workspace \(current.workspace.id)"
                    )
                }
                resolvedRemoteView = current
        } else {
            resolvedRemoteView = nil
        }
        let materializationKey = MaterializationKey(resource: id, remoteTabID: resolvedRemoteView?.tabID, workspaceID: reuseInWorkspace)
        if reuseExisting, let existing = projections.first(where: {
            guard $0.resource == id, reuseInWorkspace == nil || $0.workspaceID == reuseInWorkspace else { return false }
            // An explicit remote view is a placement identity. Reusing a pane
            // attached to a different tab would make a later rename hit the
            // wrong daemon object.
            // An explicit placement must match an explicit projection. A legacy
            // projection with no tab id is not safe to reuse because it may be
            // showing another tab of the same terminal.
            return resolvedRemoteView == nil || $0.remoteTabID == resolvedRemoteView?.tabID
        }) {
            try claimCompletedMaterializationIfNeeded(materializationKey, projection: existing)
            let resolved = attachRemoteView(resolvedRemoteView, to: existing)
            if focus { focusProjection?(resolved) }
            return (resolved, true)
        }
        guard let provider = providers[id.machine] else { throw SurfaceCatalogError.noProvider(id.machine) }

        // The materialization key includes the optional workspace, so scoped
        // opens coalesce only with other opens for that same workspace.
        if reuseExisting {
            let waiterID = UUID()
            let result = try await withTaskCancellationHandler {
                try await awaitMaterialization(
                    key: materializationKey,
                    id: id,
                    resource: resource,
                    remoteView: resolvedRemoteView,
                    provider: provider,
                    destination: destination,
                    focus: focus,
                    waiterID: waiterID
                )
            } onCancel: { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    self.cancelInFlightProjectWaiter(materializationKey, waiterID: waiterID)
                }
            }
            return try finalizeMaterializationWaiter(
                key: materializationKey,
                id: id,
                waiterID: waiterID,
                result: result,
                focus: focus
            )
        }

        let projection = try await provider.materializeValidated(resource, remoteView: resolvedRemoteView, at: destination, focus: focus)
        try validateMaterializationOwnership(projection, provider: provider)
        guard !Task.isCancelled, providers[id.machine] === provider else {
            provider.discardMaterialization(projection)
            throw CancellationError()
        }
        record(projection)
        return (projection, false)
    }

    private func awaitMaterialization(
        key: MaterializationKey,
        id: SurfaceResourceID,
        resource: SurfaceResource,
        remoteView: SurfaceRemoteView?,
        provider: any SurfaceProvider,
        destination: SurfaceDestination,
        focus: Bool,
        waiterID: UUID
    ) async throws -> SurfaceProjectionMaterialization.Result {
        try await withCheckedThrowingContinuation { continuation in
            guard !Task.isCancelled else {
                continuation.resume(throwing: CancellationError())
                return
            }

            if let inFlight = inFlightProjects[key], let completedProjection = inFlight.completedProjection {
                var completed = inFlight
                completed.pendingAcknowledgements.insert(waiterID)
                inFlightProjects[key] = completed
                continuation.resume(returning: (projection: completedProjection, reused: true))
                return
            }
            if let inFlight = inFlightProjects[key], inFlight.provider !== provider {
                cancelInFlightProject(key, error: SurfaceCatalogError.unknownResource(id))
            }
            if var inFlight = inFlightProjects[key] {
                inFlight.abandoned = false
                inFlight.abandonmentDeadlineTask?.cancel()
                inFlight.abandonmentDeadlineTask = nil
                inFlight.waiters[waiterID] = (reused: true, continuation: continuation)
                inFlightProjects[key] = inFlight
                return
            }

            guard trackedMaterializationCounts[provider.machine, default: 0] < maximumTrackedMaterializations else {
                continuation.resume(throwing: SurfaceCatalogError.unavailable(id, reason: "materialization capacity exhausted"))
                return
            }

            let token = UUID()
            trackMaterialization(token, for: provider)
            let task = Task { @MainActor [weak self] in
                do {
                    try self?.validateOwnership(of: [id], at: destination)
                    let projection = try await provider.materializeValidated(resource, remoteView: remoteView, at: destination, focus: focus)
                    try self?.validateMaterializationOwnership(projection, provider: provider)
                    self?.finishInFlightProject(key, token: token, provider: provider, result: .success(projection))
                } catch {
                    self?.finishInFlightProject(key, token: token, provider: provider, result: .failure(error))
                }
            }
            inFlightProjects[key] = SurfaceProjectionMaterialization(
                token: token,
                provider: provider,
                task: task,
                abandonmentDeadlineTask: nil,
                waiters: [waiterID: (reused: false, continuation: continuation)],
                completedProjection: nil,
                completionOwnsProjection: false,
                pendingAcknowledgements: [],
                completionCleanupTask: nil
            )
        }
    }

    private func finishInFlightProject(
        _ key: MaterializationKey,
        token: UUID,
        provider: any SurfaceProvider,
        result: Result<SurfaceProjection, any Error>
    ) {
        let id = key.resource
        guard var inFlight = inFlightProjects[key], inFlight.token == token else {
            releaseTrackedMaterialization(token)
            if retiredMaterializationTokens.remove(token) != nil {
                retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
            }
            if case .success(let projection) = result {
                cleanupMaterialization(projection, from: provider)
            }
            return
        }
        inFlight.abandonmentDeadlineTask?.cancel()
        releaseTrackedMaterialization(token)

        switch result {
        case .success(let projection):
            guard !inFlight.abandoned else {
                inFlightProjects[key] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                return
            }
            guard resources[id] != nil else {
                inFlightProjects[key] = nil
                cleanupMaterialization(projection, from: inFlight.provider)
                resume(inFlight.waiters, throwing: SurfaceCatalogError.unknownResource(id))
                return
            }
            let returnedProjection: SurfaceProjection
            let ownsProjection: Bool
            if let registered = projections.first(where: { $0.panelID == projection.panelID && $0.resource == id }) {
                // The pane bound its resource while the provider configured it. It is still this
                // operation's pane: finish placement exactly like a fresh materialization.
                returnedProjection = registered
                ownsProjection = true
            } else if let existing = projections.first(where: {
                $0.resource == id
                    && (key.remoteTabID == nil || $0.remoteTabID == key.remoteTabID)
                    && (key.workspaceID == nil || $0.workspaceID == key.workspaceID)
            }) {
                cleanupMaterialization(projection, from: inFlight.provider)
                returnedProjection = existing
                ownsProjection = false
            } else {
                record(projection)
                returnedProjection = projection
                ownsProjection = true
            }
            let waiters = inFlight.waiters
            inFlight.waiters.removeAll()
            inFlight.completedProjection = returnedProjection
            inFlight.completionOwnsProjection = ownsProjection
            inFlight.pendingAcknowledgements = Set(waiters.keys)
            inFlight.completionCleanupTask = completedMaterializationCleanupTask(key: key, token: token)
            inFlightProjects[key] = inFlight
            for waiter in waiters.values {
                waiter.continuation.resume(
                    returning: (projection: returnedProjection, reused: ownsProjection ? waiter.reused : true)
                )
            }
            if waiters.isEmpty {
                discardUnclaimedMaterializationIfEmpty(key)
            }
        case .failure(let error):
            inFlightProjects[key] = nil
            resume(inFlight.waiters, throwing: error)
        }
    }

    /// Finish the caller side of a successful materialization as one actor-isolated operation.
    /// The cancellation check and acknowledgement share the same turn, so cancellation cannot
    /// leave a newly recorded pane ownerless between those two actions.
    private func finalizeMaterializationWaiter(
        key: MaterializationKey,
        id: SurfaceResourceID,
        waiterID: UUID,
        result: SurfaceProjectionMaterialization.Result,
        focus: Bool
    ) throws -> SurfaceProjectionMaterialization.Result {
        guard !Task.isCancelled else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw CancellationError()
        }
        guard resources[id] != nil else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw SurfaceCatalogError.unknownResource(id)
        }
        guard let projection = self.projection(forPanel: result.projection.panelID),
              projection.resource == id, projection.workspaceID == result.projection.workspaceID else {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            throw SurfaceCatalogError.unavailable(id, reason: "projection closed while opening")
        }
        acknowledgeMaterialization(key, waiterID: waiterID)
        if result.reused, focus { focusProjection?(projection) }
        return (projection, result.reused)
    }

    private func acknowledgeMaterialization(_ key: MaterializationKey, waiterID: UUID) {
        guard let inFlight = inFlightProjects[key], inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.contains(waiterID) else { return }
        // One accepted result gives the pane an owner. The other resumed callers no longer need
        // bookkeeping because their later cancellation must not close a pane this caller owns.
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[key] = nil
    }

    private func claimCompletedMaterializationIfNeeded(
        _ key: MaterializationKey,
        projection: SurfaceProjection
    ) throws {
        let match = inFlightProjects.first { $0.value.completedProjection?.resource == projection.resource && $0.value.completedProjection?.panelID == projection.panelID }
        guard let (matchedKey, inFlight) = match,
              matchedKey == key || inFlight.completedProjection?.panelID == projection.panelID else { return }
        guard !Task.isCancelled else { throw CancellationError() }
        inFlight.completionCleanupTask?.cancel()
        inFlightProjects[matchedKey] = nil
    }

    private func cancelCompletedMaterialization(_ key: MaterializationKey, waiterID: UUID) {
        guard var inFlight = inFlightProjects[key],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.remove(waiterID) != nil else { return }
        if inFlight.pendingAcknowledgements.isEmpty {
            inFlightProjects[key] = nil
            inFlight.completionCleanupTask?.cancel()
            if inFlight.completionOwnsProjection {
                cleanupRecordedMaterialization(inFlight)
            }
        } else {
            inFlightProjects[key] = inFlight
        }
    }

    /// Handles the defensive empty-set case without retaining a completed operation. Normal
    /// provider completions always have at least one waiter unless every caller cancelled first.
    private func discardUnclaimedMaterializationIfEmpty(_ key: MaterializationKey) {
        guard let inFlight = inFlightProjects[key],
              inFlight.completedProjection != nil,
              inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func completedMaterializationCleanupTask(key: MaterializationKey, token: UUID) -> Task<Void, Never> {
        let timeout = completedMaterializationRetention
        let clock = materializationClock
        return Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireCompletedMaterialization(key, token: token)
        }
    }

    /// A caller can be dropped without cancellation, so completion bookkeeping needs a bounded
    /// recovery path. An acknowledged result is removed before this deadline; otherwise the
    /// operation is treated as unclaimed and any pane owned by it is discarded.
    private func expireCompletedMaterialization(_ key: MaterializationKey, token: UUID) {
        guard let inFlight = inFlightProjects[key],
              inFlight.token == token,
              inFlight.completedProjection != nil,
              !inFlight.pendingAcknowledgements.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.completionCleanupTask?.cancel()
        if inFlight.completionOwnsProjection {
            cleanupRecordedMaterialization(inFlight)
        }
    }

    private func cleanupRecordedMaterialization(_ materialization: SurfaceProjectionMaterialization) {
        guard let projection = materialization.completedProjection else { return }
        let provider = materialization.provider
        let current = projections.first {
            $0.resource == projection.resource && $0.panelID == projection.panelID
        }
        let preserved = provider.discardMaterialization(current ?? projection)
        // A completed operation owns only the projection it recorded. If that projection was
        // removed before cleanup, a preserving provider must not resurrect the closed pane.
        guard let current, !preserved else { return }
        projections.remove(current)
        notifyChange(for: projection.resource.machine)
    }

    /// Cleans up a provider result that arrived after its catalog operation was retired. A
    /// preserving provider moved an existing pane, so its late result must remain represented.
    private func cleanupMaterialization(_ projection: SurfaceProjection, from provider: any SurfaceProvider) {
        let preserved = provider.discardMaterialization(projection)
        guard preserved,
              providers[projection.resource.machine] === provider,
              resources[projection.resource] != nil,
              !projections.contains(where: {
                  $0.resource == projection.resource && $0.panelID == projection.panelID
              }) else { return }
        record(projection)
    }

    private func trackMaterialization(_ token: UUID, for provider: any SurfaceProvider) {
        trackedMaterializationTokens.insert(token)
        trackedMaterializationMachines[token] = provider.machine
        trackedMaterializationCounts[provider.machine, default: 0] += 1
    }

    private func releaseTrackedMaterialization(_ token: UUID) {
        guard trackedMaterializationTokens.remove(token) != nil,
              let machine = trackedMaterializationMachines.removeValue(forKey: token) else { return }
        let remaining = (trackedMaterializationCounts[machine] ?? 1) - 1
        if remaining > 0 {
            trackedMaterializationCounts[machine] = remaining
        } else {
            trackedMaterializationCounts[machine] = nil
        }
    }

    private func cancelInFlightProjectWaiter(_ key: MaterializationKey, waiterID: UUID) {
        guard let current = inFlightProjects[key] else { return }
        if current.completedProjection != nil {
            cancelCompletedMaterialization(key, waiterID: waiterID)
            return
        }
        var inFlight = current
        guard let waiter = inFlight.waiters.removeValue(forKey: waiterID) else { return }
        if inFlight.waiters.isEmpty {
            // Cancellation detaches this caller, but the provider operation stays single-flight
            // until it settles. Provider cancellation is cooperative, so starting another call
            // here would allow an unbounded number of remote panes to race the first one. The
            // abandonment deadline below is the recovery boundary for a provider that never
            // observes cancellation.
            inFlight.abandoned = true
            let token = inFlight.token
            let timeout = abandonedMaterializationTimeout
            let clock = materializationClock
            inFlight.abandonmentDeadlineTask = Task { @MainActor [weak self, clock] in
                do {
                    try await clock.sleep(for: timeout)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.expireAbandonedMaterialization(key, token: token)
            }
        }
        inFlightProjects[key] = inFlight
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Retire a detached provider operation after its bounded recovery window. New callers can
    /// start a fresh operation immediately while the old task drains cooperatively.
    private func expireAbandonedMaterialization(_ key: MaterializationKey, token: UUID) {
        guard let inFlight = inFlightProjects[key],
              inFlight.token == token,
              inFlight.completedProjection == nil,
              inFlight.abandoned,
              inFlight.waiters.isEmpty else { return }
        inFlightProjects[key] = nil
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(token)
        inFlight.task.cancel()
    }

    /// Keep only a short-lived token for a retired operation. A late success is always stale,
    /// so `finishInFlightProject` can discard it directly with the provider captured by its task
    /// even after this token has been evicted.
    private func retireMaterialization(_ token: UUID) {
        precondition(trackedMaterializationTokens.contains(token))
        retiredMaterializationTokens.insert(token)
        let timeout = retiredMaterializationRetention
        let clock = materializationClock
        let evictionTask = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.evictRetiredMaterialization(token)
        }
        guard retiredMaterializationTokens.contains(token) else {
            evictionTask.cancel()
            return
        }
        retiredMaterializationEvictionTasks[token] = evictionTask
    }

    private func evictRetiredMaterialization(_ token: UUID) {
        guard retiredMaterializationTokens.remove(token) != nil else { return }
        retiredMaterializationEvictionTasks.removeValue(forKey: token)?.cancel()
        // The provider may ignore cancellation and never report a result. Once the bounded
        // retirement window ends, stop counting that operation against its machine. A later
        // completion releases the token idempotently and still receives stale-result cleanup.
        releaseTrackedMaterialization(token)
    }

    private func cancelInFlightProject(_ key: MaterializationKey, error: any Error) {
        guard let current = inFlightProjects[key], current.completedProjection == nil,
              let inFlight = inFlightProjects.removeValue(forKey: key) else { return }
        inFlight.abandonmentDeadlineTask?.cancel()
        retireMaterialization(inFlight.token)
        inFlight.task.cancel()
        let waiters = inFlight.waiters
        resume(waiters, throwing: error)
    }

    private func resume(
        _ waiters: [UUID: (reused: Bool, continuation: CheckedContinuation<SurfaceProjectionMaterialization.Result, Error>)],
        throwing error: any Error
    ) {
        for waiter in waiters.values {
            waiter.continuation.resume(throwing: error)
        }
    }

    /// Records a materialized pane and reconciles it with the installed graph.
    func record(_ projection: SurfaceProjection) {
        consumePendingProjectionIfMaterialized(projection)
        insertSupersedingLocalPlaceholder(projection)
        notifyChange(for: projection.resource.machine)
    }

    /// A restored placeholder yields to its native pane without authoring a layout edit.
    func replaceProjection(
        _ previous: SurfaceProjection,
        withPanel panelID: UUID,
        in workspaceID: UUID,
        preservingSavedPlacement: Bool = false
    ) {
        // Exact restores retain saved identity; legacy replacements may infer one live view.
        let views = preservingSavedPlacement ? nil : resources[previous.resource]?.remoteViews
        let exactView = views?.first { $0.tabID == previous.remoteTabID }
        let view = exactView ?? (views?.count == 1 ? views?.first : nil)
        let savedWorkspace = views == nil ? previous.remoteWorkspaceID : nil
        let savedTab = views == nil ? previous.remoteTabID : nil
        endProjections(panelID: previous.panelID)
        record(SurfaceProjection(
            resource: previous.resource,
            workspaceID: workspaceID,
            panelID: panelID,
            remoteWorkspaceID: view?.workspace.id ?? savedWorkspace,
            remoteTabID: view?.tabID ?? savedTab
        ))
    }

    /// A pane can show one resource. When a remote resource is projected into a pane the
    /// local provider already registered as a plain local terminal (the pane is created
    /// first, then attached), the local placeholder yields: its projection ends and the
    /// local resource disappears, so the pane counts once, as the remote terminal.
    func insertSupersedingLocalPlaceholder(_ projection: SurfaceProjection) {
        if !projection.resource.machine.isLocal {
            for existing in projections where existing.panelID == projection.panelID && existing.resource.machine.isLocal {
                projections.remove(existing)
                resources[existing.resource] = nil
                resourceIDsByMachine[existing.resource.machine]?.remove(existing.resource)
                if resourceIDsByMachine[existing.resource.machine]?.isEmpty == true {
                    resourceIDsByMachine[existing.resource.machine] = nil
                }
            }
        }
        projections.insert(projection)
    }

    /// A pane went away. Remote resources live on.
    func endProjections(panelID: UUID) {
        let pendingMachine = pendingRestoredProjections.machineOwningPanel(panelID); let removedPending = pendingRestoredProjections.remove(panelID: panelID)
        let ended = projections.filter { $0.panelID == panelID }
        guard !ended.isEmpty || removedPending else { return }
        projections.subtract(ended)
        for projection in ended {
            providers[projection.resource.machine]?.projectionDidEnd(projection)
        }
        for projection in ended { notifyChange(for: projection.resource.machine) }
        if ended.isEmpty, removedPending, let pendingMachine { notifyChange(for: pendingMachine) }
    }

    func moveProjections(panelID: UUID, to workspaceID: UUID) {
        let pendingBefore = pendingRestoredProjections.projection(forPanel: panelID); let movedPending = pendingRestoredProjections.move(panelID: panelID, to: workspaceID)
        let moved = projections.filter { $0.panelID == panelID && $0.workspaceID != workspaceID }
        guard !moved.isEmpty || movedPending else { return }
        projections.subtract(moved)
        for var projection in moved {
            projection.workspaceID = workspaceID
            projections.insert(projection)
        }
        for projection in moved { notifyChange(for: projection.resource.machine) }; if movedPending, let machine = pendingBefore?.resource.machine { notifyChange(for: machine) }
    }

    /// Applies one accepted graph's coordinate changes in O(changed projections).
    func reconcileRemotePlacements(_ replacements: [SurfaceProjection: SurfaceProjection]) {
        guard !replacements.isEmpty else { return }
        for (previous, updated) in replacements where projections.contains(previous) {
            projections.remove(previous)
            projections.insert(updated)
        }
        for replacement in replacements.values {
            notifyChange(for: replacement.resource.machine)
        }
    }

    /// Updates every view of an exact tab together; a late result cannot replace a
    /// different resource that has since taken over the same local panel.
    func setRemotePlacement(for source: SurfaceProjection, workspaceID: String?, tabID: String?) {
        // Only views whose coordinates change; an unchanged placement notifies nobody.
        let matching = projections.filter {
            $0.resource == source.resource && ($0.panelID == source.panelID
                || (tabID != nil && $0.remoteTabID == tabID))
                && ($0.remoteWorkspaceID != workspaceID || $0.remoteTabID != tabID)
        }
        guard !matching.isEmpty else { return }
        var next = projections
        for var projection in matching {
            next.remove(projection)
            projection.remoteWorkspaceID = workspaceID
            projection.remoteTabID = tabID
            next.insert(projection)
        }
        projections = next
        notifyChange(for: source.resource.machine)
    }

    /// Fills a legacy projection's missing remote coordinates, or replaces a
    /// stale coordinate only when the caller explicitly supplied the same tab.
    /// The set remains the single owner of projection identity.
    @discardableResult
    private func attachRemoteView(_ view: SurfaceRemoteView?, to projection: SurfaceProjection) -> SurfaceProjection {
        guard let view else { return projection }
        let tabID = view.tabID
        guard projection.remoteTabID == nil || projection.remoteTabID == tabID else { return projection }
        var updated = projection
        updated.remoteWorkspaceID = view.workspace.id
        updated.remoteTabID = tabID
        // Reconcile reprojects through here. Rewriting unchanged coordinates
        // would request the next reconcile of this machine, forever.
        guard updated != projection else { return projection }
        // One assignment, so observers never see the pane briefly unprojected.
        var next = projections
        next.remove(projection)
        next.insert(updated)
        projections = next
        notifyChange(for: updated.resource.machine)
        return updated
    }

    func resource(forPanel panelID: UUID) -> SurfaceResource? {
        projection(forPanel: panelID).flatMap { resources[$0.resource] }
    }

    func machineInfo(for machine: SurfaceMachineID) -> SurfaceMachineInfo? {
        machines[machine]
    }

    // MARK: Restore
    /// Records persisted projections for panes the session restore recreated. The projection
    /// becomes live as soon as the provider reports the resource again (a remote terminal
    /// after the link reconnects); local resources are re-registered by the local provider
    /// with the same panel-derived key, so they resolve immediately.
    ///
    /// Session restore rebuilds a workspace before its `TabManager` publishes it, so no
    /// app lookup can resolve the destination yet; that caller passes the workspace it is
    /// restoring as `restoringWorkspace` and ownership is checked against it directly.
    func restore(_ records: [SurfaceProjectionRecord], workspaceID: UUID, restoringWorkspace: Workspace? = nil) {
        let destination = restoringWorkspace.flatMap { $0.id == workspaceID ? $0 : nil }
        for record in records {
            if let destination {
                if ownershipRejection(for: [record.resource], policy: destination.surfaceOwnershipPolicy) != nil { return }
            } else {
                do { try validateOwnership(of: [record.resource], at: .workspace(id: workspaceID, placement: .tab)) }
                catch { return }
            }
        }
        var wokenMachines = Set<SurfaceMachineID>()
        for record in records {
            if resources[record.resource] != nil {
                wokenMachines.insert(record.resource.machine)
                pendingRestoredProjections.remove(panelID: record.panelID)
                insertSupersedingLocalPlaceholder(SurfaceProjection(resource: record.resource, workspaceID: workspaceID, panelID: record.panelID, remoteWorkspaceID: record.remoteWorkspaceID, remoteTabID: record.remoteTabID))
            } else {
                pendingRestoredProjections.stage(record, workspaceID: workspaceID)
            }
        }
        for record in records {
            notifyChange(for: record.resource.machine)
        }
        for machine in wokenMachines { providers[machine]?.projectionsRestored() }
    }

    func projectionRecords(forWorkspace workspaceID: UUID) -> [SurfaceProjectionRecord] {
        var records = projections
            .filter { $0.workspaceID == workspaceID }
            .map {
                SurfaceProjectionRecord(
                    panelID: $0.panelID,
                    resource: $0.resource,
                    remoteWorkspaceID: $0.remoteWorkspaceID,
                    remoteTabID: $0.remoteTabID
                )
            }
        pendingRestoredProjections.mergeRecords(into: &records, for: workspaceID)
        return records.sorted { $0.panelID.uuidString < $1.panelID.uuidString }
    }

    /// Returns whether at least one resource is currently published for a machine.
    /// This is intentionally unsorted and does not materialize a snapshot.
    func hasResources(on machine: SurfaceMachineID) -> Bool {
        !(resourceIDsByMachine[machine]?.isEmpty ?? true)
    }
    var projectedMachines: Set<SurfaceMachineID> { Set(projections.map(\.resource.machine)) }

    /// Returns the current resources projected in a workspace in one pass. Rename
    /// fallback logic only needs membership, not the stable panel ordering exposed by
    /// `projectionRecords(forWorkspace:)`.
    func resourcesProjected(inWorkspace workspaceID: UUID) -> [SurfaceResource] {
        projections.compactMap { projection in
            guard projection.workspaceID == workspaceID else { return nil }
            return resources[projection.resource]
        }
    }

    /// Resolves staged projections for a newly published resource graph and returns only
    /// the resource IDs that became live, so providers can rebind those panes without a
    /// full-machine reprojection scan.
    @discardableResult
    private func resolvePendingRestoredProjections(on machine: SurfaceMachineID) -> Set<SurfaceResourceID> {
        var resolvedResourceIDs = Set<SurfaceResourceID>()
        let resolved = pendingRestoredProjections.takeResolvable(
            machine: machine,
            availableResources: Set(resources.keys),
            isAllowed: canRestoreProjection
        )
        for projection in resolved {
            insertSupersedingLocalPlaceholder(projection)
            resolvedResourceIDs.insert(projection.resource)
        }
        return resolvedResourceIDs
    }

    /// Observers get at most one notification per main-runloop turn: a burst of upserts
    /// (a busy shell retitling, a snapshot replacing dozens of resources) collapses into
    /// one hop, so the sidebar rebuilds once instead of once per mutation.
    var changeNotificationPending = false; var pendingChangedMachines: Set<SurfaceMachineID> = []; var pendingGlobalChange = false

}
