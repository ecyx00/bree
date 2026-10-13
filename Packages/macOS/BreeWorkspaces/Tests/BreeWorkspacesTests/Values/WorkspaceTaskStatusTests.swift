import Foundation
import Testing
@testable import BreeWorkspaces

@Suite struct WorkspaceTaskStatusTests {
    /// Raw values are a control-socket and session wire format; frozen.
    @Test func rawValuesAreFrozenWireValues() {
        #expect(WorkspaceTaskStatus.todo.rawValue == "todo")
        #expect(WorkspaceTaskStatus.working.rawValue == "working")
        #expect(WorkspaceTaskStatus.needsAttention.rawValue == "needs-attention")
        #expect(WorkspaceTaskStatus.review.rawValue == "review")
        #expect(WorkspaceTaskStatus.done.rawValue == "done")
        #expect(WorkspaceTaskStatus.allCases.count == 5)
    }

    @Test func noSignalsInfersTodo() {
        #expect(WorkspaceTaskStatus.inferred(from: WorkspaceTaskStatusSignals()) == .todo)
    }

    @Test func needsInputWinsOverEverything() {
        let signals = WorkspaceTaskStatusSignals(
            anyAgentNeedsInput: true,
            anyAgentRunning: true,
            isGitDirty: true
        )
        #expect(WorkspaceTaskStatus.inferred(from: signals) == .needsAttention)
    }

    @Test func runningAgentWinsOverDirtyTree() {
        let signals = WorkspaceTaskStatusSignals(
            anyAgentRunning: true,
            isGitDirty: true
        )
        #expect(WorkspaceTaskStatus.inferred(from: signals) == .working)
    }

    @Test func dirtyTreeAloneInfersWorking() {
        let signals = WorkspaceTaskStatusSignals(isGitDirty: true)
        #expect(WorkspaceTaskStatus.inferred(from: signals) == .working)
    }
}

@Suite struct WorkspaceTaskStatusOverrideTests {
    @Test func noOverrideResolvesToInferred() {
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: nil, inferred: .working)
        #expect(resolution.effective == .working)
        #expect(!resolution.shouldClearOverride)
    }

    @Test func matchingInferenceKeepsOverride() {
        let override = WorkspaceTaskStatusOverride(status: .review, inferredAtOverride: .working)
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: override, inferred: .working)
        #expect(resolution.effective == .review)
        #expect(!resolution.shouldClearOverride)
    }

    /// Anti-rot: once the live inference moves away from what it was when the
    /// override was set, the override expires and should be cleared.
    @Test func changedInferenceExpiresOverride() {
        let override = WorkspaceTaskStatusOverride(status: .done, inferredAtOverride: .todo)
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: override, inferred: .working)
        #expect(resolution.effective == .working)
        #expect(resolution.shouldClearOverride)
    }

    /// An override that matches the new inference by value still expires when
    /// the recorded inference differs (the resolution falls back to inferred,
    /// which happens to equal the override's status).
    @Test func expiryComparesRecordedInferenceNotOverrideValue() {
        let override = WorkspaceTaskStatusOverride(status: .working, inferredAtOverride: .todo)
        let resolution = WorkspaceTaskStatusOverride.effectiveStatus(override: override, inferred: .working)
        #expect(resolution.effective == .working)
        #expect(resolution.shouldClearOverride)
    }

    @Test func codableRoundTripUsesRawValues() throws {
        let override = WorkspaceTaskStatusOverride(status: .needsAttention, inferredAtOverride: .todo)
        let data = try JSONEncoder().encode(override)
        let decoded = try JSONDecoder().decode(WorkspaceTaskStatusOverride.self, from: data)
        #expect(decoded == override)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("needs-attention"))
    }
}
