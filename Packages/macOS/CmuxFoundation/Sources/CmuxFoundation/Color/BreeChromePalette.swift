public import AppKit
public import SwiftUI

/// An sRGB color with alpha, stored as plain numbers so the palette stays a
/// pure, `Sendable`, comparable value. Components are 0...1.
public struct BreeRGBA: Sendable, Hashable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// Reads an `NSColor` in sRGB. Resolve dynamic colors for the right
    /// appearance before calling this.
    public init(nsColor: NSColor) {
        let srgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        srgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Double(r), green: Double(g), blue: Double(b), alpha: Double(a))
    }

    /// `#RRGGBB` (the leading `#` is optional).
    public init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    public var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }

    public var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }

    public func withAlpha(_ alpha: Double) -> BreeRGBA {
        BreeRGBA(red: red, green: green, blue: blue, alpha: alpha)
    }

    /// WCAG relative luminance (alpha ignored).
    public var luminance: Double {
        Double(CmuxAccentColor.relativeLuminance(red: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue)))
    }

    /// WCAG contrast ratio against another opaque color.
    public func contrast(with other: BreeRGBA) -> Double {
        Double(CmuxAccentColor.contrastRatio(CGFloat(luminance), CGFloat(other.luminance)))
    }

    /// Max minus min channel: 0 for greys.
    var chroma: Double { max(red, green, blue) - min(red, green, blue) }

    static let white = BreeRGBA(red: 1, green: 1, blue: 1)
    static let black = BreeRGBA(red: 0, green: 0, blue: 0)

    /// Blend in gamma-encoded sRGB: `0` is `self`, `1` is `other`. The result
    /// is opaque. This matches how AppKit composites the alpha fills (hover,
    /// selection) and keeps surface steps small on dark themes, where a linear
    /// blend turns a 7% mix toward white into a mid grey.
    public func mixed(with other: BreeRGBA, _ amount: Double) -> BreeRGBA {
        func blend(_ a: Double, _ b: Double) -> Double {
            min(1, max(0, a + (b - a) * amount))
        }
        return BreeRGBA(red: blend(red, other.red), green: blend(green, other.green), blue: blend(blue, other.blue))
    }

    /// Moves each channel toward the colour's own grey (Rec. 709 luma) by
    /// `amount`, which lowers saturation and keeps perceived lightness.
    func desaturated(by amount: Double) -> BreeRGBA {
        let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue
        return mixed(with: BreeRGBA(red: luma, green: luma, blue: luma), amount)
    }

    /// HSL lightness minus `amount` (0...1), hue and saturation kept.
    func darkened(by amount: Double) -> BreeRGBA {
        let maxC = max(red, green, blue), minC = min(red, green, blue)
        let lightness = (maxC + minC) / 2
        let delta = maxC - minC
        var hue = 0.0, saturation = 0.0
        if delta > 0 {
            saturation = delta / (1 - abs(2 * lightness - 1))
            if maxC == red {
                hue = (green - blue) / delta + (green < blue ? 6 : 0)
            } else if maxC == green {
                hue = (blue - red) / delta + 2
            } else {
                hue = (red - green) / delta + 4
            }
        }
        let newLightness = min(1, max(0, lightness - amount))
        let chroma = (1 - abs(2 * newLightness - 1)) * saturation
        let x = chroma * (1 - abs(hue.truncatingRemainder(dividingBy: 2) - 1))
        let m = newLightness - chroma / 2
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<1: (r, g, b) = (chroma, x, 0)
        case ..<2: (r, g, b) = (x, chroma, 0)
        case ..<3: (r, g, b) = (0, chroma, x)
        case ..<4: (r, g, b) = (0, x, chroma)
        case ..<5: (r, g, b) = (x, 0, chroma)
        default: (r, g, b) = (chroma, 0, x)
        }
        return BreeRGBA(red: r + m, green: g + m, blue: b + m)
    }
}

/// Every Bree chrome surface, text tone and signal colour, derived from one
/// terminal theme. This is the single source phase-2 views read through
/// `@Environment(\.breePalette)` (SwiftUI) or ``BreeChromePalette/current``
/// (AppKit).
///
/// Mixing happens in gamma-encoded sRGB. Text, border, glyph, accent and signal
/// roles carry a WCAG floor against the worst of the four surfaces (base,
/// sunken, raised, overlay). A role that fails its floor is mixed toward
/// white or black (whichever gives more contrast) in 2% steps until it
/// passes, keeping its hue. If even pure white or black cannot reach the
/// floor (a mid-grey background), the role ends at the extreme with the best
/// contrast.
///
/// The type is pure: it never reads the theme, the system accent or the
/// accessibility settings itself.
public struct BreeChromePalette: Sendable, Hashable {
    /// The theme and system values the palette is computed from.
    public struct Inputs: Sendable, Hashable {
        public var background: BreeRGBA
        public var foreground: BreeRGBA
        /// ANSI colours 0...15. Missing entries fall back to `foreground`.
        public var ansi: [BreeRGBA]
        public var increaseContrast: Bool

        public init(
            background: BreeRGBA,
            foreground: BreeRGBA,
            ansi: [BreeRGBA],
            increaseContrast: Bool
        ) {
            self.background = background
            self.foreground = foreground
            self.ansi = ansi
            self.increaseContrast = increaseContrast
        }
    }

    /// The roles of the design spec, with exactly these names.
    public enum Role: String, CaseIterable, Sendable, Hashable {
        case surfaceBase, surfaceSunken, surfaceRaised, surfaceOverlay
        case separator, borderStrong
        case textPrimary, textSecondary, glyphTertiary
        case hoverFill, pressedFill, selectedFill, selectedQuiet, selectedBorder, accentFill
        case focusRing, activeIndicator
        case signalAttention, signalError, signalSuccess, signalInfo
    }

    public let inputs: Inputs
    private let values: [Role: BreeRGBA]

    /// The four surfaces text and indicators sit on.
    public static let contrastSurfaces: [Role] = [.surfaceBase, .surfaceSunken, .surfaceRaised, .surfaceOverlay]

    /// Minimum contrast of `role` against every surface in
    /// ``contrastSurfaces`` (for ``Role/accentFill``: against surfaceBase text).
    /// `nil` for roles without a floor.
    public static func contrastFloor(for role: Role, increaseContrast: Bool) -> Double? {
        switch role {
        case .textPrimary: 7
        case .textSecondary: increaseContrast ? 7 : 4.5
        case .glyphTertiary, .borderStrong, .focusRing, .activeIndicator: increaseContrast ? 4.5 : 3
        case .signalAttention, .signalError, .signalSuccess, .signalInfo: 4.5
        case .accentFill: 4.5  // surfaceBase text on the fill
        default: nil
        }
    }

    public init(_ inputs: Inputs) {
        self.inputs = inputs
        let background = inputs.background.withAlpha(1)
        let foreground = inputs.foreground.withAlpha(1)
        let boost = inputs.increaseContrast
        // Claude-style warmth: on a dark theme, derived surfaces and text lean
        // slightly yellow-brown (ivory text, warm greys). The base surface stays
        // the terminal's own colour. Light themes are left untouched.
        let isDark = background.luminance < 0.179
        let warmBackground = isDark ? background.mixed(with: Self.warmDark, 0.3) : background
        let warmForeground = isDark ? foreground.mixed(with: Self.ivory, 0.4) : foreground
        let hint = { (amount: Double) in warmBackground.mixed(with: warmForeground, amount) }

        let base = background
        let sunken = warmBackground.darkened(by: 0.03)
        let raised = hint(0.04)
        let overlay = hint(0.07)
        let surfaces = [base, sunken, raised, overlay]

        func floored(_ color: BreeRGBA, _ role: Role) -> BreeRGBA {
            Self.nudged(color, on: surfaces, floor: Self.contrastFloor(for: role, increaseContrast: boost) ?? 0)
        }

        func signal(_ index: Int, _ role: Role) -> BreeRGBA {
            let floor = Self.contrastFloor(for: role, increaseContrast: boost) ?? 0
            func ansi(_ i: Int) -> BreeRGBA { (i < inputs.ansi.count ? inputs.ansi[i] : foreground).withAlpha(1) }
            func worst(_ c: BreeRGBA) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 0 }
            let normal = ansi(index), bright = ansi(index + 8)
            // Lightness-nudge both candidates to the floor and keep the more saturated
            // result, so the signal keeps its hue (a theme's bright slot can be grey,
            // and nudging a dull colour washes it out).
            // Signals are softened (20% toward grey) before the floor nudge.
            let a = Self.nudgedKeepingHue(normal.desaturated(by: 0.2), on: surfaces, floor: floor)
            let b = Self.nudgedKeepingHue(bright.desaturated(by: 0.2), on: surfaces, floor: floor)
            return b.chroma > a.chroma ? b : a
        }

        let fillBoost = boost ? 2.0 : 1.0
        var values: [Role: BreeRGBA] = [:]
        values[.surfaceBase] = base
        values[.surfaceSunken] = sunken
        values[.surfaceRaised] = raised
        values[.surfaceOverlay] = overlay
        values[.separator] = hint(isDark ? 0.07 : 0.12)
        values[.borderStrong] = floored(hint(0.35), .borderStrong)
        values[.textPrimary] = floored(warmForeground, .textPrimary)
        values[.textSecondary] = floored(hint(isDark ? 0.65 : 0.72), .textSecondary)
        values[.glyphTertiary] = floored(hint(isDark ? 0.4 : 0.5), .glyphTertiary)
        values[.hoverFill] = foreground.withAlpha(0.08 * fillBoost)
        values[.pressedFill] = foreground.withAlpha(0.14 * fillBoost)
        // Selection is a quiet neutral wash plus a hairline, never the accent.
        values[.selectedFill] = foreground.withAlpha(0.11 * fillBoost)
        values[.selectedQuiet] = foreground.withAlpha(0.07 * fillBoost)
        values[.selectedBorder] = foreground.withAlpha(0.16 * fillBoost)
        // Monochrome accent: the primary text colour (ivory on dark, near-black on
        // light). No hue, so colour in the chrome stays reserved for the signals.
        let accent = values[.textPrimary] ?? foreground
        values[.accentFill] = accent  // primary buttons, badges; text on it is surfaceBase
        values[.focusRing] = floored(base.mixed(with: accent, 0.55), .focusRing)
        values[.activeIndicator] = accent
        values[.signalAttention] = signal(3, .signalAttention)
        values[.signalError] = signal(1, .signalError)
        values[.signalSuccess] = signal(2, .signalSuccess)
        values[.signalInfo] = signal(4, .signalInfo)
        self.values = values
    }

    private static let ivory = BreeRGBA(red: 0xF5 / 255, green: 0xF4 / 255, blue: 0xEE / 255)
    private static let warmDark = BreeRGBA(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1D / 255)

    /// Mixes `color` toward white or black until it reaches `floor` against
    /// every surface. Returns it unchanged when it already does.
    private static func nudged(_ color: BreeRGBA, on surfaces: [BreeRGBA], floor: Double) -> BreeRGBA {
        func worst(_ c: BreeRGBA) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 0 }
        if worst(color) >= floor { return color }
        let target = worst(.white) >= worst(.black) ? BreeRGBA.white : BreeRGBA.black
        for step in 1...50 {
            let candidate = color.mixed(with: target, Double(step) * 0.02)
            if worst(candidate) >= floor { return candidate }
        }
        return target
    }

    /// Like ``nudged(_:on:floor:)`` but shifts HSL lightness in 1% steps, which
    /// keeps hue and saturation (mixing toward white or black washes colour out).
    /// Used for signals. Falls back to the plain nudge if the extreme is reached.
    private static func nudgedKeepingHue(_ color: BreeRGBA, on surfaces: [BreeRGBA], floor: Double) -> BreeRGBA {
        func worst(_ c: BreeRGBA) -> Double { surfaces.map { c.contrast(with: $0) }.min() ?? 0 }
        if worst(color) >= floor { return color }
        let direction = worst(.white) >= worst(.black) ? -1.0 : 1.0  // darkened(by:) subtracts
        for step in 1...100 {
            let candidate = color.darkened(by: direction * Double(step) * 0.01)
            if worst(candidate) >= floor { return candidate }
        }
        return nudged(color, on: surfaces, floor: floor)
    }

    // MARK: Reading roles

    public func rgba(_ role: Role) -> BreeRGBA { values[role] ?? inputs.foreground }
    public func color(_ role: Role) -> Color { rgba(role).color }
    public func nsColor(_ role: Role) -> NSColor { rgba(role).nsColor }

    /// Contrast of `role` against its worst surface (surfaceBase text for
    /// ``Role/accentFill``), or `nil` when the role has no floor.
    public func worstContrast(of role: Role) -> Double? {
        guard Self.contrastFloor(for: role, increaseContrast: inputs.increaseContrast) != nil else { return nil }
        if role == .accentFill { return rgba(role).contrast(with: rgba(.surfaceBase)) }
        return Self.contrastSurfaces.map { rgba(role).contrast(with: rgba($0)) }.min()
    }

    public var surfaceBase: Color { color(.surfaceBase) }
    public var surfaceSunken: Color { color(.surfaceSunken) }
    public var surfaceRaised: Color { color(.surfaceRaised) }
    public var surfaceOverlay: Color { color(.surfaceOverlay) }
    public var separator: Color { color(.separator) }
    public var borderStrong: Color { color(.borderStrong) }
    public var textPrimary: Color { color(.textPrimary) }
    public var textSecondary: Color { color(.textSecondary) }
    public var glyphTertiary: Color { color(.glyphTertiary) }
    public var hoverFill: Color { color(.hoverFill) }
    public var pressedFill: Color { color(.pressedFill) }
    public var selectedFill: Color { color(.selectedFill) }
    public var selectedQuiet: Color { color(.selectedQuiet) }
    public var selectedBorder: Color { color(.selectedBorder) }
    public var accentFill: Color { color(.accentFill) }
    public var focusRing: Color { color(.focusRing) }
    public var activeIndicator: Color { color(.activeIndicator) }
    public var signalAttention: Color { color(.signalAttention) }
    public var signalError: Color { color(.signalError) }
    public var signalSuccess: Color { color(.signalSuccess) }
    public var signalInfo: Color { color(.signalInfo) }

    /// The same roles as `NSColor`, for AppKit drawing: `palette.ns.separator`.
    public var ns: AppKitColors { AppKitColors(palette: self) }

    public struct AppKitColors: Sendable {
        let palette: BreeChromePalette
        public var surfaceBase: NSColor { palette.nsColor(.surfaceBase) }
        public var surfaceSunken: NSColor { palette.nsColor(.surfaceSunken) }
        public var surfaceRaised: NSColor { palette.nsColor(.surfaceRaised) }
        public var surfaceOverlay: NSColor { palette.nsColor(.surfaceOverlay) }
        public var separator: NSColor { palette.nsColor(.separator) }
        public var borderStrong: NSColor { palette.nsColor(.borderStrong) }
        public var textPrimary: NSColor { palette.nsColor(.textPrimary) }
        public var textSecondary: NSColor { palette.nsColor(.textSecondary) }
        public var glyphTertiary: NSColor { palette.nsColor(.glyphTertiary) }
        public var hoverFill: NSColor { palette.nsColor(.hoverFill) }
        public var pressedFill: NSColor { palette.nsColor(.pressedFill) }
        public var selectedFill: NSColor { palette.nsColor(.selectedFill) }
        public var selectedQuiet: NSColor { palette.nsColor(.selectedQuiet) }
        public var selectedBorder: NSColor { palette.nsColor(.selectedBorder) }
        public var accentFill: NSColor { palette.nsColor(.accentFill) }
        public var focusRing: NSColor { palette.nsColor(.focusRing) }
        public var activeIndicator: NSColor { palette.nsColor(.activeIndicator) }
        public var signalAttention: NSColor { palette.nsColor(.signalAttention) }
        public var signalError: NSColor { palette.nsColor(.signalError) }
        public var signalSuccess: NSColor { palette.nsColor(.signalSuccess) }
        public var signalInfo: NSColor { palette.nsColor(.signalInfo) }
    }

    /// Dark neutral palette used before the app provider has published one.
    public static let fallback: BreeChromePalette = {
        let ansiHex = [
            "#1D1F21", "#CC6666", "#B5BD68", "#F0C674", "#81A2BE", "#B294BB", "#8ABEB7", "#C5C8C6",
            "#969896", "#D54E53", "#B9CA4A", "#E7C547", "#7AA6DA", "#C397D8", "#70C0B1", "#EAEAEA",
        ]
        return BreeChromePalette(
            Inputs(
                background: BreeRGBA(hex: "#1E1E1E") ?? .black,
                foreground: BreeRGBA(hex: "#D4D4D4") ?? .white,
                ansi: ansiHex.compactMap { BreeRGBA(hex: $0) },
                increaseContrast: false
            )
        )
    }()
}

private struct BreePaletteEnvironmentKey: EnvironmentKey {
    static let defaultValue = BreeChromePalette.fallback
}

extension EnvironmentValues {
    /// The live Bree chrome palette. Window roots inject it through
    /// ``SwiftUI/View/breePaletteEnvironment()``.
    public var breePalette: BreeChromePalette {
        get { self[BreePaletteEnvironmentKey.self] }
        set { self[BreePaletteEnvironmentKey.self] = newValue }
    }
}
