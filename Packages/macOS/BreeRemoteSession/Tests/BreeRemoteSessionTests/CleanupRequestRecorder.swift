import BreeRemoteSession

@MainActor
final class CleanupRequestRecorder {
    var requests: [NativeSSHControlMasterCleanupRequest] = []
}
