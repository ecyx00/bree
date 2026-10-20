public import BreeFoundation

/// The durable, codable subset of a remote-workspace configuration persisted
/// in session snapshots so a remote workspace can be restored across launches.
///
/// Wire/persistence shape: field names are encoded by `Codable`; do not rename
/// stored properties without a migration.
public struct SessionRemoteWorkspaceSnapshot: Codable, Equatable, Sendable {
    /// Explicit persistent SSH owner; absent in legacy daemon snapshots.
    public var sshSessionOwner: String? = nil

    /// The interactive terminal protocol, absent in snapshots written before Mosh support.
    public var terminalTransport: WorkspaceRemoteTerminalTransport? = nil
    /// Durable terminal program intent, absent in snapshots written before terminal profiles.
    public var terminalProfile: WorkspaceRemoteTerminalProfile? = nil
    /// Effective host-configured command for the managed interactive shell.
    public var configuredRemoteCommand: String? = nil
    /// SSH destination (`user@host` or `host`).
    public var destination: String
    /// Explicit SSH port, when one was configured.
    public var port: Int?
    /// Explicit identity file path, when one was configured.
    public var identityFile: String?
    /// Durable `-o` SSH options captured from the live configuration.
    public var sshOptions: [String]
    /// Whether remote PTY sessions outlive their local terminal surface.
    public var preserveAfterTerminalExit: Bool?
    /// Decode-only marker: snapshots written for pre-baked remote hosts (removed) carry `true`
    /// and are never restored. Never written by current code.
    public var skipDaemonBootstrap: Bool?
    /// The CLI relay port captured for persistent-PTY restore.
    public var relayPort: Int? = nil
    /// The persistent daemon slot captured for persistent-PTY restore.
    public var persistentDaemonSlot: String? = nil

    /// Creates a snapshot value; mirrors the synthesized memberwise initializer.
    public init(
        terminalTransport: WorkspaceRemoteTerminalTransport? = nil,
        terminalProfile: WorkspaceRemoteTerminalProfile? = nil,
        configuredRemoteCommand: String? = nil,
        destination: String,
        port: Int? = nil,
        identityFile: String? = nil,
        sshOptions: [String] = [],
        preserveAfterTerminalExit: Bool? = nil,
        skipDaemonBootstrap: Bool? = nil,
        relayPort: Int? = nil,
        persistentDaemonSlot: String? = nil
    ) {
        self.terminalTransport = terminalTransport
        self.terminalProfile = terminalProfile
        self.configuredRemoteCommand = configuredRemoteCommand
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.preserveAfterTerminalExit = preserveAfterTerminalExit
        self.skipDaemonBootstrap = skipDaemonBootstrap
        self.relayPort = relayPort
        self.persistentDaemonSlot = persistentDaemonSlot
    }
}
