import BREEAuthCore
import Foundation
import Testing

/// The demonstration-content activation gate: a server-written boolean on the
/// Stack account's `clientReadOnlyMetadata`, mirrored onto `BREEAuthUser`.
/// Only an explicit JSON `true` activates it, unknown/legacy payloads fail
/// closed, and persisted identity cards from older builds decode as
/// not-flagged.
@Suite("BREEAuthUser demonstration content")
struct BREEAuthUserDemonstrationContentTests {
    @Test("Metadata resolves only an explicit boolean true")
    func metadataResolvesOnlyExplicitBooleanTrue() {
        func resolve(_ metadata: [String: Any]?) -> Bool {
            BREEAuthUser.demonstrationContentEnabled(
                fromClientReadOnlyMetadata: metadata
            )
        }

        #expect(resolve(["breeReviewDemoContent": true]))
        #expect(!resolve(["breeReviewDemoContent": false]))
        #expect(!resolve(nil))
        #expect(!resolve([:]))
        #expect(!resolve(["breePlan": "pro"]))
        // Fail closed on every non-boolean shape a bad write could produce.
        #expect(!resolve(["breeReviewDemoContent": "true"]))
        #expect(!resolve(["breeReviewDemoContent": 1]))
        #expect(!resolve(["breeReviewDemoContent": 2.5]))
        #expect(!resolve(["breeReviewDemoContent": ["enabled": true]]))
        #expect(!resolve(["breeReviewDemoContent": NSNull()]))
    }

    @Test("Metadata parsed from real JSON activates the flag")
    func metadataParsedFromJSONActivates() throws {
        let payload = #"{"breeReviewDemoContent": true, "breePlan": "pro"}"#
        let metadata = try JSONSerialization.jsonObject(
            with: Data(payload.utf8)
        ) as? [String: Any]
        #expect(BREEAuthUser.demonstrationContentEnabled(
            fromClientReadOnlyMetadata: metadata
        ))

        let numericPayload = #"{"breeReviewDemoContent": 1}"#
        let numericMetadata = try JSONSerialization.jsonObject(
            with: Data(numericPayload.utf8)
        ) as? [String: Any]
        #expect(!BREEAuthUser.demonstrationContentEnabled(
            fromClientReadOnlyMetadata: numericMetadata
        ))
    }

    @Test("Identity cards persisted before the flag decode as not flagged")
    func legacyIdentityCardsDecodeAsNotFlagged() throws {
        let legacy = #"{"id": "user-1", "primaryEmail": "user@example.com"}"#
        let user = try JSONDecoder().decode(BREEAuthUser.self, from: Data(legacy.utf8))
        #expect(!user.demonstrationContentEnabled)
        #expect(user.id == "user-1")
    }

    @Test("The flag round-trips through the persisted identity card")
    func flagRoundTripsThroughCodable() throws {
        let flagged = BREEAuthUser(
            id: "user-2",
            primaryEmail: "review@example.com",
            displayName: "Review",
            demonstrationContentEnabled: true
        )
        let decoded = try JSONDecoder().decode(
            BREEAuthUser.self,
            from: JSONEncoder().encode(flagged)
        )
        #expect(decoded == flagged)
        #expect(decoded.demonstrationContentEnabled)
    }

    @Test("Default construction is not flagged")
    func defaultConstructionIsNotFlagged() {
        let user = BREEAuthUser(id: "user-3", primaryEmail: nil, displayName: nil)
        #expect(!user.demonstrationContentEnabled)
    }
}
