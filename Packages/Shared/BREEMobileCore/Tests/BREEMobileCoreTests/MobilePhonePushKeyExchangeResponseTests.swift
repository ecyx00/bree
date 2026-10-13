import Foundation
import Testing
@testable import BREEMobileCore

@Suite struct MobilePhonePushKeyExchangeResponseTests {
    private func reply(
        accountID: String = "account-1",
        macDeviceID: String = "physical-device",
        macInstanceTag: String = "nightly",
        macBuildID: String = "com.bree.app.nightly"
    ) -> MobilePhonePushKeyExchangeResponse {
        MobilePhonePushKeyExchangeResponse(
            descriptor: MobilePhonePushPublicKeyDescriptor(
                installationID: "mac-install",
                keyID: "mac-key",
                publicKey: Data(repeating: 1, count: 32)
            ),
            accountID: accountID,
            macDeviceID: macDeviceID,
            macInstanceTag: macInstanceTag,
            macBuildID: macBuildID
        )
    }

    /// The status names the team-directory computer; the reply names the
    /// physical device push tuples use. A reply from the same Mac must pass.
    @Test func replyFromTheStatusMacIsAccepted() {
        #expect(reply().mismatchedFields(
            accountID: "account-1",
            macInstanceTag: "nightly",
            macClientNamespace: "mac:com.bree.app.nightly"
        ).isEmpty)
    }

    @Test func contradictingFieldsAreNamed() {
        #expect(reply(accountID: "account-2", macInstanceTag: "default", macBuildID: "com.bree.app")
            .mismatchedFields(
                accountID: "account-1",
                macInstanceTag: "nightly",
                macClientNamespace: "mac:com.bree.app.nightly"
            ) == ["account", "mac_instance_tag", "mac_namespace"])
    }
}
