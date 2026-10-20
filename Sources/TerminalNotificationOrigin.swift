import Foundation

/// Where a notification's text came from, carried with the notification through the
/// store, the hook envelope (`origin`, not hook-patchable), the hook and
/// `notifications.command` environments (`BREE_NOTIFICATION_ORIGIN`), and the feed
/// history. Remote origins are untrusted emitters: the store clamps their side effects to
/// display (no reply shape, no click action, no agent context, no sound override), and
/// remote-origin notifications never consult project `bree.json` hooks — only the global
/// config the user wrote on this Mac.
enum TerminalNotificationOrigin: Hashable, Sendable {
    /// A local process (socket caller, OSC from a local PTY, the app itself).
    case local
    /// A `bree ssh` remote host, confined to the workspace that owns the relay.
    case sshRelay(ownerWorkspaceID: UUID)
    /// A bree remote machine's daemon event stream, attributed by the Mac's surface catalog.
    case remoteHost(machineID: String)
    /// Another Mac on the account (My Devices), from its notification feed. `machineID`
    /// is the device's `SurfaceMachineID` raw value (`device:<uuid>@<tag>`).
    case deviceMac(machineID: String)

    static let localWireValue = "local"
    static let sshRelayWirePrefix = "ssh-relay:"
    static let remoteHostWirePrefix = "managed-host:"
    static let deviceMacWirePrefix = "device-mac:"

    /// `local`, `ssh-relay:<workspace uuid>`, `managed-host:<machine id>`, or
    /// `device-mac:<device machine id>`; what hooks see
    /// in `BREE_NOTIFICATION_ORIGIN` and in the envelope's `origin.value`.
    var wireValue: String {
        switch self {
        case .local:
            return Self.localWireValue
        case .sshRelay(let ownerWorkspaceID):
            return Self.sshRelayWirePrefix + ownerWorkspaceID.uuidString.lowercased()
        case .remoteHost(let machineID):
            return Self.remoteHostWirePrefix + machineID
        case .deviceMac(let machineID):
            return Self.deviceMacWirePrefix + machineID
        }
    }

    /// Envelope `origin.kind`: `local`, `ssh-relay`, `managed-host`, or `device-mac`.
    var kind: String {
        switch self {
        case .local: return "local"
        case .sshRelay: return "ssh-relay"
        case .remoteHost: return "managed-host"
        case .deviceMac: return "device-mac"
        }
    }

    var isRemote: Bool {
        if case .local = self { return false }
        return true
    }

    /// Parses a wire value; anything unrecognized reads as `.local`, so a persisted
    /// history record written by a newer build still decodes.
    init(wireValue: String) {
        if wireValue.hasPrefix(Self.sshRelayWirePrefix),
           let id = UUID(uuidString: String(wireValue.dropFirst(Self.sshRelayWirePrefix.count))) {
            self = .sshRelay(ownerWorkspaceID: id)
        } else if wireValue.hasPrefix(Self.remoteHostWirePrefix) {
            let machineID = String(wireValue.dropFirst(Self.remoteHostWirePrefix.count))
            self = machineID.isEmpty ? .local : .remoteHost(machineID: machineID)
        } else if wireValue.hasPrefix(Self.deviceMacWirePrefix) {
            let machineID = String(wireValue.dropFirst(Self.deviceMacWirePrefix.count))
            self = machineID.isEmpty ? .local : .deviceMac(machineID: machineID)
        } else {
            self = .local
        }
    }
}

extension TerminalNotificationOrigin: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(wireValue: try container.decode(String.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wireValue)
    }
}

/// The `origin` block of the notification-hook envelope. Informational input for hooks
/// (`case "$BREE_NOTIFICATION_ORIGIN" in managed-host:*) …`), never patchable by them.
struct TerminalNotificationPolicyOriginContext: Codable, Sendable, Equatable {
    var kind: String
    var value: String
    /// The machine id for `managed-host` and `device-mac`; absent otherwise.
    var machine: String?

    init(_ origin: TerminalNotificationOrigin) {
        kind = origin.kind
        value = origin.wireValue
        switch origin {
        case .remoteHost(let machineID), .deviceMac(let machineID):
            machine = machineID
        case .local, .sshRelay:
            break
        }
    }
}
