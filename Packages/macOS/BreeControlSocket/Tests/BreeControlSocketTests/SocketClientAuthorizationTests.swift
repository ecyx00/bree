@testable import BreeControlSocket
import BreeSettings
import Foundation
import Testing

@Suite("Socket client authorization")
struct SocketClientAuthorizationTests {
    private let authorization = SocketClientAuthorization()

    @Test func breeOnlyFailsClosedWhenPeerPidIsUnavailable() {
        #expect(!authorization.isBreeOnlyClientAllowed(
            peerProcessID: nil,
            peerHasSameUID: true,
            isDescendant: { _ in true }
        ))
    }

    @Test func breeOnlyAllowsDescendantPeerPid() {
        #expect(authorization.isBreeOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: false,
            isDescendant: { $0 == 123 }
        ))
    }

    @Test func breeOnlyRejectsNonDescendantPeerPid() {
        #expect(!authorization.isBreeOnlyClientAllowed(
            peerProcessID: 123,
            peerHasSameUID: true,
            isDescendant: { _ in false }
        ))
    }

    @Test func breeOnlyAllowsReparentedClientWithInheritedCapability() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        let command = "hooks claude prompt-submit"

        #expect(authorization.authorizedCommand(
            envelope.wrap(command),
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == command)
    }

    @Test func breeOnlyRejectsReparentedClientWithoutCapability() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )
        #expect(authorization.authorizedCommand(
            "hooks claude prompt-submit",
            peerProcessID: 123,
            peerHasSameUID: true,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func breeOnlyRejectsCapabilityFromDifferentUser() throws {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )
        let capability = authority.issueCapability(
            nonce: Data(repeating: 0x5A, count: SocketClientCapabilityAuthority.secureByteCount)
        )
        let envelope = try #require(SocketClientCapabilityEnvelope(capability: capability))
        #expect(authorization.authorizedCommand(
            envelope.wrap("hooks claude prompt-submit"),
            peerProcessID: 123,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == nil)
    }

    @Test func ownerOnlyAutomationModesRejectDifferentUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: false,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == nil)
        }
    }

    @Test func ownerOnlyAutomationModesAllowSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )

        for mode in [SocketControlMode.automation, .password] {
            #expect(authorization.authorizedCommand(
                "ping",
                accessMode: mode,
                peerProcessID: nil,
                peerHasSameUID: true,
                capabilityAuthority: authority,
                isDescendant: { _ in false }
            ) == "ping")
        }
    }

    @Test func allowAllDoesNotRequireSameUser() {
        let authority = SocketClientCapabilityAuthority(
            secret: Data(repeating: 0xA5, count: SocketClientCapabilityAuthority.secureByteCount),
            audience: "com.bree.test"
        )

        #expect(authorization.authorizedCommand(
            "ping",
            accessMode: .allowAll,
            peerProcessID: nil,
            peerHasSameUID: false,
            capabilityAuthority: authority,
            isDescendant: { _ in false }
        ) == "ping")
    }
}
