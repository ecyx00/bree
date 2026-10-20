import BreeFoundation
import Foundation
import Testing
@testable import BreeCore

@Suite("SessionRemoteWorkspaceSnapshot persistence shape")
struct SessionRemoteWorkspaceSnapshotTests {
    @Test("codable round trip preserves every field")
    func codableRoundTrip() throws {
        let snapshot = SessionRemoteWorkspaceSnapshot(
            terminalTransport: .mosh,
            terminalProfile: .defaultTmux,
            configuredRemoteCommand: "exec fish",
            destination: "user@host",
            port: 2222,
            identityFile: "/id",
            sshOptions: ["ForwardAgent=yes"],
            preserveAfterTerminalExit: true,
            skipDaemonBootstrap: true,
            relayPort: 7000,
            persistentDaemonSlot: "slot"
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SessionRemoteWorkspaceSnapshot.self, from: data)
        #expect(decoded == snapshot)
    }

    @Test("decodes the persisted wire keys, ignoring removed keys, optional fields absent")
    func decodesLegacyWireShape() throws {
        let json = """
        {
          "transport": "websocket",
          "managedHostID": "vm-1",
          "destination": "user@host",
          "sshOptions": []
        }
        """
        let decoded = try JSONDecoder().decode(
            SessionRemoteWorkspaceSnapshot.self,
            from: Data(json.utf8)
        )
        #expect(decoded.terminalTransport == nil)
        #expect(decoded.terminalProfile == nil)
        #expect(decoded.configuredRemoteCommand == nil)
        #expect(decoded.destination == "user@host")
        #expect(decoded.port == nil)
        #expect(decoded.identityFile == nil)
        #expect(decoded.preserveAfterTerminalExit == nil)
        #expect(decoded.skipDaemonBootstrap == nil)
        #expect(decoded.relayPort == nil)
        #expect(decoded.persistentDaemonSlot == nil)
    }

    @Test("transport raw values are the persisted wire strings")
    func transportRawValues() {
        #expect(WorkspaceRemoteTerminalTransport.ssh.rawValue == "ssh")
        #expect(WorkspaceRemoteTerminalTransport.mosh.rawValue == "mosh")
        #expect(WorkspaceRemoteTerminalProfile.Kind.tmux.rawValue == "tmux")
    }
}
