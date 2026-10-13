/// Stores resolved hooks and their content-sensitive fingerprints for one cache key.
struct BreeNotificationHookCacheEntry {
    let fingerprints: [BreeNotificationHookFileFingerprint]
    let hooks: [BreeResolvedNotificationHook]
    var lastAccessSequence: UInt64
}
