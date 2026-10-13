import AppKit
import BreeFoundation
import SwiftUI

/// The resolved color shared by pane flashes and unread notification rings.
///
/// A configured color paints both. Without one, both use the ivory accent
/// (`BreeChromePalette.accentFill`): plain unread is not a call to act. A ring
/// for a pane that needs the user uses `needsYouNSColor` (the attention
/// signal). Both are captured at init so a theme change makes the value
/// unequal and the renderers repaint.
///
/// The setting store remains the only owner of the configured string. This
/// value validates one immutable snapshot before it reaches a renderer, so
/// AppKit layers and SwiftUI canvases never read ambient defaults or parse the
/// setting in their drawing loops.
struct WorkspaceAttentionColor: Hashable, Sendable {
    private let rgb: UInt32?
    /// The resolved bree accent used when no valid color is configured.
    private let accent: BreeAccentColor
    private let themeForegroundHex: String?
    private let attentionSignal: BreeRGBA
    private let unreadAccent: BreeRGBA
    private let focusRing: BreeRGBA
    private let useThemeForeground: Bool
    init(
        configuredHex: String?,
        accent: BreeAccentColor = BreeAccentColor(),
        themeForeground: NSColor? = nil,
        useThemeForeground: Bool = false
    ) {
        self.rgb = Self.strictRGB(configuredHex)
        self.accent = accent
        self.themeForegroundHex = themeForeground?.hexString()
        self.useThemeForeground = useThemeForeground
        let palette = BreeChromePalette.currentSnapshot
        self.attentionSignal = palette.rgba(.signalAttention)
        self.unreadAccent = palette.rgba(.accentFill)
        self.focusRing = palette.rgba(.focusRing)
    }

    var nsColor: NSColor {
        guard let rgb else {
            return unreadAccent.nsColor
        }
        return Self.color(rgb: rgb, alpha: 1)
    }

    /// Ring colour for a pane whose agent needs the user.
    var needsYouNSColor: NSColor { attentionSignal.nsColor }

    /// The pane flash keeps the configured color or the existing bree accent.
    var flashNSColor: NSColor {
        guard rgb == nil, useThemeForeground,
              let themeForegroundHex,
              let themeForeground = NSColor(hex: themeForegroundHex) else { return nsColor }
        return themeForeground
    }

    /// The flash for plain pane-focus navigation: a configured colour or the
    /// theme foreground still win, otherwise the palette focus ring.
    var navigationFlashNSColor: NSColor {
        guard rgb == nil, !(useThemeForeground && themeForegroundHex != nil) else { return flashNSColor }
        return focusRing.nsColor
    }

    private static func color(rgb: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }

    private static func strictRGB(_ raw: String?) -> UInt32? {
        guard let raw else { return nil }
        let bytes = raw.utf8
        guard bytes.count == 7,
              bytes.first == 0x23,
              bytes.dropFirst().allSatisfy(isASCIIHexDigit) else { return nil }
        return UInt32(raw.dropFirst(), radix: 16)
    }

    private static func isASCIIHexDigit(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30 ... 0x39, 0x41 ... 0x46, 0x61 ... 0x66:
            return true
        default:
            return false
        }
    }
}

extension EnvironmentValues {
    @Entry var workspaceAttentionColor = WorkspaceAttentionColor(configuredHex: nil)
}
