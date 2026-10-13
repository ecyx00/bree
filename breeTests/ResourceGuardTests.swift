import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite
struct ResourceGuardTests {
    private let gb: Int64 = 1024 * 1024 * 1024
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @Test
    func ramHighAtTwoGBAndClearsBelowEightyPercent() {
        var rule = ResourceGuardHighRule()
        let r1 = rule.update(memoryBytes: gb, cpuPercent: 0, now: t0)
        #expect(!r1)
        let r2 = rule.update(memoryBytes: 2 * gb, cpuPercent: 0, now: t0.addingTimeInterval(4))
        #expect(r2)
        // Hysteresis band: 1.7 GB stays high.
        let r3 = rule.update(memoryBytes: Int64(1.7 * Double(gb)), cpuPercent: 0, now: t0.addingTimeInterval(8))
        #expect(r3)
        let r4 = rule.update(memoryBytes: Int64(1.5 * Double(gb)), cpuPercent: 0, now: t0.addingTimeInterval(12))
        #expect(!r4)
    }

    @Test
    func cpuNeedsThirtySecondsSustained() {
        var rule = ResourceGuardHighRule()
        for step in stride(from: 0, to: 28, by: 4) {
            let r5 = rule.update(memoryBytes: 0, cpuPercent: 140, now: t0.addingTimeInterval(Double(step)))
            #expect(!r5)
        }
        #expect(rule.isWarm)
        let r6 = rule.update(memoryBytes: 0, cpuPercent: 140, now: t0.addingTimeInterval(30))
        #expect(r6)
    }

    @Test
    func cpuDipBeforeThirtySecondsRestartsTheWindow() {
        var rule = ResourceGuardHighRule()
        rule.update(memoryBytes: 0, cpuPercent: 150, now: t0)
        rule.update(memoryBytes: 0, cpuPercent: 150, now: t0.addingTimeInterval(16))
        rule.update(memoryBytes: 0, cpuPercent: 10, now: t0.addingTimeInterval(20))
        #expect(!rule.isWarm)
        for step in stride(from: 24, to: 54, by: 4) {
            let r7 = rule.update(memoryBytes: 0, cpuPercent: 150, now: t0.addingTimeInterval(Double(step)))
            #expect(!r7)
        }
        let r8 = rule.update(memoryBytes: 0, cpuPercent: 150, now: t0.addingTimeInterval(54))
        #expect(r8)
    }

    @Test
    func cpuHighClearsOnlyBelowSixtyFourPercent() {
        var rule = ResourceGuardHighRule()
        rule.update(memoryBytes: 0, cpuPercent: 100, now: t0)
        // Samples stay within maxSampleGap so the CPU window is never restarted.
        rule.update(memoryBytes: 0, cpuPercent: 100, now: t0.addingTimeInterval(10))
        rule.update(memoryBytes: 0, cpuPercent: 100, now: t0.addingTimeInterval(20))
        let r9 = rule.update(memoryBytes: 0, cpuPercent: 100, now: t0.addingTimeInterval(30))
        #expect(r9)
        let r10 = rule.update(memoryBytes: 0, cpuPercent: 70, now: t0.addingTimeInterval(34))
        #expect(r10)
        let r11 = rule.update(memoryBytes: 0, cpuPercent: 60, now: t0.addingTimeInterval(38))
        #expect(!r11)
    }

    @Test
    func skippedSamplingRestartsTheCpuWindow() {
        var rule = ResourceGuardHighRule()
        rule.update(memoryBytes: 0, cpuPercent: 200, now: t0)
        // App was in the background for a minute: the old start must not count.
        let r12 = rule.update(memoryBytes: 0, cpuPercent: 200, now: t0.addingTimeInterval(60))
        #expect(!r12)
        for step in stride(from: 64, to: 90, by: 4) {
            let r13 = rule.update(memoryBytes: 0, cpuPercent: 200, now: t0.addingTimeInterval(Double(step)))
            #expect(!r13)
        }
        let r14 = rule.update(memoryBytes: 0, cpuPercent: 200, now: t0.addingTimeInterval(90))
        #expect(r14)
    }

    @Test
    func pulseTextShowsMetricsOnlyWhileHighAndPausedWord() {
        #expect(SidebarWorkspacePulse.resourceText(nil) == nil)
        let high = ResourceGuardWorkspaceState(
            memoryBytes: Int64(3.1 * Double(gb)), cpuPercent: 140, isHigh: true, isPaused: false
        )
        #expect(SidebarWorkspacePulse.resourceText(high) == "3.1 GB · 140%")
        let paused = ResourceGuardWorkspaceState(memoryBytes: 0, cpuPercent: 0, isHigh: false, isPaused: true)
        #expect(SidebarWorkspacePulse.resourceText(paused) == "paused")
    }
}
