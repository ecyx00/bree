import BreeFoundation
import Foundation
import Testing
@testable import BreeSettings

struct AccentColorSettingTests {
    @Test func catalogKeyStoresTheModeTheResolverReads() throws {
        let suite = "AccentColorSettingTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = AppCatalogSection().accentColor

        #expect(key.id == "app.accentColor")
        #expect(key.userDefaultsKey == BreeAccentColorMode.userDefaultsKey)
        #expect(key.defaultValue == .system)

        let client = UserDefaultsSettingsClient(defaults: defaults)
        for mode in BreeAccentColorMode.allCases {
            client.set(mode, for: key)
            #expect(BreeAccentColorMode.stored(in: defaults) == mode)
            #expect(client.value(for: key) == mode)
        }
    }
}
