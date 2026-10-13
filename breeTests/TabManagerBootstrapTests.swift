import Testing
import BreeRemoteSession

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite
struct TabManagerBootstrapTests {
    @MainActor
    @Test
    func appBootstrapManagerDoesNotCreateAWorkspaceOrTerminal() {
        let nativeSSHConnectionBroker = NativeSSHConnectionBroker()
        let manager = TabManager.makeAppBootstrap(
            nativeSSHConnectionBroker: nativeSSHConnectionBroker
        )

        #expect(manager.tabs.isEmpty)
        #expect(manager.selectedWorkspace == nil)
        #expect(manager.selectedSurface == nil)
        #expect(manager.nativeSSHConnectionBroker === nativeSSHConnectionBroker)
    }
}
