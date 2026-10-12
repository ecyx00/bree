import AppKit
import Bonsplit
import Combine
import Darwin
import Foundation

/// Decides when a workspace's process trees count as "high". Pure value type so
/// the hysteresis is testable without timers, libproc or ghostty.
///
/// - RAM: high from `ramEnterBytes` (2 GB), clears below `clearFraction` of it.
/// - CPU: high after `cpuEnterPercent` (80%) held for `cpuSustain` (30 s),
///   clears once it drops under `clearFraction` of the enter level.
/// A gap longer than `maxSampleGap` (sampling was skipped) restarts the CPU
/// window, so a stale first sample never counts toward the 30 s.
struct ResourceGuardHighRule: Equatable, Sendable {
    static let ramEnterBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let cpuEnterPercent = 80.0
    static let cpuSustain: TimeInterval = 30
    static let clearFraction = 0.8
    static let maxSampleGap: TimeInterval = 20

    private(set) var ramHigh = false
    private(set) var cpuHigh = false
    private(set) var cpuAboveSince: Date?
    private var lastSampleAt: Date?

    var isHigh: Bool { ramHigh || cpuHigh }
    /// A workspace close to flagging: sampling should stay at full cadence.
    var isWarm: Bool { isHigh || cpuAboveSince != nil }

    @discardableResult
    mutating func update(memoryBytes: Int64, cpuPercent: Double, now: Date) -> Bool {
        if let lastSampleAt, now.timeIntervalSince(lastSampleAt) > Self.maxSampleGap {
            cpuAboveSince = nil
            cpuHigh = false
        }
        lastSampleAt = now

        let ramClear = Int64(Double(Self.ramEnterBytes) * Self.clearFraction)
        ramHigh = ramHigh ? memoryBytes >= ramClear : memoryBytes >= Self.ramEnterBytes

        if cpuHigh {
            if cpuPercent < Self.cpuEnterPercent * Self.clearFraction {
                cpuHigh = false
                cpuAboveSince = nil
            }
        } else if cpuPercent >= Self.cpuEnterPercent {
            let since = cpuAboveSince ?? now
            cpuAboveSince = since
            if now.timeIntervalSince(since) >= Self.cpuSustain { cpuHigh = true }
        } else {
            cpuAboveSince = nil
        }
        return isHigh
    }
}

/// What the Pulse row needs for one workspace; only workspaces that are high or
/// paused have an entry.
struct ResourceGuardWorkspaceState: Equatable, Sendable {
    var memoryBytes: Int64
    var cpuPercent: Double
    var isHigh: Bool
    var isPaused: Bool
}

/// Per-workspace resource roll-up on top of the guardrail's existing 4 s sample
/// (no timer of its own), the thermal attention item, and Pause/Resume.
@MainActor
final class ResourceGuard: ObservableObject {
    static let shared = ResourceGuard()

    /// Only high or paused workspaces; empty at idle so nothing re-renders.
    @Published private(set) var states: [UUID: ResourceGuardWorkspaceState] = [:]

    private var rules: [UUID: ResourceGuardHighRule] = [:]
    /// workspaceId -> panelId -> process group stopped with SIGSTOP.
    private var pausedGroups: [UUID: [UUID: Int32]] = [:]
    private var lastHottest: Hottest?
    /// Hottest process name per workspace from the latest sample (for the title chip).
    private(set) var hottestNames: [UUID: String] = [:]
    private var thermalPending = false
    private var started = false

    struct Hottest: Equatable {
        let workspaceId: UUID
        let workspaceTitle: String
        let processName: String?
        let cpuPercent: Double
        let memoryBytes: Int64
    }

    /// Full-cadence sampling is needed: something is high, paused or about to be.
    var wantsFastSampling: Bool {
        !states.isEmpty || rules.values.contains { $0.isWarm }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.thermalStateChanged() }
        }
        // Nothing may stay stopped after Bree exits.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumeAll() }
        }
    }

    /// Guardrail stopped or has no panes: forget measurements, keep pauses.
    func reset() {
        rules.removeAll()
        lastHottest = nil
        publish()
    }

    // MARK: Samples

    func ingest(samples: [PaneMemorySample], now: Date = Date()) {
        var memory: [UUID: Int64] = [:]
        var cpu: [UUID: Double] = [:]
        var hottest: Hottest?
        var names: [UUID: (cpu: Double, name: String)] = [:]
        for sample in samples {
            let workspaceId = sample.descriptor.workspaceId
            memory[workspaceId, default: 0] += sample.memoryBytes
            cpu[workspaceId, default: 0] += sample.cpuPercent
            if let name = sample.hottestProcessName, sample.cpuPercent >= (names[workspaceId]?.cpu ?? -1) {
                names[workspaceId] = (sample.cpuPercent, name)
            }
            let candidate = Hottest(
                workspaceId: workspaceId,
                workspaceTitle: sample.descriptor.workspaceTitle,
                processName: sample.hottestProcessName,
                cpuPercent: sample.cpuPercent,
                memoryBytes: sample.memoryBytes
            )
            if let current = hottest {
                if (candidate.cpuPercent, candidate.memoryBytes) > (current.cpuPercent, current.memoryBytes) {
                    hottest = candidate
                }
            } else {
                hottest = candidate
            }
        }
        lastHottest = hottest
        hottestNames = names.mapValues(\.name)

        rules = rules.filter { memory[$0.key] != nil }
        for (workspaceId, bytes) in memory {
            var rule = rules[workspaceId] ?? ResourceGuardHighRule()
            rule.update(memoryBytes: bytes, cpuPercent: cpu[workspaceId] ?? 0, now: now)
            rules[workspaceId] = rule
        }
        let livePanels = Set(samples.map(\.key.panelId))
        pruneDeadPausedGroups(livePanels: livePanels)
        publish(memory: memory, cpu: cpu)
        if thermalPending { raiseThermalItem() }
    }

    private func publish(memory: [UUID: Int64] = [:], cpu: [UUID: Double] = [:]) {
        var next: [UUID: ResourceGuardWorkspaceState] = [:]
        for workspaceId in Set(rules.keys).union(pausedGroups.keys) {
            let isHigh = rules[workspaceId]?.isHigh ?? false
            let isPaused = !(pausedGroups[workspaceId]?.isEmpty ?? true)
            guard isHigh || isPaused else { continue }
            next[workspaceId] = ResourceGuardWorkspaceState(
                memoryBytes: memory[workspaceId] ?? states[workspaceId]?.memoryBytes ?? 0,
                cpuPercent: cpu[workspaceId] ?? states[workspaceId]?.cpuPercent ?? 0,
                isHigh: isHigh,
                isPaused: isPaused
            )
        }
        if next != states {
#if DEBUG
            for (id, state) in next where states[id]?.isHigh != state.isHigh && state.isHigh {
                dlog("resourceGuard.high enter ws=\(id.uuidString.prefix(8)) cpu=\(Int(state.cpuPercent)) mem=\(state.memoryBytes / 1_048_576)MB")
            }
            for (id, old) in states where old.isHigh && !(next[id]?.isHigh ?? false) {
                dlog("resourceGuard.high leave ws=\(id.uuidString.prefix(8))")
            }
#endif
            states = next
        }
    }

    // MARK: Thermal

    private func thermalStateChanged() {
        if ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue {
            thermalPending = true
            // Fresh numbers name the right culprit; without a scan, name what we have.
            if !PaneMemoryGuardrail.shared.scanNow() { raiseThermalItem() }
        } else {
            thermalPending = false
            AttentionStore.shared.setThermalItem(nil)
        }
    }

    private func raiseThermalItem() {
        thermalPending = false
        guard ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue else { return }
        let workspaceId = lastHottest?.workspaceId ?? AppDelegate.shared?.tabManager?.selectedTabId
        guard let workspaceId else { return }
        AttentionStore.shared.setThermalItem(AttentionItem(
            id: "thermal",
            workspaceId: workspaceId,
            panelId: nil,
            workspaceTitle: lastHottest?.workspaceTitle ?? "",
            paneTitle: nil,
            agentName: lastHottest?.processName,
            state: .thermal,
            sinceMs: AttentionStore.nowMs(),
            lastPrompt: nil,
            lastOutput: String(
                localized: "attention.thermal.detail",
                defaultValue: "The Mac is running hot. Pause or quit the busiest process."
            )
        ))
    }

    // MARK: Pause / Resume

    func isPaused(workspaceId: UUID) -> Bool {
        !(pausedGroups[workspaceId]?.isEmpty ?? true)
    }

    /// SIGSTOP to the selected pane's foreground process group. Never to Bree's own group.
    @discardableResult
    func pause(workspace: Workspace) -> Bool {
        guard let panelId = workspace.focusedPanelId,
              let terminal = workspace.panels[panelId] as? TerminalPanel,
              terminal.surface.hasLiveSurface,
              let pid = terminal.surface.foregroundProcessID(),
              pid > 1, pid <= Int(Int32.max) else { return false }
        let pgid = getpgid(pid_t(pid))
        guard pgid > 1, pgid != getpgrp() else { return false }
        guard killpg(pgid, SIGSTOP) == 0 else { return false }
        pausedGroups[workspace.id, default: [:]][panelId] = pgid
#if DEBUG
        dlog("resourceGuard.pause ws=\(workspace.id.uuidString.prefix(8)) pgid=\(pgid)")
#endif
        publish()
        return true
    }

    func resume(workspaceId: UUID) {
        guard let groups = pausedGroups.removeValue(forKey: workspaceId) else { return }
        let workspace = AppDelegate.shared?.tabManagerFor(tabId: workspaceId)?.workspacesById[workspaceId]
        for (panelId, pgid) in groups {
            // The shell takes the terminal back when its job stops; SIGCONT alone would
            // leave the job running in the background, out of Ctrl-C's reach. Let the
            // shell foreground it with `fg` instead.
            var viaShell = false
            if let terminal = workspace?.panels[panelId] as? TerminalPanel,
               terminal.surface.hasLiveSurface,
               let fgPid = terminal.surface.foregroundProcessID(),
               fgPid > 1, fgPid <= Int(Int32.max),
               getpgid(pid_t(fgPid)) != pgid {
                viaShell = terminal.sendTextResult("fg").accepted
                    && terminal.sendNamedKeyResult("return").accepted
            }
            if !viaShell { _ = killpg(pgid, SIGCONT) }
#if DEBUG
            dlog("resourceGuard.resume ws=\(workspaceId.uuidString.prefix(8)) pgid=\(pgid) viaShell=\(viaShell)")
#endif
        }
        publish()
    }

    func resumeAll() {
        for groups in pausedGroups.values {
            for pgid in groups.values { _ = killpg(pgid, SIGCONT) }
        }
        pausedGroups.removeAll()
        publish()
    }

    /// Menu and palette entry: resume if paused, otherwise pause.
    func togglePause(workspace: Workspace) {
        if isPaused(workspaceId: workspace.id) {
            resume(workspaceId: workspace.id)
        } else if !pause(workspace: workspace) {
            NSSound.beep()
        }
    }

    /// Forget groups whose pane is gone or whose process group no longer exists.
    private func pruneDeadPausedGroups(livePanels: Set<UUID>) {
        guard !pausedGroups.isEmpty else { return }
        for (workspaceId, groups) in pausedGroups {
            var kept = groups
            for (panelId, pgid) in groups {
                if !livePanels.contains(panelId) {
                    _ = killpg(pgid, SIGCONT)
                    kept[panelId] = nil
                } else if killpg(pgid, 0) != 0, errno == ESRCH {
                    kept[panelId] = nil
                }
            }
            pausedGroups[workspaceId] = kept.isEmpty ? nil : kept
        }
    }
}
