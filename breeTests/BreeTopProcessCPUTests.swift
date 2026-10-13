import Darwin
import Testing
import Foundation

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite(.serialized)
struct BreeTopProcessCPUTests {
    @Test func testOverflowSentinelReportsZeroCPUPercent() {
        let previous = BreeTopProcessCPUSample(
            totalTimeTicks: 100,
            sampledAtNanoseconds: 1_000
        )
        let current = BreeTopProcessCPUSample(
            totalTimeTicks: UInt64.max,
            sampledAtNanoseconds: 2_000
        )

        #expect((BreeTopProcessSnapshot.cpuPercent(current: current, previous: previous)) == (0))
    }

    @Test func testCPUPercentagesHoldPreviousValueUntilFixedWindowElapses() {
        let key = BreeTopProcessScopeCacheKey(
            pid: 4_129_001,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let activeKeys: Set<BreeTopProcessScopeCacheKey> = [key]

        _ = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                key: BreeTopProcessCPUSample(
                    totalTimeTicks: 1_000,
                    sampledAtNanoseconds: 1_000_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 1_000_000_000
        )

        let rapidPercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                key: BreeTopProcessCPUSample(
                    totalTimeTicks: 1_000_001_000,
                    sampledAtNanoseconds: 1_100_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 1_100_000_000
        )

        #expect((rapidPercentages[key]) == (0))

        let fixedWindowPercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                key: BreeTopProcessCPUSample(
                    totalTimeTicks: 1_000_002_000,
                    sampledAtNanoseconds: 2_000_000_000
                )
            ],
            activeKeys: activeKeys,
            sampledAtNanoseconds: 2_000_000_000
        )

        #expect((fixedWindowPercentages[key] ?? 0) > (0))
    }

    @Test func testExitedChildCPUPercentCarriesIntoActiveParentForOneSample() {
        let parentKey = BreeTopProcessScopeCacheKey(
            pid: 4_129_100,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let childKey = BreeTopProcessScopeCacheKey(
            pid: 4_129_101,
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let activeParentAndChild: Set<BreeTopProcessScopeCacheKey> = [parentKey, childKey]

        _ = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 10_000_000_000),
                childKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 10_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 10_000_000_000
        )
        let activePercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 11_000_000_000),
                childKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000_001_000, sampledAtNanoseconds: 11_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 11_000_000_000
        )

        #expect((activePercentages[childKey] ?? 0) > (0))

        let parentOnlyPercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 12_000_000_000),
            ],
            activeKeys: [parentKey],
            sampledAtNanoseconds: 12_000_000_000
        )

        #expect((parentOnlyPercentages[parentKey] ?? 0) > (0))
        #expect((parentOnlyPercentages[childKey]) == nil)
    }

    @Test func testExitedChildCPUPercentDoesNotInflateHeldParentSample() {
        let parentKey = BreeTopProcessScopeCacheKey(
            pid: 4_129_200,
            startSeconds: 1_000,
            startMicroseconds: 0
        )
        let childKey = BreeTopProcessScopeCacheKey(
            pid: 4_129_201,
            startSeconds: 1_000,
            startMicroseconds: 1
        )
        let activeParentAndChild: Set<BreeTopProcessScopeCacheKey> = [parentKey, childKey]

        _ = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 20_000_000_000),
                childKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 20_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 20_000_000_000
        )
        let activePercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 21_000_000_000),
                childKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000_001_000, sampledAtNanoseconds: 21_000_000_000),
            ],
            activeKeys: activeParentAndChild,
            parentKeysByKey: [childKey: parentKey],
            sampledAtNanoseconds: 21_000_000_000
        )

        #expect((activePercentages[parentKey]) == (0))
        #expect((activePercentages[childKey] ?? 0) > (0))

        let heldParentOnlyPercentages = BreeTopProcessSnapshot.cpuPercentages(
            for: [
                parentKey: BreeTopProcessCPUSample(totalTimeTicks: 1_000, sampledAtNanoseconds: 21_100_000_000),
            ],
            activeKeys: [parentKey],
            sampledAtNanoseconds: 21_100_000_000
        )

        #expect((heldParentOnlyPercentages[parentKey]) == (0))
        #expect((heldParentOnlyPercentages[childKey]) == nil)
    }

    @Test func testBusyChildProcessReportsNonZeroCPUPercent() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do :; done"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer { terminate(process) }

        let pid = Int(process.processIdentifier)
        _ = await BreeTopProcessSnapshot.capture(includeProcessDetails: false).summary(for: [pid])

        let observedCPU = await waitForCPUPercent(pid: pid, timeout: 5)

        #expect((observedCPU) > (0.1))
    }

    private func waitForCPUPercent(pid: Int, timeout: TimeInterval) async -> Double {
        let deadline = Date.now.addingTimeInterval(timeout)
        var maxCPU = 0.0

        while Date.now < deadline {
            let cpu = await BreeTopProcessSnapshot.capture(includeProcessDetails: false)
                .summary(for: [pid])
                .cpuPercent
            maxCPU = max(maxCPU, cpu)
            if cpu > 0.1 {
                return cpu
            }

            // A real sampling interval is required for a measurable CPU delta.
            try? await ContinuousClock().sleep(for: .milliseconds(200))
        }

        return maxCPU
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()

        let deadline = Date.now.addingTimeInterval(2)
        while process.isRunning, Date.now < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date.now.addingTimeInterval(0.05))
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}
