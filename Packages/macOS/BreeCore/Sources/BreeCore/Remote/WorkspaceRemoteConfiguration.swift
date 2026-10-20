public import BreeFoundation
public import Foundation

/// Everything needed to establish and operate one remote-workspace connection:
/// transport selection, SSH identity/options, relay and proxy wiring, and the
/// persistent-PTY restore knobs.
///
/// This is a pure `Sendable` value; all normalization helpers are pure string
/// transforms (see `WorkspaceRemoteConfiguration+SSHOptionNormalization.swift`).
public struct WorkspaceRemoteConfiguration: Equatable, Sendable {
    /// Protocol used by the user-facing interactive terminal.
    public let terminalTransport: WorkspaceRemoteTerminalTransport
    /// Original durable descriptor when restoring managed SSH. A legacy owner is
    /// retained for recovery, never silently converted into a new TUI session.
    public var restoredSSHSession: SessionRemoteWorkspaceSnapshot? = nil

    /// Durable program profile opened in the interactive terminal.
    public let terminalProfile: WorkspaceRemoteTerminalProfile
    /// Effective host-configured command chained after bree's interactive bootstrap.
    public let configuredRemoteCommand: String?
    /// SSH destination (`user@host` or `host`).
    public let destination: String
    /// Explicit SSH port, when configured.
    public let port: Int?
    /// Explicit identity file path, when configured.
    public let identityFile: String?
    /// `-o` SSH options applied to every spawned SSH process.
    public let sshOptions: [String]
    /// Deterministic local proxy port override (docker regression test hook).
    public let localProxyPort: Int?
    /// CLI relay port for remote `bree` command forwarding.
    public let relayPort: Int?
    /// Relay identity advertised to the remote CLI.
    public let relayID: String?
    /// Shared secret authenticating relay clients.
    public let relayToken: String?
    /// Local control-socket path forwarded over the relay.
    public let localSocketPath: String?
    /// Local workspace that owns VM-originated CLI bridge requests.
    public let ownerWorkspaceID: UUID?
    /// Startup command run in new terminal surfaces for this workspace.
    public let terminalStartupCommand: String?
    /// One-shot token gating auto-connect on foreground SSH authentication.
    public let foregroundAuthToken: String?
    /// SSH agent socket injected as `SSH_AUTH_SOCK`, when usable.
    public let agentSocketPath: String?
    /// Whether remote PTY sessions outlive their local terminal surface.
    public let preserveAfterTerminalExit: Bool
    /// Slot name isolating persistent daemons per workspace identity.
    public let persistentDaemonSlot: String?
    /// Runtime generation assigned by the native-SSH connection owner.
    ///
    /// This value is deliberately excluded from configuration equality: it
    /// identifies one broker lease, not a user-visible connection setting.
    public let sshControlMasterLeaseGeneration: UUID?

    /// Creates a configuration, normalizing the agent socket path and allowing
    /// persistent daemon state only for SSH-backed interactive terminals.
    public init(
        terminalTransport: WorkspaceRemoteTerminalTransport = .ssh,
        terminalProfile: WorkspaceRemoteTerminalProfile = .shell,
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        localProxyPort: Int?,
        relayPort: Int?,
        relayID: String?,
        relayToken: String?,
        localSocketPath: String?,
        ownerWorkspaceID: UUID? = nil,
        terminalStartupCommand: String?,
        configuredRemoteCommand: String? = nil,
        foregroundAuthToken: String? = nil,
        agentSocketPath: String? = nil,
        preserveAfterTerminalExit: Bool = false,
        persistentDaemonSlot: String? = nil,
        sshControlMasterLeaseGeneration: UUID? = nil
    ) {
        self.terminalTransport = terminalTransport
        self.terminalProfile = terminalProfile
        self.destination = destination
        self.port = port
        self.identityFile = identityFile
        self.sshOptions = sshOptions
        self.localProxyPort = localProxyPort
        self.relayPort = relayPort
        self.relayID = relayID
        self.relayToken = relayToken
        self.localSocketPath = localSocketPath
        self.ownerWorkspaceID = ownerWorkspaceID
        self.terminalStartupCommand = terminalStartupCommand
        self.configuredRemoteCommand = Self.normalizedOptionalValue(configuredRemoteCommand)
        self.foregroundAuthToken = foregroundAuthToken
        self.agentSocketPath = Self.normalizedAgentSocketPath(agentSocketPath)
        let preservesPersistentPTY = terminalTransport == .ssh && preserveAfterTerminalExit
        self.preserveAfterTerminalExit = preservesPersistentPTY
        self.persistentDaemonSlot = preservesPersistentPTY
            ? Self.normalizedPersistentDaemonSlot(persistentDaemonSlot)
            : nil
        self.sshControlMasterLeaseGeneration = sshControlMasterLeaseGeneration
    }

    /// Compares user-visible connection settings while ignoring the runtime lease generation.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.restoredSSHSession == rhs.restoredSSHSession &&
            lhs.terminalTransport == rhs.terminalTransport &&
            lhs.terminalProfile == rhs.terminalProfile &&
            lhs.configuredRemoteCommand == rhs.configuredRemoteCommand &&
            lhs.destination == rhs.destination &&
            lhs.port == rhs.port &&
            lhs.identityFile == rhs.identityFile &&
            lhs.sshOptions == rhs.sshOptions &&
            lhs.localProxyPort == rhs.localProxyPort &&
            lhs.relayPort == rhs.relayPort &&
            lhs.relayID == rhs.relayID &&
            lhs.relayToken == rhs.relayToken &&
            lhs.localSocketPath == rhs.localSocketPath &&
            lhs.ownerWorkspaceID == rhs.ownerWorkspaceID &&
            lhs.terminalStartupCommand == rhs.terminalStartupCommand &&
            lhs.foregroundAuthToken == rhs.foregroundAuthToken &&
            lhs.agentSocketPath == rhs.agentSocketPath &&
            lhs.preserveAfterTerminalExit == rhs.preserveAfterTerminalExit &&
            lhs.persistentDaemonSlot == rhs.persistentDaemonSlot
    }

    /// Resolves the SSH agent socket to use for a remote configuration from an explicit socket or durable options.
    public static func resolvedAgentSocketPath(
        sshOptions: [String],
        explicitAgentSocketPath: String? = nil,
        explicitAgentSocketPathIsSet: Bool = false
    ) -> String? {
        if explicitAgentSocketPathIsSet {
            return existingAgentSocketPath(explicitAgentSocketPath)
        }
        return existingAgentSocketPath(explicitAgentSocketPath)
            ?? existingAgentSocketPath(sshAgentSocketPath(for: sshOptions))
    }

    /// `destination` or `destination:port` for user-facing status text.
    public var displayTarget: String {
        guard let port else { return destination }
        return "\(destination):\(port)"
    }

    /// The stable key the proxy broker uses to share one daemon tunnel across
    /// workspaces that target the same transport identity.
    public var proxyBrokerTransportKey: String {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedIdentity = Self.normalizedIdentityPath(identityFile) ?? ""
        let normalizedLocalProxyPort = localProxyPort.map(String.init) ?? ""
        let normalizedOptions = Self.proxyBrokerSSHOptions(sshOptions).joined(separator: "\u{1f}")
        let normalizedRequiredCapabilities = preserveAfterTerminalExit ? "pty.session" : ""
        let normalizedPersistentDaemonSlot = persistentDaemonSlot ?? ""
        let normalizedOwnerWorkspaceID = ownerWorkspaceID?.uuidString.lowercased() ?? ""
        return [
            normalizedDestination,
            normalizedPort,
            normalizedIdentity,
            normalizedOptions,
            normalizedLocalProxyPort,
            normalizedRequiredCapabilities,
            normalizedPersistentDaemonSlot,
            normalizedOwnerWorkspaceID,
        ]
            .joined(separator: "\u{1e}")
    }

    private static func proxyBrokerSSHOptions(_ options: [String]) -> [String] {
        durableSSHOptions(options)
    }

    /// True when `other` addresses the same persistent-PTY daemon identity, so
    /// reconfiguration can keep existing persistent sessions alive.
    public func hasSamePersistentPTYIdentity(as other: WorkspaceRemoteConfiguration) -> Bool {
        guard preserveAfterTerminalExit,
              other.preserveAfterTerminalExit,
              let persistentDaemonSlot,
              persistentDaemonSlot == other.persistentDaemonSlot else {
            return false
        }

        return destination.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            && port == other.port
            && relayPort == other.relayPort
            && ownerWorkspaceID == other.ownerWorkspaceID
            && Self.normalizedIdentityPath(identityFile)
                == Self.normalizedIdentityPath(other.identityFile)
            && Self.proxyBrokerSSHOptions(sshOptions) == Self.proxyBrokerSSHOptions(other.sshOptions)
    }

    /// Returns the stable lookup key for this configuration's persistent PTY.
    ///
    /// The key includes the owner workspace. Callers
    /// should still verify a candidate with
    /// ``hasSamePersistentPTYIdentity(as:)`` after the dictionary lookup.
    /// An empty array means this configuration cannot own a persistent PTY.
    public var persistentPTYIdentityLookupKeys: [String] {
        guard preserveAfterTerminalExit, let persistentDaemonSlot else {
            return []
        }
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPort = port.map(String.init) ?? ""
        let normalizedRelayPort = relayPort.map(String.init) ?? ""
        let normalizedIdentity = Self.normalizedIdentityPath(identityFile) ?? ""
        let normalizedSSHOptions = Self.proxyBrokerSSHOptions(sshOptions)
            .joined(separator: "\u{1f}")
        let components: [String] = [
            normalizedDestination,
            normalizedPort,
            normalizedRelayPort,
            normalizedIdentity,
            normalizedSSHOptions,
            persistentDaemonSlot,
        ]
        let base = components.joined(separator: "\u{1e}")
        let exact = base + "\u{1e}" + (ownerWorkspaceID?.uuidString.lowercased() ?? "")
        return [exact]
    }

    /// True when `other` addresses the same remote CLI relay metadata namespace.
    ///
    /// Relay metadata lives under `$HOME/.bree/relay/<relayPort>` on the remote
    /// transport endpoint. This comparison intentionally ignores persistent
    /// slots, SSH options, and credentials: those inputs may change while still
    /// reaching the same remote account, so treating that case as shared avoids
    /// starting a replacement that could overwrite incompletely cleaned metadata.
    ///
    /// - Parameter other: The remote configuration to compare.
    /// - Returns: `true` when both configurations address the same relay metadata namespace.
    public func hasSameRemoteRelayNamespace(as other: WorkspaceRemoteConfiguration) -> Bool {
        guard let relayPort, relayPort > 0, relayPort == other.relayPort else { return false }
        return destination.trimmingCharacters(in: .whitespacesAndNewlines)
                == other.destination.trimmingCharacters(in: .whitespacesAndNewlines)
            && port == other.port
    }

    /// Returns a copy scoped to the local workspace that owns this remote
    /// configuration. Remote CLI bridges use this to reject cross-workspace
    /// requests before they reach the app control socket.
    public func scopedToOwnerWorkspace(_ workspaceID: UUID) -> WorkspaceRemoteConfiguration {
        var copy = WorkspaceRemoteConfiguration(
            terminalTransport: terminalTransport,
            terminalProfile: terminalProfile,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath,
            ownerWorkspaceID: workspaceID,
            terminalStartupCommand: terminalStartupCommand,
            configuredRemoteCommand: configuredRemoteCommand,
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: agentSocketPath,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot
        )
        copy.restoredSSHSession = restoredSSHSession
        return copy
    }

    /// Returns a copy carrying the broker generation for one native-SSH lease.
    public func withSSHControlMasterLeaseGeneration(_ generation: UUID) -> WorkspaceRemoteConfiguration {
        var copy = WorkspaceRemoteConfiguration(
            terminalTransport: terminalTransport,
            terminalProfile: terminalProfile,
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions,
            localProxyPort: localProxyPort,
            relayPort: relayPort,
            relayID: relayID,
            relayToken: relayToken,
            localSocketPath: localSocketPath,
            ownerWorkspaceID: ownerWorkspaceID,
            terminalStartupCommand: terminalStartupCommand,
            configuredRemoteCommand: configuredRemoteCommand,
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: agentSocketPath,
            preserveAfterTerminalExit: preserveAfterTerminalExit,
            persistentDaemonSlot: persistentDaemonSlot,
            sshControlMasterLeaseGeneration: generation
        )
        copy.restoredSSHSession = restoredSSHSession
        return copy
    }
}

extension WorkspaceRemoteConfiguration {
    /// Environment injected into remote terminal startup commands
    /// (`SSH_AUTH_SOCK` only), or `nil` when no agent socket is configured.
    public var sshTerminalStartupEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        return ["SSH_AUTH_SOCK": agentSocketPath]
    }

    /// Full process environment for spawned ssh/scp processes with
    /// `SSH_AUTH_SOCK` overridden, or `nil` when no agent socket is configured.
    public var sshProcessEnvironment: [String: String]? {
        guard let agentSocketPath = self.agentSocketPath else {
            return nil
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_AUTH_SOCK"] = agentSocketPath
        return environment
    }

    /// SSH options propagated to a forked agent workspace (durable subset).
    public static func forkedAgentSSHOptions(_ options: [String]) -> [String] {
        forkedWorkspaceSSHOptions(options)
    }

    /// The durable snapshot persisted into session state, or `nil` for
    /// non-restorable remotes.
    public func sessionSnapshot(sshOptionsOverride: [String]? = nil) -> SessionRemoteWorkspaceSnapshot? {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty else { return nil }

        if let restoredSSHSession { return restoredSSHSession }
        let retainsRelayNamespace = preserveAfterTerminalExit || terminalTransport == .mosh

        let snapshot = SessionRemoteWorkspaceSnapshot(
            terminalTransport: terminalTransport,
            terminalProfile: terminalProfile,
            configuredRemoteCommand: configuredRemoteCommand,
            destination: normalizedDestination,
            port: port,
            identityFile: Self.normalizedIdentityPath(identityFile),
            sshOptions: sshOptionsOverride ?? Self.durableSSHOptions(sshOptions),
            preserveAfterTerminalExit: preserveAfterTerminalExit ? true : nil,
            relayPort: retainsRelayNamespace ? relayPort : nil,
            persistentDaemonSlot: preserveAfterTerminalExit ? persistentDaemonSlot : nil
        )
        return snapshot
    }
}
