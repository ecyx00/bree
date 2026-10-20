internal import BreeCore
internal import BreeFoundation
internal import Foundation

/// Identifies one native SSH endpoint for connection-attempt coordination.
struct NativeSSHConnectionKey: Hashable, Sendable {
    let destination: String
    let port: Int?

    init?(
        configuration: WorkspaceRemoteConfiguration,
        sharingOptions: SSHConnectionSharingOptions
    ) {
        if let controlPath = sharingOptions.breeOwnedControlPath(in: configuration.sshOptions),
           !controlPath.contains("%") {
            self.destination = "control-path:\(controlPath)"
            self.port = nil
            return
        }
        let destination = configuration.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return nil }
        // Preserve the user/config alias exactly. Usernames can be
        // case-sensitive, so lowercasing the entire destination could make
        // two distinct OpenSSH `%C` endpoints share lifecycle state.
        self.destination = destination
        self.port = configuration.port
    }
}
