import BreeRemoteWorkspace
import Foundation
@testable import BreeRemoteSession

struct IntentionalCleanupRelayCommandRewriter: RemoteRelayCommandRewriting {
    func rewriteRemoteRelayCommandLine(
        _ commandLine: Data,
        workspaceAliases: [UUID: UUID],
        surfaceAliases: [UUID: UUID]
    ) -> Data { commandLine }
}
