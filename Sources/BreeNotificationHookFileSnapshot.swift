import Foundation

/// Couples a hook file's cache identity with the exact bytes represented by that identity.
struct BreeNotificationHookFileSnapshot {
    let fingerprint: BreeNotificationHookFileFingerprint
    let contents: Data?
}
