public import AppKit
public import Foundation
public import SwiftUI

/// The one accent for cmux-drawn chrome: the color that means "this is the
/// active or attention-worthy thing" (selected workspace, attention ring,
/// pane swap source, canvas focus, scroll markers, agent status).
///
/// A value carries the resolved `app.accentColor` mode. ``CmuxAccentColorObserver``
/// resolves it once per change and hands it to the sidebar snapshot, the
/// SwiftUI environment (``SwiftUI/EnvironmentValues/cmuxAccentColor``) and
/// AppKit chrome, so drawing code never reads settings itself. Native
/// controls (toggles, pickers, text cursors, list selection) always keep the
/// system accent. User overrides such as the sidebar selection color or the
/// pane flash color are applied by their callers and win over both modes.
public struct CmuxAccentColor: Sendable, Hashable {
    /// Posted on the default center, with the ``CmuxAccentColorObserver`` as
    /// the object, when the resolved accent changes.
    public static let didChangeNotification = Notification.Name("cmux.accentColorDidChange")

    /// Hex the built-in agent hooks write for Running and Needs input. The
    /// sidebar draws entries carrying it with the accent instead.
    public static let builtInAgentStatusHex = "#4C8DFF"

    public let mode: CmuxAccentColorMode

    /// Normalized `#RRGGBB` color drawn in ``CmuxAccentColorMode/custom``
    /// mode. `nil` there falls back to cmux blue.
    public let customHex: String?

    public init(mode: CmuxAccentColorMode = .defaultValue) {
        self.init(mode: mode, customHex: nil)
    }

    public init(mode: CmuxAccentColorMode, customHex: String?) {
        self.mode = mode
        self.customHex = CmuxAccentColorMode.normalizedCustomHex(customHex)
    }

    /// The accent stored in `defaults` (`app.accentColor`).
    public static func stored(in defaults: UserDefaults = .standard) -> CmuxAccentColor {
        CmuxAccentColor(
            mode: .stored(in: defaults),
            customHex: CmuxAccentColorMode.storedCustomHex(in: defaults)
        )
    }

    /// Bree's accent is monochrome ivory (the dark palette's primary text colour).
    /// It is the same in every appearance and ignores the stored mode, so an old
    /// `app.accentColor` value in cmux.json or UserDefaults cannot bring blue back.
    public static let ivory = NSColor(srgbRed: 0xF5 / 255.0, green: 0xF4 / 255.0, blue: 0xEE / 255.0, alpha: 1)

    /// The accent for a light or dark appearance (always ``ivory``).
    public func nsColor(isDark: Bool) -> NSColor { Self.ivory }

    /// The accent for an AppKit appearance. `nil` resolves as light.
    public func nsColor(for appearance: NSAppearance?) -> NSColor {
        nsColor(isDark: appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    /// Appearance-aware accent that resolves against the drawing appearance,
    /// like a system dynamic color.
    public var dynamicNSColor: NSColor {
        let accent = self
        return NSColor(name: "cmuxAccent") { appearance in
            accent.nsColor(for: appearance)
        }
    }

    /// Minimum contrast between white and ``selectedFill(isDark:)``. Primary
    /// text is white (4.5:1 would do); the sidebar's secondary lines are white
    /// at 0.8 opacity, which clears 4.5:1 only when white itself has about 6.2.
    public static let selectedFillMinimumContrast: Double = 6.2

    /// The one "selected" fill for rows that carry text (sidebar row, Quick
    /// View segment, Settings sidebar). It is the accent darkened until white
    /// text on it reaches ``selectedFillMinimumContrast`` (WCAG AA for text
    /// under 18 pt, also for 80% white secondary lines). An accent that
    /// already passes is returned unchanged.
    public func selectedFill(isDark: Bool) -> NSColor {
        Self.selectedFill(darkening: nsColor(isDark: isDark))
    }

    /// The darkening rule behind ``selectedFill(isDark:)`` for any base color,
    /// so ``BreeChromePalette`` shares it with the sidebar.
    public static func selectedFill(darkening accent: NSColor) -> NSColor {
        let base = accent.usingColorSpace(.sRGB) ?? accent
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        base.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        var scale: CGFloat = 1
        while scale > 0.2 {
            let luminance = relativeLuminance(red: red * scale, green: green * scale, blue: blue * scale)
            if contrastRatio(1, luminance) >= selectedFillMinimumContrast { break }
            scale -= 0.01
        }
        return NSColor(srgbRed: red * scale, green: green * scale, blue: blue * scale, alpha: 1)
    }

    /// ``selectedFill(isDark:)`` as an appearance-aware SwiftUI color.
    public var selectedFillColor: Color {
        let accent = self
        return Color(nsColor: NSColor(name: "cmuxSelectedFill") { appearance in
            accent.selectedFill(isDark: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        })
    }

    /// WCAG contrast ratio between two relative luminances, in either order.
    static func contrastRatio(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    /// WCAG relative luminance of an sRGB color (components 0...1).
    static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func linear(_ component: CGFloat) -> CGFloat {
            component <= 0.03928 ? component / 12.92 : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// SwiftUI accent that follows the view's color scheme.
    public var color: Color {
        Color(nsColor: dynamicNSColor)
    }

    /// Color for a sidebar status entry's hex. The built-in agent status blue
    /// resolves to the accent; any other valid hex is used as written.
    public func statusEntryColor(hex: String?, isDark: Bool) -> NSColor? {
        guard let hex else { return nil }
        let trimmed = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare(Self.builtInAgentStatusHex) == .orderedSame {
            return nsColor(isDark: isDark)
        }
        return NSColor(hex: trimmed)
    }

    /// Identifies what the accent draws: the mode plus both scheme colors,
    /// so a `system` value changes when the macOS accent does.
    public var fingerprint: String {
        "\(mode.rawValue):\(nsColor(isDark: false).hexString()):\(nsColor(isDark: true).hexString())"
    }

    /// Two values are equal when they draw the same colors.
    public static func == (lhs: CmuxAccentColor, rhs: CmuxAccentColor) -> Bool {
        lhs.fingerprint == rhs.fingerprint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(fingerprint)
    }
}

private struct CmuxAccentColorEnvironmentKey: EnvironmentKey {
    static let defaultValue = CmuxAccentColor()
}

extension EnvironmentValues {
    /// The resolved cmux accent. Window roots inject the observer's value.
    public var cmuxAccentColor: CmuxAccentColor {
        get { self[CmuxAccentColorEnvironmentKey.self] }
        set { self[CmuxAccentColorEnvironmentKey.self] = newValue }
    }
}
