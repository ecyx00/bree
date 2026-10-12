import Foundation
import Testing
@testable import CmuxFoundation

private actor ReliefLog {
    private(set) var reasons: [MemoryReliefCoordinator.Reason] = []
    func add(_ reason: MemoryReliefCoordinator.Reason) { reasons.append(reason) }
}

/// Polls until `log` holds `count` reasons or the deadline passes, so a starved
/// test runner (hundreds of parallel tests) cannot turn a slow wakeup into a failure.
private func waitForReasons(_ log: ReliefLog, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(10)
    while await log.reasons.count < count, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
}

struct MemoryReliefCoordinatorTests {
    private func make(_ log: ReliefLog) -> MemoryReliefCoordinator {
        MemoryReliefCoordinator(
            closeDebounce: .milliseconds(40),
            idleDelay: .milliseconds(60),
            launchDelay: .milliseconds(50)
        ) { await log.add($0) }
    }

    @Test("A burst of closes relieves once after the debounce")
    func closeBurstIsDebounced() async throws {
        let log = ReliefLog()
        let coordinator = make(log)
        for _ in 0..<5 {
            await coordinator.noteClose()
        }
        try await waitForReasons(log, count: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.reasons == [.close])
    }

    @Test("Inactivity relieves once and returning cancels it")
    func idleRelief() async throws {
        let log = ReliefLog()
        let coordinator = make(log)
        await coordinator.noteInactive()
        await coordinator.noteActive()
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.reasons.isEmpty)
        await coordinator.noteInactive()
        try await waitForReasons(log, count: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.reasons == [.idle])
    }

    @Test("Memory pressure relieves immediately")
    func pressureIsImmediate() async {
        let log = ReliefLog()
        let coordinator = make(log)
        await coordinator.noteMemoryPressure()
        #expect(await log.reasons == [.memoryPressure])
    }

    @Test("Launch relief fires once after the settle delay")
    func launchRelief() async throws {
        let log = ReliefLog()
        let coordinator = make(log)
        await coordinator.noteLaunch()
        try await waitForReasons(log, count: 1)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await log.reasons == [.launch])
    }
}
