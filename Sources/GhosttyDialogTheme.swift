import AppKit
import BreeFoundation
import SwiftUI

/// Colors for in-app dialogs and cards drawn over terminal content. They use
/// the Ghostty theme's background and foreground, so a dark terminal theme on a
/// light macOS appearance (or the reverse) still gets a matching dialog.
struct GhosttyDialogTheme: Equatable {
    /// Opaque terminal background. Translucent terminals keep readable dialogs.
    let background: NSColor
    /// Terminal foreground, adjusted only when it is unreadable on `background`.
    let foreground: NSColor
    /// The scheme system controls (buttons, progress, dynamic colors) resolve in.
    let colorScheme: ColorScheme

    var secondaryForeground: NSColor { foreground.withAlphaComponent(0.65) }
    var border: NSColor { foreground.withAlphaComponent(0.2) }
    var separator: NSColor { foreground.withAlphaComponent(0.12) }

    static func resolved(background: NSColor, foreground: NSColor) -> GhosttyDialogTheme {
        let opaqueBackground = (background.usingColorSpace(.sRGB) ?? background).withAlphaComponent(1)
        let opaqueForeground = (foreground.usingColorSpace(.sRGB) ?? foreground).withAlphaComponent(1)
        return GhosttyDialogTheme(
            background: opaqueBackground,
            foreground: breeReadableForegroundNSColor(preferred: opaqueForeground, on: opaqueBackground),
            colorScheme: breeReadableColorScheme(for: opaqueBackground)
        )
    }

    /// Dialogs are `surfaceOverlay` cards with `textPrimary` text, like every
    /// other overlay; the palette already follows the terminal theme.
    static func current() -> GhosttyDialogTheme {
        let colors = BreeChromePalette.currentSnapshot.ns
        return resolved(background: colors.surfaceOverlay, foreground: colors.textPrimary)
    }
}

/// Publishes the current ``GhosttyDialogTheme`` and refreshes it when the
/// Ghostty default appearance changes, so every themed dialog shares one
/// observer instead of each view subscribing to notifications.
@MainActor
@Observable
final class GhosttyDialogThemeObserver {
    static let shared = GhosttyDialogThemeObserver()

    private(set) var theme: GhosttyDialogTheme
    @ObservationIgnored
    private var observers: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        theme = .current()
        for name in [Notification.Name.ghosttyDefaultBackgroundDidChange, .ghosttyConfigDidReload, BreeChromePaletteStore.didChangeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
    }

    func refresh() {
        let next = GhosttyDialogTheme.current()
        if next != theme { theme = next }
    }
}

private struct GhosttyDialogThemeModifier: ViewModifier {
    @State private var observer = GhosttyDialogThemeObserver.shared

    func body(content: Content) -> some View {
        let theme = observer.theme
        content
            .environment(\.colorScheme, theme.colorScheme)
            .foregroundStyle(Color(nsColor: theme.foreground))
    }
}

private struct GhosttyDialogSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @State private var observer = GhosttyDialogThemeObserver.shared

    func body(content: Content) -> some View {
        let theme = observer.theme
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(Color(nsColor: theme.background), in: shape)
            .overlay(shape.strokeBorder(Color(nsColor: BreeChromePalette.currentSnapshot.ns.separator), lineWidth: 1))
            .ghosttyDialogTheme()
    }
}

extension View {
    /// Resolves this dialog subtree against the Ghostty theme: its color scheme
    /// and default text color. Hierarchical styles such as `.secondary` derive
    /// from the theme foreground.
    func ghosttyDialogTheme() -> some View {
        modifier(GhosttyDialogThemeModifier())
    }

    /// Draws a themed dialog panel: Ghostty background, a foreground-tinted
    /// border, and ``ghosttyDialogTheme()`` for the content.
    func ghosttyDialogSurface(cornerRadius: CGFloat) -> some View {
        modifier(GhosttyDialogSurfaceModifier(cornerRadius: cornerRadius))
    }
}
