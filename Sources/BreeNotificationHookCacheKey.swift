/// Identifies notification-hook resolution for one working directory and global configuration.
struct BreeNotificationHookCacheKey: Hashable {
    let directory: String?
    let globalConfigPath: String
}
