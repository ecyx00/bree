import AppKit
import Carbon.HIToolbox
import GhosttyKit
import Testing
@testable import BreeTerminal

@_silgen_name("bree_test_ghostty_surface_key_reset")
private func breeTestGhosttySurfaceKeyReset()

@_silgen_name("bree_test_ghostty_surface_key_was_called")
private func breeTestGhosttySurfaceKeyWasCalled() -> Bool

@_silgen_name("bree_test_ghostty_surface_key_mods")
private func breeTestGhosttySurfaceKeyMods() -> Int32

@_silgen_name("bree_test_ghostty_surface_key_unshifted_codepoint")
private func breeTestGhosttySurfaceKeyUnshiftedCodepoint() -> UInt32

@_silgen_name("bree_test_ghostty_surface_key_text")
private func breeTestGhosttySurfaceKeyText() -> UnsafePointer<CChar>

@MainActor
@Suite(.serialized)
struct TerminalSurfaceExplicitInputTests {
    enum ProgrammaticInput: CaseIterable, Equatable, Sendable {
        case pasteText
        case keyText
        case namedKey
        case parsedInput
        case bindingAction

        var expectedExplicitInputCount: Int {
            self == .bindingAction ? 0 : 1
        }

        @MainActor
        func send(to surface: TerminalSurface) {
            switch self {
            case .pasteText:
                _ = surface.sendText("hello")
            case .keyText:
                _ = surface.sendKeyText("x")
            case .namedKey:
                _ = surface.sendNamedKey("enter")
            case .parsedInput:
                _ = surface.sendInputResult("hello")
            case .bindingAction:
                _ = surface.performBindingAction("scroll_to_bottom")
            }
        }
    }

    @Test(
        "programmatic input waits for a runtime clipboard read",
        arguments: ProgrammaticInput.allCases
    )
    func programmaticInputWaitsForRuntimeClipboardRead(
        _ input: ProgrammaticInput
    ) {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.shouldDeferRuntimeInput = true

        input.send(to: fixture.surface)

        #expect(fixture.nativeView.deferredRuntimeInputs.count == 1)
        #expect(
            fixture.nativeView.deferredRuntimeInputBytes.allSatisfy { $0 > 0 }
        )
        #expect(
            fixture.paneHost.explicitInputCount
                == input.expectedExplicitInputCount
        )
        fixture.nativeView.shouldDeferRuntimeInput = false
        fixture.nativeView.deferredRuntimeInputs.removeFirst()()
        #expect(fixture.nativeView.deferredRuntimeInputs.isEmpty)
        #expect(
            fixture.paneHost.explicitInputCount
                == input.expectedExplicitInputCount
        )
    }

    @Test func parsedInputChecksDeferralBetweenLiveEvents() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }
        fixture.nativeView.runtimeInputDeferralResponses = [false, true, true]

        let result = fixture.surface.sendInputResult("x\r")

        #expect(result == .queued)
        #expect(fixture.nativeView.runtimeInputDeferralCallCount == 3)
        #expect(fixture.nativeView.deferredRuntimeInputs.count == 2)
        #expect(
            fixture.nativeView.deferredRuntimeInputBytes.allSatisfy { $0 > 0 }
        )
    }

    @Test func genericCtrlLetterParserRecognizesPlusAndDashForms() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        for spelling in ["ctrl+p", "ctrl-p", "control+p"] {
            let event = fixture.surface.pendingKeyEvent(for: spelling)
            #expect(event?.keycode == UInt32(kVK_ANSI_P))
            #expect(event?.mods.rawValue == GHOSTTY_MODS_CTRL.rawValue)
        }
        #expect(fixture.surface.pendingKeyEvent(for: "ctrl+1") == nil)
    }

    @Test func syntheticCtrlLetterProvidesGhosttyEncoderTextAndCodepoint() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }
        breeTestGhosttySurfaceKeyReset()

        #expect(fixture.surface.sendNamedKey("ctrl+p") == .sent)
        #expect(breeTestGhosttySurfaceKeyWasCalled())
        #expect(breeTestGhosttySurfaceKeyMods() == Int32(GHOSTTY_MODS_CTRL.rawValue))
        #expect(breeTestGhosttySurfaceKeyUnshiftedCodepoint() == UInt32("p".unicodeScalars.first!.value))
        #expect(String(cString: breeTestGhosttySurfaceKeyText()) == "p")
    }

    @Test func pasteTextNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendTextResult("hello") == .queued)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func pasteReportsClipboardDeferralAndRetainsOneReplay() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.shouldDeferRuntimeInput = true

        #expect(fixture.surface.sendTextResult("literal\n世界") == .queued)
        #expect(fixture.nativeView.deferredRuntimeInputs.count == 1)
        #expect(fixture.surface.pendingSocketInputBytes == 0)

        fixture.nativeView.shouldDeferRuntimeInput = false
        fixture.nativeView.deferredRuntimeInputs.removeFirst()()
        #expect(fixture.surface.pendingSocketInputBytes == "literal\n世界".utf8.count)
    }

    @Test func pasteReportsQueueFullWithoutAcceptingText() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.pendingSocketInputBytes = fixture.surface.maxPendingSocketInputBytes
        var accepted = 0
        fixture.surface.onExplicitInput = { accepted += 1 }

        #expect(fixture.surface.sendTextResult("literal\n世界") == .inputQueueFull)
        #expect(fixture.surface.pendingSocketInputBytes == fixture.surface.maxPendingSocketInputBytes)
        #expect(accepted == 0)
    }

    @Test func pasteReportsClosedSurfaceWithoutQueueing() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.beginPortalCloseLifecycle(reason: "test.closed")

        #expect(fixture.surface.sendTextResult("literal\n世界") == .surfaceUnavailable)
        #expect(fixture.surface.pendingSocketInputBytes == 0)
    }

    @Test func parsedInputNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendInputResult("hello").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func queuedParsedInputNotifiesItsOwner() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        var acceptedInputCount = 0
        fixture.surface.onExplicitInput = { acceptedInputCount += 1 }

        #expect(fixture.surface.sendInputResult("hello") == .queued)

        #expect(acceptedInputCount == 1)
    }

    @Test func rejectedParsedInputDoesNotNotifyItsOwner() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        var acceptedInputCount = 0
        fixture.surface.onExplicitInput = { acceptedInputCount += 1 }
        fixture.surface.pendingSocketInputBytes = fixture.surface.maxPendingSocketInputBytes

        #expect(fixture.surface.sendInputResult("hello") == .inputQueueFull)

        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(acceptedInputCount == 0)
    }

    @Test func namedKeyNotifiesPaneHostBeforeQueueingOnAColdSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendNamedKey("enter").accepted)

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func keyTextNotifiesPaneHostBeforeWritingToALiveSurface() {
        let runtimeSurface = allocatedRuntimeSurface()
        let fixture = makeFixture(runtimeSurface: runtimeSurface)
        defer {
            fixture.surface.releaseSurfaceForTesting()
            runtimeSurface.deallocate()
        }

        _ = fixture.surface.sendKeyText("x")

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func explicitBindingActionNotifiesWithoutChangingInternalBindingActions() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(!fixture.surface.performBindingAction("scroll_to_bottom"))
        #expect(fixture.paneHost.explicitInputCount == 0)

        #expect(!fixture.surface.performExplicitInputBindingAction("paste_from_clipboard"))
        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func closingSearchAsExplicitInputNotifiesBeforeClearingSearchState() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.surface.searchState = TerminalSurface.SearchState(needle: "scroll")

        fixture.surface.closeSearchFromExplicitInput()

        #expect(fixture.paneHost.explicitInputCount == 1)
        #expect(fixture.surface.searchState == nil)
    }

    @Test func copyModeToggleNotifiesPaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(!fixture.surface.toggleKeyboardCopyMode())

        #expect(fixture.paneHost.explicitInputCount == 1)
    }

    @Test func losingFocusCancelsKeyboardCopyModeOnTheSurface() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }
        fixture.nativeView.isKeyboardCopyModeActive = true

        fixture.surface.setFocus(true)
        fixture.surface.setFocus(false)

        #expect(fixture.nativeView.keyboardCopyModeCancellationCount == 1)
        #expect(!fixture.nativeView.isKeyboardCopyModeActive)
    }

    @Test func emptyInputDoesNotNotifyThePaneHost() {
        let fixture = makeFixture()
        defer { fixture.surface.releaseSurfaceForTesting() }

        #expect(fixture.surface.sendText(""))
        #expect(fixture.surface.sendKeyText(""))
        #expect(fixture.surface.sendInputResult("").accepted)
        #expect(fixture.surface.sendNamedKey("") == .unknownKey)

        #expect(fixture.paneHost.explicitInputCount == 0)
    }

    @Test func paneHostPreparationRunsBeforeStartupWorkCanAttachTheRuntime() {
        var events: [String] = []
        let fixture = makeFixture(
            initialInput: "echo ready",
            preparePaneHost: { _ in events.append("prepare") },
            onAttach: { events.append("attach") }
        )
        defer {
            fixture.surface.closeHeadlessStartupWindowIfNeeded()
            fixture.surface.releaseSurfaceForTesting()
        }

        #expect(events.first == "prepare")
        #expect(events.dropFirst().contains("attach"))
    }

    private func makeFixture(
        initialInput: String? = nil,
        preparePaneHost: @Sendable @MainActor (any TerminalSurfacePaneHosting) -> Void = { _ in },
        onAttach: (() -> Void)? = nil,
        runtimeSurface: ghostty_surface_t? = nil
    ) -> (
        surface: TerminalSurface,
        paneHost: FakeTerminalSurfacePaneHost,
        nativeView: FakeTerminalSurfaceNativeView
    ) {
        let nativeView = FakeTerminalSurfaceNativeView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600)
        )
        let paneHost = FakeTerminalSurfacePaneHost(surfaceView: nativeView, onAttach: onAttach)
        let registry = FakeSurfaceRegistry()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            initialInput: initialInput,
            preparePaneHost: preparePaneHost,
            dependencies: TerminalSurfaceRuntimeDependencies(
                registry: registry,
                engine: FakeTerminalEngine(),
                viewProvider: FakeTerminalSurfaceViewProvider(
                    surfaceView: nativeView,
                    paneHost: paneHost
                ),
                spawnPolicy: FakeSpawnPolicyProvider(),
                byteTee: FakeTerminalByteTee(),
                rendererRealization: FakeRendererRealizationScheduler(),
                hibernationRecorder: FakeHibernationRecorder(),
                runtimeTeardown: TerminalSurfaceRuntimeTeardownCoordinator(),
                restoreSpawnScheduler: TerminalSurfaceRestoreSpawnScheduler(interSpawnDelay: .zero),
                runtimeFilesystem: TerminalSurfaceRuntimeFilesystem(
                    agentCommandShimRootDirectory: URL(
                        fileURLWithPath: "/tmp/bree-terminal-tests",
                        isDirectory: true
                    ),
                    installAgentCommandShims: { _, _, _ in nil },
                    isExecutableFile: { _ in false }
                ),
                sessionPortBase: 40_000,
                sessionPortRangeSize: 100,
                scrollbackReplayEnvironmentKey: "BREE_TEST_SCROLLBACK_REPLAY"
            )
        )
        if let runtimeSurface {
            registry.registerRuntimeSurface(runtimeSurface, ownerId: surface.id)
            surface.installRuntimeSurfaceForTesting(runtimeSurface)
        }
        return (surface, paneHost, nativeView)
    }

    private func allocatedRuntimeSurface() -> ghostty_surface_t {
        UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)
    }
}
