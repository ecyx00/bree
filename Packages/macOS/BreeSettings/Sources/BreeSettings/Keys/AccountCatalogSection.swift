import Foundation

/// Local settings under the dotted-id prefix `account.*`.
public struct AccountCatalogSection: SettingCatalogSection {
    public let piiDisplayMode = DefaultsKey<PIIDisplayMode>(
        id: "account.piiDisplayMode",
        defaultValue: .visible,
        userDefaultsKey: "bree.settings.piiDisplayMode"
    )

    public let welcomeShown = DefaultsKey<Bool>(
        id: "account.welcomeShown",
        defaultValue: false,
        userDefaultsKey: "breeWelcomeShown"
    )

    public init() {}
}
