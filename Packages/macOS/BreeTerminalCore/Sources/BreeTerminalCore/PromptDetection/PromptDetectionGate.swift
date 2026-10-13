import BreeFoundation
import Foundation
import os

/// Lets a surface's PTY read thread skip prompt detection with one atomic load.
///
/// Prompt-line turn detection only matters while the surface's foreground
/// process is an interactive agent REPL such as `ollama run`. The owner of
/// the shell state flips this gate from the main actor; the read thread never
/// does process work, it only compares ``currentEpoch`` with the epoch it last
/// saw.
public final class PromptDetectionGate: Sendable {
    /// Epoch value of a gate that is off.
    public static let disabledEpoch: UInt64 = 0

    private let epoch: AtomicUInt64Value
    private let nextEpoch = OSAllocatedUnfairLock(initialState: UInt64(1))

    /// Creates a gate.
    ///
    /// - Parameter isEnabled: Surfaces start enabled so a shell without
    ///   integration, which never reports its state, keeps working.
    public init(isEnabled: Bool = true) {
        epoch = AtomicUInt64Value(isEnabled ? 1 : Self.disabledEpoch)
    }

    /// Zero while disabled; otherwise an identifier that changes on every
    /// off-to-on transition, so the reader can drop state gathered earlier.
    @inline(__always)
    public var currentEpoch: UInt64 { epoch.loadRelaxed() }

    /// Turns detection on. A gate that is already on keeps its epoch.
    public func enable() {
        guard currentEpoch == Self.disabledEpoch else { return }
        let next = nextEpoch.withLock { value -> UInt64 in
            value &+= 1
            return value
        }
        epoch.storeRelaxed(next)
    }

    /// Turns detection off; the read thread then skips every buffer.
    public func disable() {
        epoch.storeRelaxed(Self.disabledEpoch)
    }
}

/// When to look at a surface's foreground process after its shell starts a command.
public enum PromptDetectionProbeSchedule {
    /// Delays between probes, measured from the command start. An agent REPL
    /// is the foreground process within milliseconds of the command starting
    /// and shows its first prompt only after loading, so a short ladder
    /// finds it; later probes cover wrappers that exec the agent afterwards.
    /// The ladder is bounded so a long-running unrelated command costs a
    /// handful of probes, not a poll.
    public static let delays: [Duration] = [
        .milliseconds(40), .milliseconds(120), .milliseconds(300), .milliseconds(700),
        .milliseconds(1_500), .seconds(3), .seconds(6), .seconds(12),
    ]

    /// Index in ``delays`` after which a command that is still not an agent
    /// switches detection off. Later probes can still switch it back on.
    public static let disableAfterStep = 2
}
