import BreeCloud
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Regression coverage for the post-#12505 Cloud startup path.
@Suite("Cloud terminal startup latency")
struct CloudTerminalStartupLatencyTests {
    @Test
    func terminalCreationFailuresKeepTheirKnownCause() {
        #expect(CloudDiagnosticFailure.classify(BreeTuiSurfaceProvider.ProviderError.remoteTabNotFound("tab_source")) == .notFound)
        #expect(CloudDiagnosticFailure.classify(BreeTuiSurfaceProvider.ProviderError.invalidSnapshot("machine")) == .response)
        #expect(CloudDiagnosticFailure.classify(BreeTuiSurfaceProvider.ProviderError.terminalAttachTimedOut(
            terminalID: "term_created", failure: .transportUnavailable
        )) == .timeout)
    }

    @Test @MainActor
    func unresolvedSurfaceCannotStartAnAttachStream() {
        let session = CloudTuiManualMirrorSession(
            machineID: "machine",
            terminalID: "term_new-machine",
            remoteSurfaceID: 0,
            onNeedsReconnect: {}
        )
        defer { session.stop() }

        session.reconnect(socketPath: "/tmp/bree-unresolved-startup.sock")

        #expect(session.phase == .idle)
    }
}
