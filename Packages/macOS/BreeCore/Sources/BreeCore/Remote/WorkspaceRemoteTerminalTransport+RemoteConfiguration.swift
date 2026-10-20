public import BreeFoundation
internal import Foundation

/// The protocol used by a remote workspace's interactive terminal.
///
/// BreeCore exposes the shared foundation value as part of its remote-workspace
/// API so callers do not need to import both modules to configure a transport.
public typealias WorkspaceRemoteTerminalTransport = BreeFoundation.WorkspaceRemoteTerminalTransport

extension WorkspaceRemoteTerminalTransport {
    /// Parses a socket remote-configuration value, defaulting an absent value to SSH.
    ///
    /// - Parameter remoteConfigurationValue: The optional `terminal_transport` wire value.
    public init?(remoteConfigurationValue: String?) {
        let normalized = remoteConfigurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized?.isEmpty != false {
            self = .ssh
        } else {
            self.init(rawValue: normalized ?? "")
        }
    }
}
