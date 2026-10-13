/// Associates a parsed notification-hook configuration with its content fingerprint.
struct BreeNotificationHookParsedConfig {
    let fingerprint: BreeNotificationHookFileFingerprint
    let config: BreeConfigFile?
}
