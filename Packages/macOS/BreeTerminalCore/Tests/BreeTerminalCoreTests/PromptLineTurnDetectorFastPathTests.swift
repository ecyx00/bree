import Foundation
import Testing
@testable import BreeTerminalCore

@Suite("Prompt line turn detector fast path")
struct PromptLineTurnDetectorFastPathTests {
    private let configuration = PromptLineTurnDetectionConfiguration(
        prompt: ">>> ",
        waitingPromptSuffixes: ["Send a message (/? for help)"]
    )

    private struct SplitMix64 {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
    }

    private static let fragments: [[UInt8]] = [
        ">>> ", ">>> Send a message (/? for help)", ">>> hi", ">>", ">", "hello", "x", "y",
        "some longer response line with words", "\r\n", "\r\n", "\n", "\n", "\r", "\u{8}",
        "\u{7F}", "\u{1B}[2K", "\u{1B}[1G", "\u{1B}[K", "\u{1B}[31m", "\u{1B}]0;t\u{7}",
        "\u{1B}", "é", " ", "\t", "0123456789abcdef0123456789abcdef",
    ].map { Array($0.utf8) }

    @Test("Skipping whole inert lines matches the per-byte state machine")
    func fastPathMatchesPerByteStateMachine() {
        var rng = SplitMix64(state: 0xC0FFEE)
        for _ in 0..<3_000 {
            var stream: [UInt8] = []
            for _ in 0..<(1 + rng.below(40)) {
                stream += Self.fragments[rng.below(Self.fragments.count)]
            }
            var fast = PromptLineTurnDetector(configuration: configuration)
            var reference = PromptLineTurnDetector(configuration: configuration)
            reference.linesFastPathEnabled = false

            var offset = 0
            while offset < stream.count {
                let length = min(stream.count - offset, 1 + rng.below(24))
                stream[offset..<(offset + length)].withUnsafeBufferPointer { fast.consume($0) }
                stream[offset..<(offset + length)].withUnsafeBufferPointer { reference.consume($0) }
                offset += length

                #expect(fast.submissionCount == reference.submissionCount)
                #expect(fast.confirmationRevision == reference.confirmationRevision)
                #expect(fast.pendingConfirmation == reference.pendingConfirmation)
                if let pending = fast.pendingConfirmation, rng.below(2) == 0 {
                    #expect(fast.confirm(pending) == reference.confirm(pending))
                }
            }
        }
    }

    @Test("A prompt right after a block of inert lines still completes a turn")
    func promptAfterInertLinesCompletesTurn() throws {
        var detector = PromptLineTurnDetector(configuration: configuration)
        detector.consume(Data(">>> ".utf8))
        detector.consume(Data("go\r\n".utf8))
        let noise = String(repeating: "12345\n", count: 5_000)
        detector.consume(Data(noise.utf8))
        detector.consume(Data("\r\n>>> ".utf8))

        let confirmation = try #require(detector.pendingConfirmation)
        #expect(detector.confirm(confirmation) == 1)
    }
}

@Suite("Prompt detection gate")
struct PromptDetectionGateTests {
    @Test("A gate is on at first, off after disable, and gets a new epoch when re-enabled")
    func epochChangesOnEveryEnable() {
        let gate = PromptDetectionGate()
        let first = gate.currentEpoch
        #expect(first != PromptDetectionGate.disabledEpoch)

        gate.enable()
        #expect(gate.currentEpoch == first)

        gate.disable()
        #expect(gate.currentEpoch == PromptDetectionGate.disabledEpoch)

        gate.enable()
        #expect(gate.currentEpoch != PromptDetectionGate.disabledEpoch)
        #expect(gate.currentEpoch != first)
    }

    @Test("Resynchronizing drops stale screen state but keeps counters monotonic")
    func resynchronizeKeepsCountersMonotonic() throws {
        let configuration = PromptLineTurnDetectionConfiguration(prompt: ">>> ")
        var detector = PromptLineTurnDetector(configuration: configuration)
        detector.consume(Data(">>> go\r\nanswer\r\n>>> ".utf8))
        let pending = try #require(detector.pendingConfirmation)
        let revision = detector.confirmationRevision
        let submissions = detector.submissionCount

        detector.resynchronize()

        #expect(detector.pendingConfirmation == nil)
        #expect(detector.confirmationRevision > revision)
        #expect(detector.submissionCount == submissions)
        #expect(detector.confirm(pending) == 0)

        // Back to seeking: output missed while off cannot complete a turn.
        detector.consume(Data("stale\r\n>>> ".utf8))
        #expect(detector.pendingConfirmation == nil)
    }
}
