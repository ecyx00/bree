import AppKit
import Foundation
import Testing

@testable import CmuxFoundation

/// Contrast guards for ``BreeChromePalette``. The floors are re-checked here
/// with an independent WCAG formula, so a regression in the nudge cannot hide
/// behind the palette's own helpers. `scripts/bree-palette-contrast.py`
/// mirrors the math and prints the same table.
@Suite struct BreeChromePaletteTests {
    struct Theme: Sendable, CustomStringConvertible {
        let name: String
        let background: String
        let foreground: String
        let ansi: [String]
        var description: String { name }

        func inputs(increaseContrast: Bool) -> BreeChromePalette.Inputs {
            BreeChromePalette.Inputs(
                background: rgba(background),
                foreground: rgba(foreground),
                ansi: ansi.map(rgba),
                increaseContrast: increaseContrast
            )
        }
    }

    // Values from Resources/ghostty/themes (regenerate with
    // `python3 scripts/bree-palette-contrast.py --swift`).
    static let themes: [Theme] = [
        Theme(name: "iTerm2 Solarized Light", background: "#FDF6E3", foreground: "#657B83",
              ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#BBB5A2", "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]),
        Theme(name: "GitHub Light Default", background: "#FFFFFF", foreground: "#1F2328",
              ansi: ["#24292F", "#CF222E", "#116329", "#4D2D00", "#0969DA", "#8250DF", "#1B7C83", "#6E7781", "#57606A", "#A40E26", "#1A7F37", "#633C01", "#218BFF", "#A475F9", "#3192AA", "#8C959F"]),
        Theme(name: "TokyoNight", background: "#1A1B26", foreground: "#C0CAF5",
              ansi: ["#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6", "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5"]),
        Theme(name: "Dracula", background: "#282A36", foreground: "#F8F8F2",
              ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2", "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]),
        Theme(name: "Gruvbox Dark", background: "#282828", foreground: "#EBDBB2",
              ansi: ["#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984", "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2"]),
    ]

    private static func luminance(_ color: BreeRGBA) -> Double {
        func channel(_ value: Double) -> Double {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    private static func ratio(_ a: BreeRGBA, _ b: BreeRGBA) -> Double {
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    @Test(arguments: BreeChromePaletteTests.themes, [false, true])
    func everyFlooredRoleHoldsOnAllSurfaces(theme: Theme, increaseContrast: Bool) {
        let palette = BreeChromePalette(theme.inputs(increaseContrast: increaseContrast))
        for role in BreeChromePalette.Role.allCases {
            guard let floor = BreeChromePalette.contrastFloor(for: role, increaseContrast: increaseContrast) else {
                continue
            }
            let color = palette.rgba(role)
            if role == .accentFill {
                #expect(Self.ratio(color, palette.rgba(.surfaceBase)) >= floor, "\(theme.name) \(role) vs surfaceBase text")
                continue
            }
            for surface in BreeChromePalette.contrastSurfaces {
                let value = Self.ratio(color, palette.rgba(surface))
                #expect(value >= floor, "\(theme.name) ic=\(increaseContrast) \(role) on \(surface): \(value) < \(floor)")
            }
        }
    }

    @Test(arguments: BreeChromePaletteTests.themes)
    func surfacesAndFillsFollowTheSpec(theme: Theme) {
        let normal = BreeChromePalette(theme.inputs(increaseContrast: false))
        let boosted = BreeChromePalette(theme.inputs(increaseContrast: true))
        let background = rgba(theme.background)
        #expect(normal.rgba(.surfaceBase) == background)
        let foreground = rgba(theme.foreground)
        #expect(normal.rgba(.hoverFill) == foreground.withAlpha(0.08))
        #expect(normal.rgba(.pressedFill) == foreground.withAlpha(0.14))
        #expect(normal.rgba(.selectedQuiet) == foreground.withAlpha(0.07)
        )
        #expect(normal.rgba(.selectedFill) == foreground.withAlpha(0.11))
        #expect(boosted.rgba(.hoverFill) == foreground.withAlpha(0.16))
        #expect(boosted.rgba(.pressedFill) == foreground.withAlpha(0.28))
        // Surfaces step away from the base, toward the foreground (raised,
        // overlay) or darker (sunken).
        #expect(Self.luminance(normal.rgba(.surfaceSunken)) <= Self.luminance(background))
        #expect(normal.rgba(.surfaceRaised).contrast(with: foreground) <= background.contrast(with: foreground))
        #expect(normal.rgba(.surfaceOverlay).contrast(with: foreground) <= normal.rgba(.surfaceRaised).contrast(with: foreground))
    }

    @Test(arguments: BreeChromePaletteTests.themes)
    func accentIsMonochromeAndDerivedFromTheForeground(theme: Theme) {
        let palette = BreeChromePalette(theme.inputs(increaseContrast: false))
        let text = palette.rgba(.textPrimary)
        #expect(palette.rgba(.accentFill) == text)
        #expect(palette.rgba(.activeIndicator) == text)
        // Focus ring: B toward the accent at 55%, only nudged when it fails 3:1.
        let expected = palette.rgba(.surfaceBase).mixed(with: text, 0.55)
        let ring = palette.rgba(.focusRing)
        let worst = BreeChromePalette.contrastSurfaces.map { Self.ratio(expected, palette.rgba($0)) }.min() ?? 0
        if worst >= 3 { #expect(ring == expected) }
    }

    @Test(arguments: BreeChromePaletteTests.themes)
    func signalsKeepTheirHue(theme: Theme) {
        let palette = BreeChromePalette(theme.inputs(increaseContrast: false))
        for role in [BreeChromePalette.Role.signalAttention, .signalError, .signalSuccess, .signalInfo] {
            #expect(palette.rgba(role).chroma >= 0.10, "\(theme.name) \(role) is near grey")
        }
    }

    @Test func unchangedColorsPassThroughTheNudge() {
        // Solarized Light is a light theme: no warm tint, and its foreground is
        // nudged only if it fails 7:1, so textPrimary never moves away from F's hue.
        let theme = Self.themes[1]
        let palette = BreeChromePalette(theme.inputs(increaseContrast: false))
        #expect(palette.rgba(.textPrimary) == rgba(theme.foreground))
    }

    @Test func everySpecRoleExistsAndIsReadableAsBothColorTypes() {
        let palette = BreeChromePalette.fallback
        #expect(BreeChromePalette.Role.allCases.count == 21)
        for role in BreeChromePalette.Role.allCases {
            let ns = palette.nsColor(role).usingColorSpace(.sRGB)
            #expect(ns != nil)
            _ = palette.color(role)
        }
        #expect(palette.ns.focusRing == palette.nsColor(.focusRing))
    }

    @MainActor
    @Test func snapshotFollowsTheStoreAndIsReadableOffMain() async {
        let previous = BreeChromePaletteStore.shared.palette
        defer { BreeChromePaletteStore.shared.update(previous) }
        let next = BreeChromePalette(Self.themes[0].inputs(increaseContrast: false))
        BreeChromePaletteStore.shared.update(next)

        let offMain = await Task.detached { BreeChromePalette.currentSnapshot }.value
        #expect(offMain == next)
        #expect(BreeChromePalette.currentSnapshot == BreeChromePalette.current)
    }

}

private func bytes(_ color: BreeRGBA) -> [Int] {
    [color.red, color.green, color.blue].map { Int(($0 * 255).rounded()) }
}

private func rgba(_ hex: String) -> BreeRGBA {
    BreeRGBA(hex: hex) ?? BreeRGBA(red: 0, green: 0, blue: 0)
}
