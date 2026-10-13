import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite("Ghostty current-directory action dispatcher", .serialized)
struct GhosttyCurrentDirectoryActionDispatcherTests {
    @Test(arguments: [2, 100])
    func replayBoundariesSurviveOrdinaryPWDQueueing(ordinaryCount: Int) async {
        let startBoundary = "/.bree/session-scrollback-replay/test/start"
        let endBoundary = "/.bree/session-scrollback-replay/test/end"
        var deliveredDirectories: [String] = []
        let dispatcher = GhosttyCurrentDirectoryActionDispatcher(
            startBoundary: startBoundary,
            endBoundary: endBoundary
        ) { action in
            deliveredDirectories.append(action.directory)
        }
        let surfaceView = GhosttyNSView(frame: .zero)

        dispatcher.enqueue(
            directory: startBoundary,
            authoritativeGeometry: nil,
            surfaceView: surfaceView,
            terminalSurface: nil
        )
        for index in 0..<ordinaryCount {
            dispatcher.enqueue(
                directory: "/replayed/\(index)",
                authoritativeGeometry: nil,
                surfaceView: surfaceView,
                terminalSurface: nil
            )
        }
        dispatcher.enqueue(
            directory: endBoundary,
            authoritativeGeometry: nil,
            surfaceView: surfaceView,
            terminalSurface: nil
        )
        for index in 0..<ordinaryCount {
            dispatcher.enqueue(
                directory: "/live/\(index)",
                authoritativeGeometry: nil,
                surfaceView: surfaceView,
                terminalSurface: nil
            )
        }

        for _ in 0..<10 where !deliveredDirectories.contains(endBoundary) {
            await Task.yield()
        }

        let startIndex = deliveredDirectories.firstIndex(of: startBoundary)
        let endIndex = deliveredDirectories.firstIndex(of: endBoundary)
        #expect(startIndex != nil)
        #expect(endIndex != nil)
        if let startIndex, let endIndex {
            #expect(startIndex < endIndex)
        }
    }
}
