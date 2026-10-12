import Foundation
import os

/// Tells periodic samplers whether some terminal is streaming output.
///
/// The PTY read thread already counts reads per surface for the scrollback
/// checkpoint; this monitor only sums those counters when asked, so reading
/// the signal costs nothing on the hot path.
final class TerminalOutputStreamingMonitor: Sendable {
    static let shared = TerminalOutputStreamingMonitor()

    /// Reads per second, across all terminals, above which output counts as streaming.
    private static let streamingReadsPerSecond = 100.0
    private static let minimumWindow: Duration = .milliseconds(500)

    private struct State {
        var activity: TerminalScrollbackCheckpointActivity?
        var lastTotal: UInt64 = 0
        var lastAt: ContinuousClock.Instant = .now
        var streaming = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func attach(_ activity: TerminalScrollbackCheckpointActivity) {
        state.withLock { $0.activity = activity }
    }

    /// Whether the reads since the previous verdict ran above the streaming rate.
    func isStreaming() -> Bool {
        state.withLock { state in
            guard let activity = state.activity else { return false }
            let now = ContinuousClock.now
            let window = state.lastAt.duration(to: now)
            // Callers poll at seconds; a shorter window is too noisy to judge.
            guard window >= Self.minimumWindow else { return state.streaming }
            let total = activity.totalOutputGeneration()
            let seconds = Double(window.components.seconds)
                + Double(window.components.attoseconds) / 1e18
            state.streaming = Double(total &- state.lastTotal) / seconds > Self.streamingReadsPerSecond
            state.lastTotal = total
            state.lastAt = now
            return state.streaming
        }
    }
}
