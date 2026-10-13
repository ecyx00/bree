import Foundation

extension CodingUserInfoKey {
    /// Allows app-owned persisted snapshots to decode reserved built-in Vault capabilities.
    static let breeTrustedPersistedSessionSnapshot = CodingUserInfoKey(
        rawValue: "com.bree.session-snapshot.trusted"
    )!
}

extension Decoder {
    var isTrustedBreePersistedSessionSnapshot: Bool {
        userInfo[.breeTrustedPersistedSessionSnapshot] as? Bool == true
    }
}
