import BreeSidebarInterpreterClient
import BreeSidebarRemoteRender
import Darwin

/// Routes a re-executed bree process into its requested isolated worker mode.
struct BreeWorkerEntrypoint {
    private let arguments: [String]

    /// Creates a worker router for one process argument snapshot.
    init(arguments: [String]) {
        self.arguments = arguments
    }

    /// Runs the requested worker instead of continuing normal app startup.
    func runIfRequested() {
        if arguments.contains(
            TerminalPastePreparationWorkerClient.workerModeArgument
        ) {
            exit(
                TerminalPastePreparationWorker().run(
                    arguments: arguments
                )
            )
        }
        if arguments.contains(RenderWorkerClient.workerModeArgument) {
            runSidebarRenderWorker()
        }
        if arguments.contains(InterpreterClient.workerModeArgument) {
            runSidebarInterpreterWorker()
            exit(0)
        }
    }
}
