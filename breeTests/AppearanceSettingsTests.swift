import XCTest
import AppKit
import SwiftUI

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
final class AppearanceSettingsTests: XCTestCase {
    func testBundleIconPersistenceAllowsStableReleaseBundle() {
        XCTAssertTrue(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app",
                appBundleLastPathComponent: "bree.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceSkipsNightlyBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app.nightly",
                appBundleLastPathComponent: "bree NIGHTLY.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app.nightly.issue-4350",
                appBundleLastPathComponent: "bree NIGHTLY issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceRejectsMismatchedStableIdentifierAndPath() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app",
                appBundleLastPathComponent: "bree NIGHTLY.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceSkipsDebugBundles() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app.debug",
                appBundleLastPathComponent: "Bree Dev.app",
                persistenceDisabled: false
            )
        )
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app.debug.issue-4350",
                appBundleLastPathComponent: "Bree Dev issue-4350.app",
                persistenceDisabled: false
            )
        )
    }

    func testBundleIconPersistenceHonorsDisableDefault() {
        XCTAssertFalse(
            AppBundleIconPersistencePolicy.shouldPersist(
                bundleIdentifier: "com.bree.app",
                appBundleLastPathComponent: "bree.app",
                persistenceDisabled: true
            )
        )
    }

    func testBundleIconPersistenceMirrorsSmokeLaunchArgumentToDefaults() {
        let suiteName = "AppearanceSettingsTests.BundleIconPersistence.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: [AppBundleIconPersistencePolicy.disablePersistenceArgument]
        )
        XCTAssertEqual(
            defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool,
            true
        )

        AppBundleIconPersistencePolicy.updateDisableDefault(
            defaults: defaults,
            launchArguments: []
        )
        XCTAssertEqual(
            defaults.object(forKey: AppBundleIconPersistencePolicy.disablePersistenceDefaultsKey) as? Bool,
            false
        )
    }

    // Regression: https://github.com/ecyx00/bree/issues/8938
    // Install the appearance-resolved config before changing Ghostty's surface
    // color scheme. Applying the scheme to the stale config can emit its old
    // background alongside the new config's foreground, producing black text
    // on a black terminal after a light-appearance reload.
    func testAppConfigReloadRefreshUpdatesSurfaceConfigBeforeColorSchemeAndRedraw() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3851))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: "appearanceSync:test",
            reloadSurfaceConfiguration: { surface, soft, source in
                XCTAssertEqual(surface, fakeSurface)
                XCTAssertTrue(soft)
                events.append("reload:\(source)")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        XCTAssertEqual(events, [
            "reload:appearanceSync:test",
            "color-scheme",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testAppConfigReloadRefreshSkipsSurfaceConfigUpdateWhenSurfaceIsUnavailable() {
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: nil,
            source: "appearanceSync:teardown",
            reloadSurfaceConfiguration: { _, _, _ in
                events.append("reload")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        XCTAssertEqual(events, [
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testAppConfigReloadRefreshAppliesSurfaceColorSchemeForPreviewReload() throws {
        let fakeSurface = try XCTUnwrap(UnsafeMutableRawPointer(bitPattern: 0x3852))
        var events: [String] = []

        GhosttySurfaceConfigurationRefresh.applyAfterAppConfigReload(
            to: fakeSurface,
            source: GhosttySurfaceConfigurationRefresh.breeThemeReloadPreviewSource,
            reloadSurfaceConfiguration: { _, soft, source in
                XCTAssertTrue(soft)
                events.append("reload:\(source)")
            },
            applySurfaceColorScheme: {
                events.append("color-scheme")
            },
            refreshHostBackground: {
                events.append("host-background")
            },
            forceRefresh: { reason in
                events.append("force-refresh:\(reason)")
            }
        )

        XCTAssertEqual(events, [
            "reload:\(GhosttySurfaceConfigurationRefresh.breeThemeReloadPreviewSource)",
            "color-scheme",
            "host-background",
            "force-refresh:\(GhosttySurfaceConfigurationRefresh.forceRefreshReason)"
        ])
    }

    func testBreeThemeFinalReloadUsesFinalSource() {
        XCTAssertEqual(
            GhosttySurfaceConfigurationRefresh.breeThemeReloadSource(phase: "final"),
            GhosttySurfaceConfigurationRefresh.breeThemeReloadFinalSource
        )
    }

    func testBreeThemePreviewReloadIsDebounced() {
        XCTAssertEqual(
            GhosttySurfaceConfigurationRefresh.breeThemeReloadSource(phase: "preview"),
            GhosttySurfaceConfigurationRefresh.breeThemeReloadPreviewSource
        )
        XCTAssertTrue(
            GhosttySurfaceConfigurationRefresh.shouldDebounceBreeThemeReload(
                source: GhosttySurfaceConfigurationRefresh.breeThemeReloadPreviewSource
            )
        )
        XCTAssertTrue(
            GhosttySurfaceConfigurationRefresh.shouldDebounceBreeThemeReload(
                source: GhosttySurfaceConfigurationRefresh.breeThemeReloadLegacySource
            )
        )
        XCTAssertFalse(
            GhosttySurfaceConfigurationRefresh.shouldDebounceBreeThemeReload(
                source: GhosttySurfaceConfigurationRefresh.breeThemeReloadFinalSource
            )
        )
    }

    func testResolvedModeDefaultsToDarkWhenUnsetOrLegacy() {
        let suiteName = "AppearanceSettingsTests.Default.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.removeObject(forKey: AppearanceSettings.appearanceModeKey)
        XCTAssertEqual(AppearanceSettings.resolvedMode(defaults: defaults), .dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)

        // Bree is dark only: an old Light or System value is rewritten to dark.
        for legacy in [AppearanceMode.light, .system, .auto] {
            defaults.set(legacy.rawValue, forKey: AppearanceSettings.appearanceModeKey)
            XCTAssertEqual(AppearanceSettings.resolvedMode(defaults: defaults), .dark)
            XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)
        }
        XCTAssertEqual(AppearanceMode.visibleCases, [.dark])
    }

    func testCurrentColorSchemePreferenceUsesStoredDarkModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.dark.rawValue,
            appleInterfaceStyle: nil
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testCurrentColorSchemePreferenceIgnoresStoredLightModeBeforeAppAppearanceExists() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.light.rawValue,
            appleInterfaceStyle: nil
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testCurrentColorSchemePreferenceStaysDarkForSystemMode() {
        withTemporaryAppearanceDefaults(
            appearanceMode: AppearanceMode.system.rawValue,
            appleInterfaceStyle: "Dark"
        ) {
            XCTAssertEqual(
                GhosttyConfig.currentColorSchemePreference(appAppearance: nil),
                .dark
            )
        }
    }

    func testColorSchemePreferenceStaysDarkWhenSystemStyleIsLight() {
        let suiteName = "AppearanceSettingsTests.SystemLight.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        defaults.removeObject(forKey: "AppleInterfaceStyle")
        let lightSystem = AppearanceSettings.SystemAppearance(interfaceStyle: nil)

        XCTAssertEqual(
            AppearanceSettings.colorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .dark
        )
        XCTAssertEqual(
            GhosttyConfig.currentColorSchemePreference(appAppearance: nil, defaults: defaults, systemAppearance: lightSystem),
            .dark
        )
    }

    func testSplitGhosttyThemeUsesStoredDarkModeWhenAppAppearanceIsStaleLight() {
        let suiteName = "AppearanceSettingsTests.SplitThemeStoredDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Apple System Colors")
    }

    func testSplitGhosttyThemeStaysDarkForStoredLightMode() {
        let suiteName = "AppearanceSettingsTests.testSplitGhosttyThemeStaysDarkForStoredLightMode.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.light.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Light")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Catppuccin Latte,dark:Apple System Colors",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Apple System Colors")
    }

    func testSplitGhosttyThemeStaysDarkForSystemModeWithLightSystem() {
        let suiteName = "AppearanceSettingsTests.testSplitGhosttyThemeStaysDarkForSystemModeWithLightSystem.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .darkAqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: nil)
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Monokai Pro Machine")
    }

    func testSplitGhosttyThemeStaysDarkForSystemModeWithDarkSystem() {
        let suiteName = "AppearanceSettingsTests.testSplitGhosttyThemeStaysDarkForSystemModeWithDarkSystem.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)

        let preferredColorScheme = GhosttyConfig.currentColorSchemePreference(
            appAppearance: NSAppearance(named: .aqua),
            defaults: defaults,
            systemAppearance: .init(interfaceStyle: "Dark")
        )
        let resolvedTheme = GhosttyConfig.resolveThemeName(
            from: "light:Monokai Pro Light,dark:Monokai Pro Machine",
            preferredColorScheme: preferredColorScheme
        )

        XCTAssertEqual(preferredColorScheme, .dark)
        XCTAssertEqual(resolvedTheme, "Monokai Pro Machine")
    }

    func testColorSchemeOverrideIsAlwaysDark() {
        for raw in [AppearanceMode.light.rawValue, AppearanceMode.dark.rawValue, AppearanceMode.system.rawValue,
                    AppearanceMode.auto.rawValue, "invalid", nil] {
            XCTAssertEqual(AppearanceSettings.colorSchemeOverride(for: raw), .dark)
        }
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.light.rawValue, fallback: .light), .dark)
        XCTAssertEqual(AppearanceSettings.colorScheme(for: AppearanceMode.system.rawValue, fallback: .light), .dark)
    }

    func testSelectingDarkModeAppliesRuntimeAppearanceAndSynchronizesTerminalTheme() {
        let suiteName = "AppearanceSettingsTests.SelectDark.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceName: NSAppearance.Name?
        var synchronizedAppearanceName: NSAppearance.Name?
        var synchronizedSource: String?
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                synchronizedSource = source
            },
            systemAppearance: {
                XCTFail("Dark mode should not resolve system appearance")
                return nil
            }
        )

        let selected = AppearanceSettings.selectMode(
            .dark,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)
        XCTAssertEqual(appliedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedSource, "settings.themePicker")
    }

    func testSelectingSystemModeStillAppliesDarkAppearance() {
        let suiteName = "AppearanceSettingsTests.SelectSystem.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var appliedAppearanceName: NSAppearance.Name?
        let environment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { _, _ in },
            systemAppearance: {
                XCTFail("Dark-only mode should not resolve system appearance")
                return nil
            }
        )

        let selected = AppearanceSettings.selectMode(
            .system,
            defaults: defaults,
            source: "settings.themePicker",
            environment: environment
        )

        XCTAssertEqual(selected, .dark)
        XCTAssertEqual(defaults.string(forKey: AppearanceSettings.appearanceModeKey), AppearanceMode.dark.rawValue)
        XCTAssertEqual(appliedAppearanceName, .darkAqua)
    }

    func testDefaultsObserverAppliesLiveAppearanceWhenStoredModeChanges() {
        let suiteName = "AppearanceSettingsTests.DefaultsObserver.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let notificationCenter = NotificationCenter()
        var appliedAppearanceName: NSAppearance.Name?
        var synchronizedAppearanceName: NSAppearance.Name?
        var synchronizedSource: String?
        let liveEnvironment = AppearanceSettings.LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                appliedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                synchronizedAppearanceName = appearance?.bestMatch(from: [.darkAqua, .aqua])
                synchronizedSource = source
            },
            systemAppearance: {
                XCTFail("Dark mode should not resolve system appearance")
                return nil
            }
        )
        let observer = AppearanceSettingsUserDefaultsObserver(
            environment: .init(
                addDefaultsObserver: { handler in
                    notificationCenter.addObserver(
                        forName: UserDefaults.didChangeNotification,
                        object: nil,
                        queue: nil
                    ) { _ in
                        MainActor.assumeIsolated { handler() }
                    }
                },
                removeObserver: { observer in
                    notificationCenter.removeObserver(observer)
                },
                currentRawValue: {
                    defaults.string(forKey: AppearanceSettings.appearanceModeKey)
                },
                applyStoredMode: { rawValue, source in
                    AppearanceSettings.applyStoredMode(
                        rawValue: rawValue,
                        defaults: defaults,
                        source: source,
                        environment: liveEnvironment
                    )
                }
            ),
            source: "test.defaultsObserver"
        )

        defaults.set(AppearanceMode.system.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        observer.startObserving()
        defaults.set(AppearanceMode.dark.rawValue, forKey: AppearanceSettings.appearanceModeKey)
        notificationCenter.post(name: UserDefaults.didChangeNotification, object: defaults)

        XCTAssertEqual(appliedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedAppearanceName, .darkAqua)
        XCTAssertEqual(synchronizedSource, "test.defaultsObserver")
    }

    private func withTemporaryAppearanceDefaults(
        appearanceMode: String,
        appleInterfaceStyle: String?,
        body: () -> Void
    ) {
        let defaults = UserDefaults.standard
        let originalAppearanceMode = defaults.object(forKey: AppearanceSettings.appearanceModeKey)
        let originalAppleInterfaceStyle = defaults.object(forKey: "AppleInterfaceStyle")
        defer {
            restoreDefaultsValue(
                originalAppearanceMode,
                key: AppearanceSettings.appearanceModeKey,
                defaults: defaults
            )
            restoreDefaultsValue(
                originalAppleInterfaceStyle,
                key: "AppleInterfaceStyle",
                defaults: defaults
            )
        }

        defaults.set(appearanceMode, forKey: AppearanceSettings.appearanceModeKey)
        if let appleInterfaceStyle {
            defaults.set(appleInterfaceStyle, forKey: "AppleInterfaceStyle")
        } else {
            defaults.removeObject(forKey: "AppleInterfaceStyle")
        }
        body()
    }

    private func restoreDefaultsValue(_ value: Any?, key: String, defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

}
