import BreeRemoteWorkspace
@testable import BreeRemoteSession

actor RecordingImmediateClock: RemoteProxyRetryClock {
    private(set) var requestedDelays: [Int] = []

    func sleep(forMilliseconds milliseconds: Int) async throws {
        requestedDelays.append(milliseconds)
    }
}
