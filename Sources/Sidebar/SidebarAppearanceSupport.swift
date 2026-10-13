import AppKit
import BreeAppKitSupportUI
import BreeFoundation
import Foundation
import SwiftUI
import BreeSettings

enum SidebarMatchTerminalBackgroundSettings {
    static let userDefaultsKey = "sidebarMatchTerminalBackground"
    static let legacyAppliedSettingsFileDefaultKey = "bree.settingsFile.sidebarMatchTerminalBackground.appliedDefault.v1"
}

enum SidebarTabItemFontScale {
    static func scale(for sidebarFontSize: CGFloat) -> CGFloat {
        GhosttyConfig.clampedSidebarFontSize(sidebarFontSize)
            / GhosttyConfig.defaultSidebarFontSize
    }

    /// Base size `S` of the sidebar's type scale. An explicit
    /// `sidebar-font-size` (10-20) wins; `nil` means the key is not set in the
    /// config (see `GhosttyConfig.explicitSidebarFontSize`), so the sidebar
    /// follows the Interface Text Size.
    static func baseSize(sidebarFontSize: CGFloat?, interfaceTextSize: Int) -> CGFloat {
        if let sidebarFontSize {
            return GhosttyConfig.clampedSidebarFontSize(sidebarFontSize)
        }
        return CGFloat(InterfaceTextSize.clamp(interfaceTextSize))
    }

    /// Inverse of ``scale(for:)`` for views that only carry the scale.
    static func baseSize(forScale scale: CGFloat) -> CGFloat {
        scale * GhosttyConfig.defaultSidebarFontSize
    }

    /// Interface Text Size read from `defaults` (same storage rules as
    /// `InterfaceTextSize.stored`, but for an injected store).
    static func interfaceTextSize(in defaults: UserDefaults) -> Int {
        let raw = defaults.object(forKey: InterfaceTextSize.key)
        if let number = raw as? NSNumber { return InterfaceTextSize.clamp(number.intValue) }
        if let string = raw as? String, let parsed = Int(string) { return InterfaceTextSize.clamp(parsed) }
        return InterfaceTextSize.defaultSize
    }
}

/// Bree type roles resolved on a fractional base size, so the sidebar can
/// honour `sidebar-font-size` (10-20) which `BreeType.spec` (Int, 11-16)
/// cannot express. Mirrors `BreeType`: role offsets, a 10 pt floor and no
/// semibold below 11 pt.
enum SidebarRowType {
    struct Spec: Equatable {
        let size: CGFloat
        let weight: Font.Weight
        let isMonospaced: Bool
        let monospacedDigit: Bool
    }

    static func spec(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body,
        base: CGFloat,
        magnificationPercent: Int
    ) -> Spec {
        let sizingRole = (role == .count && countRow != .count) ? countRow : role
        let offset: CGFloat
        switch sizingRole {
        case .title, .body, .count: offset = 0
        case .tab, .secondary, .mono: offset = -1
        case .caption: offset = -2
        }
        let size = max(
            BreeType.minimumPointSize,
            GlobalFontMagnification.scaledSize(base, percent: magnificationPercent) + offset
        )
        var resolved = weight ?? ((role == .title || (role == .count && sizingRole == .title)) ? .medium : .regular)
        // Medium is the weight ceiling (Claude-style hierarchy: size and tone).
        if resolved == .semibold || resolved == .bold || resolved == .heavy || resolved == .black {
            resolved = .medium
        }
        return Spec(size: size, weight: resolved, isMonospaced: role == .mono, monospacedDigit: role == .count)
    }

    static func nsFont(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body,
        base: CGFloat,
        magnificationPercent: Int
    ) -> NSFont {
        let spec = spec(role, weight: weight, countRow: countRow, base: base, magnificationPercent: magnificationPercent)
        let nsWeight: NSFont.Weight
        switch spec.weight {
        case .ultraLight: nsWeight = .ultraLight
        case .thin: nsWeight = .thin
        case .light: nsWeight = .light
        case .medium: nsWeight = .medium
        case .semibold: nsWeight = .semibold
        case .bold: nsWeight = .bold
        case .heavy: nsWeight = .heavy
        case .black: nsWeight = .black
        default: nsWeight = .regular
        }
        if spec.isMonospaced { return NSFont.monospacedSystemFont(ofSize: spec.size, weight: nsWeight) }
        if spec.monospacedDigit { return NSFont.monospacedDigitSystemFont(ofSize: spec.size, weight: nsWeight) }
        return NSFont.systemFont(ofSize: spec.size, weight: nsWeight)
    }

    /// SwiftUI twin of ``nsFont(_:weight:countRow:base:magnificationPercent:)``.
    static func font(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body,
        base: CGFloat,
        magnificationPercent: Int
    ) -> Font {
        let spec = spec(role, weight: weight, countRow: countRow, base: base, magnificationPercent: magnificationPercent)
        var font = Font.system(size: spec.size, weight: spec.weight, design: spec.isMonospaced ? .monospaced : .default)
        if spec.monospacedDigit { font = font.monospacedDigit() }
        return font
    }
}

/// Resolves AppKit colors against bree's concrete terminal light/dark scheme.
///
/// AppKit semantic colors otherwise resolve against the window's effective
/// appearance, which can differ from the active bree theme. This value type is
/// shared by the SwiftUI and pure-AppKit sidebar paths so they never ask
/// AppKit to make an independent appearance decision.
struct SidebarAppearanceColorResolver {
    /// Returns the scheme selected by the shared terminal-theme authority.
    func currentColorScheme() -> ColorScheme {
        GhosttyApp.shared.effectiveTerminalColorSchemePreference == .dark ? .dark : .light
    }

    /// Resolves an AppKit semantic color against a concrete bree scheme.
    func resolvedColor(
        _ color: NSColor,
        for colorScheme: ColorScheme,
        opacity: CGFloat? = nil
    ) -> NSColor {
        let resolved = WindowAppearanceSnapshot.resolvedColor(color, for: colorScheme)
        guard let opacity else { return resolved }
        return resolved.withAlphaComponent(max(0, min(opacity, 1)))
    }

    /// Minimum WCAG contrast for secondary sidebar text and icons over a
    /// terminal-matched backdrop. The macOS secondary label on white is about
    /// 3.9:1, so neutral themes keep the system look and only saturated
    /// mid-tone themes are raised.
    static let secondaryMinimumContrast: CGFloat = 3.5

    /// Resolves a secondary semantic color and, when the sidebar draws over
    /// a known opaque `backdrop`, raises its opacity to the contrast floor.
    func readableSecondaryColor(
        _ color: NSColor,
        for colorScheme: ColorScheme,
        opacity: CGFloat? = nil,
        over backdrop: NSColor?
    ) -> NSColor {
        let resolved = resolvedColor(color, for: colorScheme, opacity: opacity)
        guard let backdrop else { return resolved }
        return WindowChromeColorResolver().contrastFloored(
            resolved,
            over: backdrop,
            minimumContrast: Self.secondaryMinimumContrast
        )
    }

    /// Returns the active-control foreground for a concrete bree scheme.
    func activeForegroundColor(
        opacity: CGFloat,
        for colorScheme: ColorScheme
    ) -> NSColor {
        let clampedOpacity = max(0, min(opacity, 1))
        let baseColor: NSColor = colorScheme == .dark ? .white : .black
        return baseColor.withAlphaComponent(clampedOpacity)
    }
}

extension Color {
    init?(hex: String) {
        let hex = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        guard hex.count == 6, let value = UInt64(hex, radix: 16) else { return nil }
        self.init(
            red:   Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8)  & 0xFF) / 255.0,
            blue:  Double( value        & 0xFF) / 255.0
        )
    }
}

func coloredCircleImage(color: NSColor) -> NSImage {
    let size = NSSize(width: 14, height: 14)
    let image = NSImage(size: size, flipped: false) { rect in
        color.setFill()
        NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
        return true
    }
    image.isTemplate = false
    return image
}

func sidebarActiveForegroundNSColor(
    opacity: CGFloat,
    appAppearance: NSAppearance? = nil
) -> NSColor {
    let colorScheme = appAppearance.map {
        $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? ColorScheme.dark : .light
    } ?? SidebarAppearanceColorResolver().currentColorScheme()
    return SidebarAppearanceColorResolver().activeForegroundColor(
        opacity: opacity,
        for: colorScheme
    )
}

/// The appearance titlebar controls draw over: the terminal backdrop.
@MainActor
func titlebarControlAppearance() -> WindowAppearanceSnapshot {
    let app = GhosttyApp.shared
    return WindowAppearanceResolver(
        terminalAppearance: WindowTerminalAppearanceSnapshot(
            backgroundColor: app.defaultBackgroundColor,
            backgroundOpacity: app.defaultBackgroundOpacity,
            backgroundBlur: app.defaultBackgroundBlur,
            usesHostLayerBackground: app.usesHostLayerBackground,
            resolvedColorScheme: app.effectiveTerminalColorSchemePreference == .dark ? .dark : .light
        )
    ).currentFromUserDefaults(
        defaults: .standard,
        colorScheme: AppearanceSettings.currentAmbientColorScheme()
    )
}

/// Light or dark for chrome drawn over the titlebar, the same choice that
/// colors the titlebar icons. Shortcut-hint pills there use it so their
/// palette matches the icons instead of the window appearance.
@MainActor
func titlebarControlColorScheme() -> ColorScheme {
    breeReadableColorScheme(for: titlebarControlAppearance().compositedTerminalBackgroundColor)
}

@MainActor
func titlebarControlForegroundNSColor(opacity: CGFloat) -> NSColor {
    titlebarControlForegroundNSColor(opacity: opacity, appearance: titlebarControlAppearance())
}

func titlebarControlForegroundNSColor(opacity: CGFloat, appearance: WindowAppearanceSnapshot) -> NSColor {
    breeReadableForegroundNSColor(
        on: appearance.compositedTerminalBackgroundColor,
        opacity: opacity
    )
}

extension BreeAccentColor {
    /// The accent for a SwiftUI color scheme.
    func nsColor(for colorScheme: ColorScheme) -> NSColor {
        nsColor(isDark: colorScheme == .dark)
    }

    /// The accent for the scheme chosen by the terminal-theme authority, for
    /// AppKit chrome that has no view appearance of its own to resolve with.
    var themeNSColor: NSColor {
        nsColor(for: SidebarAppearanceColorResolver().currentColorScheme())
    }
}

/// Fill for an unread notification badge: the Notification Badge color
/// setting when it holds a valid hex, else `fallback`. Workspace rows and
/// group headers both resolve through here so the setting reaches every badge.
func breeNotificationBadgeNSColor(hex: String?, fallback: @autoclosure () -> NSColor) -> NSColor {
    if let hex, let color = NSColor(hex: hex) {
        return color
    }
    return fallback()
}

func breeReadableColorScheme(for backgroundColor: NSColor) -> ColorScheme {
    let backgroundLuminance = breeRelativeLuminance(backgroundColor)
    let whiteContrast = breeContrastRatio(backgroundLuminance, 1.0)
    let blackContrast = breeContrastRatio(backgroundLuminance, 0.0)
    return whiteContrast >= blackContrast ? .dark : .light
}

func breeReadableForegroundNSColor(on backgroundColor: NSColor, opacity: CGFloat) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    return breeReadableForegroundBaseColor(on: backgroundColor)
        .withAlphaComponent(clampedOpacity)
}

func breeReadableForegroundNSColor(
    preferred preferredColor: NSColor,
    on backgroundColor: NSColor,
    minimumContrast: CGFloat = 4.5
) -> NSColor {
    let foregroundForComparison = preferredColor.alphaComponent < 1
        ? breeCompositedNSColor(preferredColor, over: backgroundColor)
        : preferredColor
    guard breeContrastRatio(foreground: foregroundForComparison, background: backgroundColor) < minimumContrast else {
        return preferredColor
    }
    return breeReadableForegroundNSColor(on: backgroundColor, opacity: preferredColor.alphaComponent)
}

func breeCompositedNSColor(_ foreground: NSColor, over background: NSColor) -> NSColor {
    let fg = foreground.usingColorSpace(.sRGB) ?? foreground
    let bg = background.usingColorSpace(.sRGB) ?? background
    var foregroundRed: CGFloat = 0
    var foregroundGreen: CGFloat = 0
    var foregroundBlue: CGFloat = 0
    var foregroundAlpha: CGFloat = 0
    var backgroundRed: CGFloat = 0
    var backgroundGreen: CGFloat = 0
    var backgroundBlue: CGFloat = 0
    var backgroundAlpha: CGFloat = 0
    fg.getRed(&foregroundRed, green: &foregroundGreen, blue: &foregroundBlue, alpha: &foregroundAlpha)
    bg.getRed(&backgroundRed, green: &backgroundGreen, blue: &backgroundBlue, alpha: &backgroundAlpha)
    _ = backgroundAlpha

    let alpha = max(0, min(foregroundAlpha, 1))
    return NSColor(
        srgbRed: foregroundRed * alpha + backgroundRed * (1 - alpha),
        green: foregroundGreen * alpha + backgroundGreen * (1 - alpha),
        blue: foregroundBlue * alpha + backgroundBlue * (1 - alpha),
        alpha: 1
    )
}

func breeContrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
    breeContrastRatio(
        breeRelativeLuminance(foreground),
        breeRelativeLuminance(background)
    )
}

private func breeReadableForegroundBaseColor(on backgroundColor: NSColor) -> NSColor {
    breeReadableColorScheme(for: backgroundColor) == .dark ? .white : .black
}

private func breeRelativeLuminance(_ color: NSColor) -> CGFloat {
    let srgb = color.usingColorSpace(.sRGB) ?? color
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    _ = alpha

    func linearized(_ component: CGFloat) -> CGFloat {
        component <= 0.03928
            ? component / 12.92
            : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
    }

    return 0.2126 * linearized(red)
        + 0.7152 * linearized(green)
        + 0.0722 * linearized(blue)
}

private func breeContrastRatio(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
    let lighter = max(lhs, rhs)
    let darker = min(lhs, rhs)
    return (lighter + 0.05) / (darker + 0.05)
}

struct SidebarRemoteErrorCopyEntry: Equatable {
    let workspaceTitle: String
    let target: String
    let detail: String
}

enum SidebarRemoteErrorCopySupport {
    static func menuLabel(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1 {
            return String(localized: "contextMenu.copyError", defaultValue: "Copy Error")
        }
        return String(localized: "contextMenu.copyErrors", defaultValue: "Copy Errors")
    }

    static func clipboardText(for entries: [SidebarRemoteErrorCopyEntry]) -> String? {
        guard !entries.isEmpty else { return nil }
        if entries.count == 1, let entry = entries.first {
            return String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.single", defaultValue: "SSH error (%@): %@"),
                entry.target,
                entry.detail
            )
        }

        return entries.enumerated().map { index, entry in
            String.localizedStringWithFormat(
                String(localized: "clipboard.sshError.item", defaultValue: "%lld. %@ (%@): %@"),
                Int64(index + 1),
                entry.workspaceTitle,
                entry.target,
                entry.detail
            )
        }.joined(separator: "\n")
    }
}

/// Selection treatment for the workspace sidebar. Selection is persistent
/// state, so it reads as a faint wash with a 1 pt hairline instead of a
/// saturated block: the user's accent while the window is active, and a
/// neutral wash and edge when it isn't, the way Finder dims an inactive
/// window's selection. Increase Contrast strengthens both. Picked from a
/// pairwise comparison of eight treatments across accents and sidebar themes
/// (ecyx00/bree#14890).
struct BreeSelectionFill: Equatable {
    let color: NSColor
    let edgeColor: NSColor?

    static func resolve(
        colorScheme: ColorScheme,
        isEmphasized: Bool,
        increaseContrast: Bool = false,
        isSecondary: Bool = false
    ) -> BreeSelectionFill {
        let isDark = colorScheme == .dark
        let base: NSColor
        let fillAlpha: CGFloat
        let edgeAlpha: CGFloat
        if isEmphasized {
            base = BreeAccentColor.ivory
            fillAlpha = increaseContrast ? 0.26 : (isDark ? 0.14 : 0.11)
            edgeAlpha = increaseContrast ? 0.95 : 0.60
        } else {
            base = .labelColor
            fillAlpha = isDark ? 0.08 : 0.06
            edgeAlpha = increaseContrast ? 0.45 : 0.20
        }
        // Secondary selections (multi-select members) sit at roughly half the
        // primary strength so the active row stays the clear anchor.
        let scale: CGFloat = isSecondary ? 0.55 : 1
        let resolver = SidebarAppearanceColorResolver()
        return BreeSelectionFill(
            color: resolver.resolvedColor(base, for: colorScheme, opacity: fillAlpha * scale),
            edgeColor: resolver.resolvedColor(base, for: colorScheme, opacity: edgeAlpha * scale)
        )
    }
}

/// Opaque color the selected workspace row reads as, used to choose readable
/// row foregrounds. A configured `sidebarSelectionColorHex`, the solid-fill
/// indicator style, and the default (non-subtle) selection paint a solid
/// fill; the opt-in subtle selection composites its tint over an approximate
/// sidebar surface for the scheme.
func sidebarSelectedWorkspaceBackgroundNSColor(
    for colorScheme: ColorScheme,
    sidebarSelectionColorHex: String? = UserDefaults.standard.string(forKey: "sidebarSelectionColorHex"),
    activeTabIndicatorStyle: WorkspaceIndicatorStyle = .leftRail,
    subtleSelection: Bool = false,
    isEmphasized: Bool = true,
    increaseContrast: Bool = false,
    accent: BreeAccentColor = BreeAccentColor()
) -> NSColor {
    if let hex = sidebarSelectionColorHex,
       let parsed = NSColor(hex: hex) {
        return parsed
    }
    if activeTabIndicatorStyle == .solidFill || !subtleSelection {
        return accent.selectedFill(isDark: colorScheme == .dark)
    }
    let surface = NSColor(white: colorScheme == .dark ? 0.16 : 0.93, alpha: 1)
    let fill = BreeSelectionFill.resolve(
        colorScheme: colorScheme,
        isEmphasized: isEmphasized,
        increaseContrast: increaseContrast
    )
    return breeCompositedNSColor(fill.color, over: surface)
}

func sidebarSelectedWorkspaceForegroundNSColor(opacity: CGFloat) -> NSColor {
    sidebarSelectedWorkspaceForegroundNSColor(
        on: sidebarSelectedWorkspaceBackgroundNSColor(for: .dark),
        opacity: opacity
    )
}

func sidebarSelectedWorkspaceForegroundNSColor(
    on backgroundColor: NSColor,
    opacity: CGFloat
) -> NSColor {
    let clampedOpacity = max(0, min(opacity, 1))
    let whiteContrast = breeContrastRatio(foreground: .white, background: backgroundColor)
    guard whiteContrast < 2.75 else {
        return NSColor.white.withAlphaComponent(clampedOpacity)
    }
    return breeReadableForegroundNSColor(on: backgroundColor, opacity: clampedOpacity)
}

/// Whether selected rows paint the subtle tint and hairline. Only the
/// left-rail indicator style uses it, and a configured selection color is an
/// explicit request for a solid fill.
func sidebarUsesSubtleSelection(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    subtleSelection: Bool,
    sidebarSelectionColorHex: String?
) -> Bool {
    subtleSelection
        && activeTabIndicatorStyle == .leftRail
        && sidebarSelectionColorHex.flatMap { NSColor(hex: $0) } == nil
}

/// Hairline for a group header whose anchor workspace is selected, so group
/// headers carry the same edge as selected workspace rows in subtle-selection
/// mode. The header keeps its neutral wash, so the edge is the neutral
/// selection edge. Nil when subtle selection is off.
func sidebarGroupHeaderAnchorActiveEdgeNSColor(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    subtleSelection: Bool,
    sidebarSelectionColorHex: String?,
    colorScheme: ColorScheme,
    increaseContrast: Bool
) -> NSColor? {
    guard sidebarUsesSubtleSelection(
        activeTabIndicatorStyle: activeTabIndicatorStyle,
        subtleSelection: subtleSelection,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    ) else { return nil }
    return BreeSelectionFill.resolve(
        colorScheme: colorScheme,
        isEmphasized: false,
        increaseContrast: increaseContrast
    ).edgeColor
}

struct SidebarWorkspaceRowBackgroundStyle: Equatable, Hashable {
    let color: NSColor?
    let opacity: Double
    var edgeColor: NSColor? = nil

    static let clear = Self(color: nil, opacity: 0)
}

func sidebarWorkspaceRowExplicitRailNSColor(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    customColorHex: String?,
    colorScheme: ColorScheme
) -> NSColor? {
    guard activeTabIndicatorStyle == .leftRail,
          let customColorHex else {
        return nil
    }
    return WorkspaceTabColorSettings.displayNSColor(
        hex: customColorHex,
        colorScheme: colorScheme,
        forceBright: true
    )
}

func sidebarWorkspaceRowBackgroundStyle(
    activeTabIndicatorStyle: WorkspaceIndicatorStyle,
    isActive: Bool,
    isMultiSelected: Bool,
    customColorHex: String?,
    colorScheme: ColorScheme,
    sidebarSelectionColorHex: String?,
    subtleSelection: Bool = false,
    isEmphasized: Bool = true,
    increaseContrast: Bool = false,
    accent: BreeAccentColor = BreeAccentColor()
) -> SidebarWorkspaceRowBackgroundStyle {
    // Increase Contrast: the multi-selection wash is otherwise too faint to
    // read against the sidebar material.
    let multiSelectionOpacity = increaseContrast ? 0.45 : 0.25
    let selectedBackground = sidebarSelectedWorkspaceBackgroundNSColor(
        for: colorScheme,
        sidebarSelectionColorHex: sidebarSelectionColorHex,
        activeTabIndicatorStyle: activeTabIndicatorStyle,
        subtleSelection: subtleSelection,
        isEmphasized: isEmphasized,
        increaseContrast: increaseContrast,
        accent: accent
    )
    let accentBackground = accent.nsColor(for: colorScheme)
    let usesSubtleSelection = sidebarUsesSubtleSelection(
        activeTabIndicatorStyle: activeTabIndicatorStyle,
        subtleSelection: subtleSelection,
        sidebarSelectionColorHex: sidebarSelectionColorHex
    )
    func calmFill(isSecondary: Bool) -> SidebarWorkspaceRowBackgroundStyle {
        let fill = BreeSelectionFill.resolve(
            colorScheme: colorScheme,
            isEmphasized: isEmphasized,
            increaseContrast: increaseContrast,
            isSecondary: isSecondary
        )
        return SidebarWorkspaceRowBackgroundStyle(color: fill.color, opacity: 1, edgeColor: fill.edgeColor)
    }
    let customBackground = customColorHex.flatMap {
        WorkspaceTabColorSettings.displayNSColor(
            hex: $0,
            colorScheme: colorScheme,
            forceBright: activeTabIndicatorStyle == .leftRail
        )
    }

    switch activeTabIndicatorStyle {
    case .leftRail:
        if isActive {
            if usesSubtleSelection { return calmFill(isSecondary: false) }
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if isMultiSelected {
            if usesSubtleSelection { return calmFill(isSecondary: true) }
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: multiSelectionOpacity)
        }
        return .clear

    case .solidFill:
        if isActive {
            return SidebarWorkspaceRowBackgroundStyle(
                color: selectedBackground,
                opacity: 1
            )
        }
        if let customBackground {
            return SidebarWorkspaceRowBackgroundStyle(
                color: customBackground,
                opacity: isMultiSelected ? 0.35 : 0.7
            )
        }
        if isMultiSelected {
            return SidebarWorkspaceRowBackgroundStyle(color: accentBackground, opacity: multiSelectionOpacity)
        }
        return .clear
    }
}

extension WorkspaceIndicatorStyle {
    /// Whether the active row gets its outline stroke. Solid-fill rows always
    /// draw it; with Increase Contrast every style does, so the selected row
    /// keeps an edge even when its fill is close to the sidebar background.
    func drawsActiveBorder(isActive: Bool, increaseContrast: Bool) -> Bool {
        isActive && (self == .solidFill || increaseContrast)
    }
}

private struct SidebarReadabilityBackdropKey: EnvironmentKey {
    static var defaultValue: NSColor? { nil }
}

extension EnvironmentValues {
    /// The opaque color sidebar content is drawn over when the sidebar
    /// matches the terminal background, or `nil` over its own material.
    var sidebarReadabilityBackdrop: NSColor? {
        get { self[SidebarReadabilityBackdropKey.self] }
        set { self[SidebarReadabilityBackdropKey.self] = newValue }
    }
}

extension SidebarAppearanceColorResolver {
    /// SwiftUI secondary color for sidebar chrome: `.secondary` over the
    /// sidebar material, floored for contrast over a terminal-matched
    /// backdrop.
    func readableSecondary(for colorScheme: ColorScheme, over backdrop: NSColor?) -> Color {
        guard let backdrop else { return .secondary }
        return Color(nsColor: readableSecondaryColor(.secondaryLabelColor, for: colorScheme, over: backdrop))
    }
}

/// Reads window activation for the subtle selection wash, which dims to
/// neutral when the window is inactive the way Finder's selection does.
/// Rows wrap only their selection background in this reader, and only while
/// the subtle selection paints them, so activation changes invalidate that
/// background instead of every sidebar row.
struct SidebarSelectionWindowActivationReader<Content: View>: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let content: (_ isEmphasized: Bool) -> Content

    init(@ViewBuilder content: @escaping (_ isEmphasized: Bool) -> Content) {
        self.content = content
    }

    var body: some View {
        content(controlActiveState != .inactive)
    }
}

extension SidebarRowType {
    /// Un-magnified point size of small row glyphs (`caption` role) for views
    /// that only carry the sidebar font scale; symbol views magnify themselves.
    static func glyphSize(fontScale: CGFloat) -> CGFloat {
        spec(.caption, base: SidebarTabItemFontScale.baseSize(forScale: fontScale), magnificationPercent: GlobalFontMagnification.defaultPercent).size
    }

    /// Un-magnified size of inline editing fields (`secondary` role).
    static func fieldSize(fontScale: CGFloat) -> CGFloat {
        spec(.secondary, base: SidebarTabItemFontScale.baseSize(forScale: fontScale), magnificationPercent: GlobalFontMagnification.defaultPercent).size
    }
}

/// SwiftUI twin of `SidebarRowType`: a Bree type role on the sidebar base
/// size (explicit `sidebar-font-size`, else the Interface Text Size), given
/// the sidebar font scale the legacy SwiftUI rows already carry.
struct SidebarRoleFontModifier: ViewModifier {
    @Environment(\.breeGlobalFontMagnificationPercent) private var percent
    let role: BreeTextRole
    let weight: Font.Weight?
    let countRow: BreeTextRole
    let fontScale: CGFloat

    func body(content: Content) -> some View {
        content.font(
            SidebarRowType.font(
                role,
                weight: weight,
                countRow: countRow,
                base: SidebarTabItemFontScale.baseSize(forScale: fontScale),
                magnificationPercent: percent
            )
        )
    }
}

extension View {
    func sidebarFont(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body,
        fontScale: CGFloat
    ) -> some View {
        modifier(SidebarRoleFontModifier(role: role, weight: weight, countRow: countRow, fontScale: fontScale))
    }
}
