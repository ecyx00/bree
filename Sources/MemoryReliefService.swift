import AppKit
import BreeFoundation
import Darwin

/// Hands freed heap back to the OS and drops rebuildable caches. The policy
/// (debounce, idle delay, pressure) lives in `MemoryReliefCoordinator`; this
/// type only wires the app's signals to it and supplies the action.
@MainActor
final class MemoryReliefService {
    static let shared = MemoryReliefService()

    private let coordinator: MemoryReliefCoordinator
    private var observers: [NSObjectProtocol] = []
    private var started = false

    init(
        coordinator: MemoryReliefCoordinator = MemoryReliefCoordinator(relieve: MemoryReliefService.relieve)
    ) {
        self.coordinator = coordinator
    }

    func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        let coordinator = coordinator
        observers = [
            center.addObserver(
                forName: MallocPressureRelief.itemClosedNotification, object: nil, queue: nil
            ) { _ in Task { await coordinator.noteClose() } },
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: nil
            ) { _ in Task { await coordinator.noteInactive() } },
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
            ) { _ in Task { await coordinator.noteActive() } },
        ]
        Task { await coordinator.noteLaunch() }
    }

    nonisolated static func relieve(_ reason: MemoryReliefCoordinator.Reason) async {
        await MainActor.run {
            NotificationCenter.default.post(name: MallocPressureRelief.dropCachesNotification, object: nil)
        }
        // The heap walk can take tens of milliseconds; never run it on the main thread.
        await Task.detached(priority: .utility) {
            MallocPressureRelief.relieveHeap()
        }.value
    }

    /// Registers with the app's `MemoryPressureMonitor` (which owns the kernel
    /// pressure source) so a system warning also trims the heap.
    func makePressureResponder() -> any MemoryPressureResponder {
        HeapReliefMemoryPressureResponder(coordinator: coordinator)
    }
}

/// Runs last (lowest priority) so every other responder has already freed its
/// memory by the time the heap is trimmed.
@MainActor
final class HeapReliefMemoryPressureResponder: MemoryPressureResponder {
    let memoryPressureResponderID = "heap-relief"
    let memoryPressureMinimumSeverity: MemoryPressureSeverity = .warning
    let memoryPressurePriority = 1

    private let coordinator: MemoryReliefCoordinator

    init(coordinator: MemoryReliefCoordinator) {
        self.coordinator = coordinator
    }

    func shedMemory(for snapshot: MemoryPressureSnapshot) -> MemoryPressureShedResult {
        let coordinator = coordinator
        Task { await coordinator.noteMemoryPressure() }
        return MemoryPressureShedResult(reclaimedItemCount: 0, detail: "malloc-pressure-relief")
    }
}
