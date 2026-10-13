import AppKit
import Foundation
import Testing

@testable import BreeFoundation

@Suite struct BreeAccentColorTests {
    @Test func everyModeDrawsIvory() {
        for mode in BreeAccentColorMode.allCases {
            let accent = BreeAccentColor(mode: mode, customHex: "#FF6A00")
            #expect(rgbBytes(accent.nsColor(isDark: false)) == [245, 244, 238])
            #expect(rgbBytes(accent.nsColor(isDark: true)) == [245, 244, 238])
        }
    }


    @Test func storedModeParsesAndFallsBackToSystem() throws {
        let suite = "BreeAccentColorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(BreeAccentColorMode.stored(in: defaults) == .system)
        for mode in BreeAccentColorMode.allCases {
            defaults.set(mode.rawValue, forKey: BreeAccentColorMode.userDefaultsKey)
            #expect(BreeAccentColorMode.stored(in: defaults) == mode)
        }
        defaults.set("purple", forKey: BreeAccentColorMode.userDefaultsKey)
        #expect(BreeAccentColorMode.stored(in: defaults) == .system)
    }

    @Test func storedCustomColorIsParsedButNotDrawn() throws {
        let suite = "BreeAccentColorTests.custom.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(BreeAccentColorMode.custom.rawValue, forKey: BreeAccentColorMode.userDefaultsKey)
        defaults.set(" ff6a00 ", forKey: BreeAccentColorMode.customHexUserDefaultsKey)
        let accent = BreeAccentColor.stored(in: defaults)
        #expect(accent.mode == .custom)
        #expect(accent.customHex == "#FF6A00")
        #expect(rgbBytes(accent.nsColor(isDark: true)) == [245, 244, 238])
    }

    @Test func invalidCustomColorIsDropped() {
        for hex in [nil, "", "not-a-color", "#FF6A00AA"] {
            #expect(BreeAccentColor(mode: .custom, customHex: hex).customHex == nil)
        }
    }

    @MainActor
    @Test func observerIgnoresCustomColorChangesBecauseTheAccentIsFixed() throws {
        let suite = "BreeAccentColorTests.customObserver.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(BreeAccentColorMode.custom.rawValue, forKey: BreeAccentColorMode.userDefaultsKey)
        defaults.set("#FF6A00", forKey: BreeAccentColorMode.customHexUserDefaultsKey)

        let observer = BreeAccentColorObserver(defaults: defaults, center: NotificationCenter())
        #expect(observer.current.customHex == "#FF6A00")
        defaults.set("#00FF00", forKey: BreeAccentColorMode.customHexUserDefaultsKey)
        // The drawn colour is always ivory, so a custom hex change is not a visible change.
        #expect(observer.refresh() == false)
    }

    @Test func settingsFileValueRoundTripsEveryMode() throws {
        #expect(BreeAccentColorMode.settingsFileValue(mode: .bree, customHex: "#FF6A00") == "bree")
        #expect(BreeAccentColorMode.settingsFileValue(mode: .system, customHex: nil) == "system")
        #expect(BreeAccentColorMode.settingsFileValue(mode: .custom, customHex: "ff6a00") == "#FF6A00")
        #expect(BreeAccentColorMode.settingsFileValue(mode: .custom, customHex: nil) == nil)

        for (mode, hex) in [(BreeAccentColorMode.bree, nil), (.system, nil), (.custom, "#FF6A00")] as [(BreeAccentColorMode, String?)] {
            let value = try #require(BreeAccentColorMode.settingsFileValue(mode: mode, customHex: hex))
            let parsed = try #require(BreeAccentColorMode.parseSettingsFileValue(value))
            #expect(parsed.mode == mode)
            #expect(parsed.customHex == hex)
        }
        for invalid in ["custom", "purple", "#FF6A", "#FF6A00AA", ""] {
            #expect(BreeAccentColorMode.parseSettingsFileValue(invalid) == nil)
        }
    }

    @Test func appearanceResolvesToMatchingScheme() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        for accent in BreeAccentColorMode.allCases.map(BreeAccentColor.init(mode:)) {
            #expect(rgbBytes(accent.nsColor(for: dark)) == rgbBytes(accent.nsColor(isDark: true)))
            #expect(rgbBytes(accent.nsColor(for: aqua)) == rgbBytes(accent.nsColor(isDark: false)))
            #expect(rgbBytes(accent.nsColor(for: nil)) == rgbBytes(accent.nsColor(isDark: false)))
        }
    }

    @Test func dynamicColorFollowsDrawingAppearance() throws {
        let dark = try #require(NSAppearance(named: .darkAqua))
        let aqua = try #require(NSAppearance(named: .aqua))
        let accent = BreeAccentColor(mode: .bree)
        var darkBytes: [Int] = []
        var lightBytes: [Int] = []
        dark.performAsCurrentDrawingAppearance {
            darkBytes = rgbBytes(accent.dynamicNSColor)
        }
        aqua.performAsCurrentDrawingAppearance {
            lightBytes = rgbBytes(accent.dynamicNSColor)
        }
        #expect(darkBytes == [245, 244, 238])
        #expect(lightBytes == [245, 244, 238])
    }

    @Test func builtInAgentStatusBlueResolvesToTheAccent() {
        for accent in BreeAccentColorMode.allCases.map(BreeAccentColor.init(mode:)) {
            for hex in ["#4C8DFF", "#4c8dff", " #4C8DFF "] {
                let color = accent.statusEntryColor(hex: hex, isDark: true)
                #expect(color.map(rgbBytes) == rgbBytes(accent.nsColor(isDark: true)))
            }
        }
    }

    @Test func otherStatusColorsStayAsWritten() {
        let accent = BreeAccentColor(mode: .system)
        #expect(accent.statusEntryColor(hex: "#00FF00", isDark: false).map(rgbBytes) == [0, 255, 0])
        #expect(accent.statusEntryColor(hex: nil, isDark: false) == nil)
        #expect(accent.statusEntryColor(hex: "not-a-color", isDark: false) == nil)
    }

    @MainActor
    @Test func observerResolvesOnceAndPostsOnlyOnChange() throws {
        let suite = "BreeAccentColorTests.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let center = NotificationCenter()
        var posts = 0
        let token = center.addObserver(forName: BreeAccentColor.didChangeNotification, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { center.removeObserver(token) }

        let observer = BreeAccentColorObserver(defaults: defaults, center: center)
        #expect(observer.current.mode == .system)
        #expect(observer.refresh() == false)

        defaults.set(BreeAccentColorMode.bree.rawValue, forKey: BreeAccentColorMode.userDefaultsKey)
        #expect(observer.current.mode == .system)
        #expect(observer.refresh() == true)
        #expect(observer.current.mode == .bree)
        #expect(observer.refresh() == false)

        defaults.set(BreeAccentColorMode.system.rawValue, forKey: BreeAccentColorMode.userDefaultsKey)
        #expect(observer.refresh() == true)
        #expect(posts == 2)
    }

    private func rgbBytes(_ color: NSColor) -> [Int] {
        guard let srgb = color.usingColorSpace(.sRGB) else { return [] }
        return [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()) }
    }
}
