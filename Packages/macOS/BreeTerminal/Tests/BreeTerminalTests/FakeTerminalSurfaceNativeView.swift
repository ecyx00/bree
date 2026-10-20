import AppKit
import BreeTerminalCore
import GhosttyKit
@testable import BreeTerminal

final class FakeTerminalSurfaceNativeView: NSView {
    var tabId: UUID?
    var hostedTabId: UUID? { tabId }
    weak var attachedController: (any TerminalSurfaceControlling)?
    var attachedSurfaceController: (any TerminalSurfaceControlling)? { attachedController }
    var currentKeyStateIndicatorText: String? { nil }
    var isKeyboardCopyModeActive = false
    private(set) var keyboardCopyModeCancellationCount = 0
    var shouldDeferRuntimeInput = false
    var runtimeInputDeferralResponses: [Bool] = []
    var runtimeInputDeferralCallCount = 0
    var deferredRuntimeInputs: [() -> Void] = []
    var deferredRuntimeInputBytes: [Int] = []

    func toggleKeyboardCopyMode() -> Bool { false }
    func cancelKeyboardCopyMode() {
        keyboardCopyModeCancellationCount += 1
        isKeyboardCopyModeActive = false
    }
    func applyWindowBackgroundIfActive() {}
    func forceRefreshSurface() -> Bool { true }
    func runtimeSurfaceDidBecomeReady() {}

    func deferRuntimeInputDuringClipboardRead(
        estimatedBytes: Int,
        replay: @escaping () -> Void
    ) -> Bool {
        runtimeInputDeferralCallCount += 1
        let shouldDefer = runtimeInputDeferralResponses.isEmpty
            ? shouldDeferRuntimeInput
            : runtimeInputDeferralResponses.removeFirst()
        guard shouldDefer else { return false }
        deferredRuntimeInputBytes.append(estimatedBytes)
        deferredRuntimeInputs.append(replay)
        return true
    }
}

extension FakeTerminalSurfaceNativeView: @preconcurrency TerminalSurfaceHosting {}
extension FakeTerminalSurfaceNativeView: TerminalSurfaceNativeViewing {}
