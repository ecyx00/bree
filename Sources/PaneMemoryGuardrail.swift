import AppKit
import CmuxFoundation
import CmuxSettings
import Foundation
import Observation

// MARK: - Monitor

/// One instance owns the background poll timer, scans every live pane each tick,
/// and attributes process-tree memory by controlling tty. The user-facing
/// warning badge and dismissible banner were removed in issue #6614, so the scan
/// now only maintains the engine's monitoring state (surfaced in DEBUG logs).
/// The heavy libproc scan runs off the main thread; only the small state updates
/// touch `@MainActor`.
@MainActor
@Observable
final class PaneMemoryGuardrail {
    static let shared = PaneMemoryGuardrail()

    private static let enabledSetting = SettingCatalog().terminal.runawayMemoryGuardrailEnabled
    private static let thresholdGBSetting = SettingCatalog().terminal.runawayMemoryGuardrailThresholdGB
    private static let pollInterval: TimeInterval = 4
    private static let scopedScanInterval: TimeInterval = 15
    private static let idleStride = 3
    private static let defaultThresholdGB: Double = 8
    private static let thresholdRangeGB: ClosedRange<Double> = 1...256
    private static let bytesPerGB = 1024.0 * 1024.0 * 1024.0

    /// Supplies the live pane set each tick (main-actor; reads ghostty/tty).
    @ObservationIgnored
    var paneProvider: (@MainActor () -> [PaneMemoryDescriptor])?

    @ObservationIgnored
    private var engine = PaneMemoryGuardrailEngine()
    @ObservationIgnored
    private let timerQueue = DispatchQueue(label: "com.cmux.pane-memory-guardrail", qos: .utility)
    @ObservationIgnored
    private var timer: DispatchSourceTimer?
    @ObservationIgnored
    private var isScanning = false
    @ObservationIgnored
    private var idleTickCount = 0
    @ObservationIgnored
    private var scanApplyTask: Task<Void, Never>?
    @ObservationIgnored
    private var lastScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample] = [:]
    @ObservationIgnored
    private var lastScopedScanAt = Date.distantPast

    @ObservationIgnored
    private var settingsObserver: (any NSObjectProtocol)?

    /// Begins following the enabled setting. No timer runs while it is off.
    func start() {
        guard settingsObserver == nil else { return }
        ResourceGuard.shared.start()
        settingsObserver = NotificationCenter.default.addUserDefaultsObserver(object: nil) { [weak self] in
            self?.syncTimerWithSetting()
        }
        syncTimerWithSetting()
    }

    /// Starts the poll timer when the setting is on and cancels it when off.
    func syncTimerWithSetting() {
        Self.applyTimerState(
            isEnabled: isTimerWanted,
            hasTimer: timer != nil,
            start: { startTimer() },
            stop: { stopTimer() }
        )
    }

    nonisolated static func applyTimerState(
        isEnabled: Bool,
        hasTimer: Bool,
        start: () -> Void,
        stop: () -> Void
    ) {
        if isEnabled, !hasTimer { start() }
        if !isEnabled, hasTimer { stop() }
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(
            deadline: .now() + Self.pollInterval,
            repeating: Self.pollInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        timer.resume()
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        clearAll()
    }

    // MARK: Settings

    private var isEnabled: Bool {
        Self.enabledSetting.value(in: .standard)
    }

    /// The Resource guard (Pulse suffix, thermal item, Pause) rides on the same
    /// sample; it is on unless `bree.resourceGuard.enabled` is set to false.
    private var resourceGuardEnabled: Bool {
        UserDefaults.standard.object(forKey: "bree.resourceGuard.enabled") as? Bool ?? true
    }

    private var isTimerWanted: Bool { isEnabled || resourceGuardEnabled }

    private func thresholdBytes() -> Int64 {
        let raw = Self.thresholdGBSetting.value(in: .standard)
        let gb = raw.isFinite ? min(max(raw, Self.thresholdRangeGB.lowerBound), Self.thresholdRangeGB.upperBound) : Self.defaultThresholdGB
        return Int64(gb * Self.bytesPerGB)
    }

    // MARK: Tick

    /// Samples right now (thermal event). Returns whether a scan was started.
    @discardableResult
    func scanNow() -> Bool {
        guard isTimerWanted, !isScanning, paneProvider != nil else { return false }
        return tick(force: true)
    }

    /// Idle cost: with nothing high, paused or close to high, and the legacy
    /// guardrail off, only every `idleStride`-th tick scans, and none while the
    /// app is in the background (the Pulse is not visible then).
    private func shouldSkipIdleTick() -> Bool {
        guard !isEnabled, !ResourceGuard.shared.wantsFastSampling else { return false }
        if !NSApplication.shared.isActive { return true }
        idleTickCount += 1
        return idleTickCount % Self.idleStride != 0
    }

    @discardableResult
    private func tick(force: Bool = false) -> Bool {
        guard isTimerWanted else {
            clearAll()
            return false
        }
        guard !isScanning, let paneProvider else { return false }
        if !force, shouldSkipIdleTick() { return false }
        let descriptors = paneProvider()
        guard !descriptors.isEmpty else {
            clearAll()
            return false
        }
        let thresholdBytes = thresholdBytes()
        let includeCMUXScope = consumeScopedScanIfDue(now: Date())
        isScanning = true
        let sampleTask = Task.detached(priority: .utility) {
            await Self.computeCachedSamples(
                descriptors: descriptors,
                thresholdBytes: thresholdBytes,
                includeCMUXScope: includeCMUXScope
            )
        }
        scanApplyTask = Task { @MainActor [weak self] in
            let batch = await sampleTask.value
            guard !Task.isCancelled else { return }
            self?.applySamples(
                batch,
                thresholdBytes: thresholdBytes
            )
        }
        return true
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated static func computeCachedSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        includeCMUXScope: Bool = false
    ) async -> PaneMemoryGuardrailSampleBatch {
        // The unscoped maximumAge must stay below pollInterval (4s): serving the
        // guardrail its own previous tick's snapshot would silently halve its
        // effective sampling cadence. 3s only allows reuse of a snapshot another
        // subsystem (autosave, task manager) captured moments earlier; when the
        // guardrail is the sole sampler it still captures fresh each tick, which
        // is the cheap no-details tier and the intended freshness floor.
        let snapshot = includeCMUXScope
            ? await CmuxTopProcessSnapshot.captureCached(includeCMUXScope: true, maximumAge: 5)
            : await CmuxTopProcessSnapshot.captureCached(includeCMUXScope: false, maximumAge: 3)
        let samples = computeSamples(
            descriptors: descriptors,
            thresholdBytes: thresholdBytes,
            snapshot: snapshot
        )
        let scopedOnlySamples = snapshot.hasCMUXScope
            ? computeScopedOnlySamples(
                descriptors: descriptors,
                thresholdBytes: thresholdBytes,
                snapshot: snapshot
            )
            : []
        return PaneMemoryGuardrailSampleBatch(
            samples: samples,
            scopedOnlySamplesByKey: Dictionary(
                scopedOnlySamples.map { ($0.key, $0) },
                uniquingKeysWith: { _, last in last }
            ),
            includesCMUXScope: snapshot.hasCMUXScope
        )
    }

    nonisolated static func computeSamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        snapshot: CmuxTopProcessSnapshot
    ) -> [PaneMemorySample] {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            var rootPIDs = snapshot.pids(forCMUXSurfaceID: descriptor.panelId)
            if let foregroundPID = descriptor.foregroundPID {
                rootPIDs.insert(foregroundPID)
            }
            if let ttyName = descriptor.ttyName {
                rootPIDs.formUnion(snapshot.pids(forTTYName: ttyName))
            }
            let pids = snapshot.expandedPIDs(rootPIDs: rootPIDs)
            let summary = snapshot.summary(for: pids)
            let pgids = memoryPressureProcessGroupIDs(
                in: snapshot,
                pids: pids,
                clearBytes: clearBytes
            )
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                memoryPressureProcessGroupIDs: pgids,
                foregroundCommand: foregroundCommand,
                cpuPercent: summary.cpuPercent,
                hottestProcessName: Self.hottestProcessName(in: snapshot, pids: pids)
            )
        }
    }

    nonisolated static func computeScopedOnlySamples(
        descriptors: [PaneMemoryDescriptor],
        thresholdBytes: Int64,
        snapshot: CmuxTopProcessSnapshot
    ) -> [PaneMemorySample] {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        return descriptors.map { descriptor in
            let cheapPIDs = snapshot.expandedPIDs(rootPIDs: cheapRootPIDs(for: descriptor, in: snapshot))
            let scopedPIDs = snapshot.expandedPIDs(rootPIDs: snapshot.pids(forCMUXSurfaceID: descriptor.panelId))
            let scopedOnlyPIDs = scopedPIDs.subtracting(cheapPIDs)
            let summary = snapshot.summary(for: scopedOnlyPIDs)
            let pgids = memoryPressureProcessGroupIDs(
                in: snapshot,
                pids: scopedOnlyPIDs,
                clearBytes: clearBytes
            )
            let foregroundCommand = descriptor.foregroundPID
                .flatMap { snapshot.process(pid: $0)?.name }
            return PaneMemorySample(
                descriptor: descriptor,
                memoryBytes: summary.memoryBytes,
                residentBytes: summary.residentBytes,
                memoryPressureProcessGroupIDs: pgids,
                foregroundCommand: foregroundCommand,
                cpuPercent: summary.cpuPercent,
                hottestProcessName: Self.hottestProcessName(in: snapshot, pids: scopedOnlyPIDs)
            )
        }
    }

    nonisolated static func hottestProcessName(
        in snapshot: CmuxTopProcessSnapshot,
        pids: Set<Int>
    ) -> String? {
        var best: (cpu: Double, memory: Int64, name: String)?
        for pid in pids {
            guard let process = snapshot.process(pid: pid), !process.name.isEmpty else { continue }
            if let current = best, (process.cpuPercent, process.memoryBytes) <= (current.cpu, current.memory) { continue }
            best = (process.cpuPercent, process.memoryBytes, process.name)
        }
        return best?.name
    }

    nonisolated static func cheapRootPIDs(
        for descriptor: PaneMemoryDescriptor,
        in snapshot: CmuxTopProcessSnapshot
    ) -> Set<Int> {
        var rootPIDs: Set<Int> = []
        if let foregroundPID = descriptor.foregroundPID {
            rootPIDs.insert(foregroundPID)
        }
        if let ttyName = descriptor.ttyName {
            rootPIDs.formUnion(snapshot.pids(forTTYName: ttyName))
        }
        return rootPIDs
    }

    private func consumeScopedScanIfDue(now: Date) -> Bool {
        guard now.timeIntervalSince(lastScopedScanAt) >= Self.scopedScanInterval else {
            return false
        }
        lastScopedScanAt = now
        return true
    }

    nonisolated static func reconcileScopedSamples(
        samples: [PaneMemorySample],
        currentScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        previousScopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample],
        includesCMUXScope: Bool,
        clearBytes: Int64
    ) -> (
        samples: [PaneMemorySample],
        scopedOnlySamplesByKey: [PaneMemoryPaneKey: PaneMemorySample]
    ) {
        let liveKeys = Set(samples.map(\.key))
        let previousScopedOnlySamplesByKey = previousScopedOnlySamplesByKey.filter { liveKeys.contains($0.key) }

        if includesCMUXScope {
            let scopedOnlySamplesByKey = currentScopedOnlySamplesByKey.filter {
                liveKeys.contains($0.key) && $0.value.memoryBytes > 0
            }
            return (samples, scopedOnlySamplesByKey)
        }

        let mergedSamples = samples.map { sample in
            guard let scopedOnlySample = previousScopedOnlySamplesByKey[sample.key] else {
                return sample
            }
            return addingScopedOnlySample(scopedOnlySample, to: sample)
        }
        return (mergedSamples, previousScopedOnlySamplesByKey)
    }

    nonisolated static func addingScopedOnlySample(
        _ scopedOnlySample: PaneMemorySample,
        to sample: PaneMemorySample
    ) -> PaneMemorySample {
        let memoryBytes = saturatingAdd(sample.memoryBytes, scopedOnlySample.memoryBytes)
        let residentBytes = saturatingAdd(sample.residentBytes, scopedOnlySample.residentBytes)
        let pgids = Array(Set(sample.memoryPressureProcessGroupIDs)
            .union(scopedOnlySample.memoryPressureProcessGroupIDs))
            .sorted()
        return PaneMemorySample(
            descriptor: sample.descriptor,
            memoryBytes: memoryBytes,
            residentBytes: residentBytes,
            memoryPressureProcessGroupIDs: pgids,
            foregroundCommand: sample.foregroundCommand,
            cpuPercent: sample.cpuPercent + scopedOnlySample.cpuPercent,
            hottestProcessName: sample.hottestProcessName ?? scopedOnlySample.hottestProcessName
        )
    }

    nonisolated private static func saturatingAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let result = lhs.addingReportingOverflow(rhs)
        return result.overflow ? Int64.max : result.partialValue
    }

    nonisolated static func memoryPressureProcessGroupIDs(
        in snapshot: CmuxTopProcessSnapshot,
        pids: Set<Int>,
        clearBytes: Int64
    ) -> [Int] {
        var totalBytes: Int64 = 0
        var bytesByProcessGroup: [Int: Int64] = [:]
        for pid in pids {
            guard let process = snapshot.process(pid: pid) else { continue }
            let memoryBytes = max(0, process.memoryBytes)
            totalBytes = totalBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : totalBytes + memoryBytes
            guard let processGroupID = process.processGroupID, processGroupID > 1 else { continue }
            let current = bytesByProcessGroup[processGroupID] ?? 0
            bytesByProcessGroup[processGroupID] = current.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : current + memoryBytes
        }

        guard totalBytes > clearBytes else { return [] }
        var selectedBytes: Int64 = 0
        var selectedProcessGroups: [Int] = []
        for (processGroupID, memoryBytes) in bytesByProcessGroup.sorted(by: {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }) where memoryBytes > 0 {
            selectedProcessGroups.append(processGroupID)
            selectedBytes = selectedBytes.addingReportingOverflow(memoryBytes).overflow
                ? Int64.max
                : selectedBytes + memoryBytes
            if totalBytes - selectedBytes < clearBytes { break }
        }
        return selectedProcessGroups.sorted()
    }

    private func applySamples(
        _ batch: PaneMemoryGuardrailSampleBatch,
        thresholdBytes: Int64
    ) {
        let clearBytes = Int64(Double(thresholdBytes) * PaneMemoryGuardrailEngine.clearFraction)
        let reconciled = Self.reconcileScopedSamples(
            samples: batch.samples,
            currentScopedOnlySamplesByKey: batch.scopedOnlySamplesByKey,
            previousScopedOnlySamplesByKey: lastScopedOnlySamplesByKey,
            includesCMUXScope: batch.includesCMUXScope,
            clearBytes: clearBytes
        )
        lastScopedOnlySamplesByKey = reconciled.scopedOnlySamplesByKey
        let samples = reconciled.samples
        isScanning = false
        scanApplyTask = nil

        // Keep the engine's monitoring state machine current. Its warn/clear
        // output no longer drives any UI (the badge + banner were removed in
        // issue #6614); it is retained for the DEBUG scan log below.
        ResourceGuard.shared.ingest(samples: samples)
        guard isEnabled else { return }
        let output = engine.ingest(samples: samples, thresholdBytes: thresholdBytes)
        emitScanDebugLog(samples: samples, output: output, thresholdBytes: thresholdBytes, includesCMUXScope: batch.includesCMUXScope)
    }

    private func emitScanDebugLog(
        samples: [PaneMemorySample],
        output: PaneMemoryGuardrailEngineOutput,
        thresholdBytes: Int64,
        includesCMUXScope: Bool
    ) {
#if DEBUG
        let maxBytes = samples.map(\.memoryBytes).max() ?? 0
        cmuxDebugLog(
            "paneMemGuard.scan panes=\(samples.count) maxMB=\(maxBytes / 1_048_576) " +
            "thresholdMB=\(thresholdBytes / 1_048_576) warned=\(output.warnedWorkspaceIds.count) " +
            "scope=\(includesCMUXScope ? 1 : 0)"
        )
#endif
    }

    // MARK: Clearing

    private func clearAll() {
        engine.reset()
        isScanning = false
        scanApplyTask?.cancel()
        scanApplyTask = nil
        lastScopedOnlySamplesByKey.removeAll()
        lastScopedScanAt = .distantPast
        ResourceGuard.shared.reset()
    }
}
