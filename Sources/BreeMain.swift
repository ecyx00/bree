import Bonsplit
import BreeFoundation
import Foundation
import SwiftUI

/// The process entry point. When the binary is launched with a worker flag
/// (the app re-executes its own binary so a crash or hang in paste preparation,
/// the interpreter or renderer kills only the worker process), run
/// that worker instead of the app:
/// - the paste worker resolves providers and prepares images before any app or
///   SwiftUI startup;
/// - the render worker hosts its own faceless AppKit session and shares the
///   rendered layer tree with the host;
/// - the interpreter worker (stage-1 fallback path) runs before any
///   AppKit/SwiftUI setup.
@main
enum BreeMain {
    /// Raises inherited descriptor limits before receipt writing or worker routing.
    static func main() {
        // First: nothing may read preferences before an app-host test process
        // switches to its own domain.
        TestProcessDefaults.installIfHostingTests()
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            // Copy settings and stores saved under the pre-rename names, once, before anything reads them.
            LegacyNameMigration.runIfNeeded()
        }
        FileDescriptorLimitController().raiseSoftLimitIfNeeded()
        AppHostProcessReceipt.writeIfRequired()
#if DEBUG
        // Bonsplit's `dlog` and the app's `breeDebugLog` resolve the same
        // debug log file. Route bonsplit through the shared writer so the
        // file has exactly one serialized append path (single O_APPEND
        // handle, monotonic #<seq> line prefixes); with two independent
        // appenders, concurrent lines interleaved and landed out of order.
        Bonsplit.DebugEventLog.setExternalSink { breeDebugLog($0) }
#endif
        BreeWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()
        SurfaceResumeApprovalStore.preloadSigningSecret()
        breeApp.main()
    }
}
