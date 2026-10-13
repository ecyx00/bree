import AppKit
import BreeAppKitSupportUI
import BreeFoundation
import BreeTerminalCore

/// Computes the live ``BreeChromePalette`` from the Ghostty theme and the
/// system, and publishes it to ``BreeChromePaletteStore``.
///
/// It recomputes on the notifications the app already posts: Ghostty default
/// appearance and config reload, system appearance, Increase Contrast, the
/// and the "match terminal background" setting. There is no
/// polling. Call ``start()`` once at launch.
///
/// With `sidebarMatchTerminalBackground` off, the palette is built from
/// `windowBackgroundColor` and `labelColor`; the ANSI signals still come from
/// the theme and are lightness-nudged against those surfaces.
@MainActor
final class BreeChromePaletteProvider {
    static let shared = BreeChromePaletteProvider()

    private let defaults: UserDefaults
    private var tokens: [(center: NotificationCenter, token: any NSObjectProtocol)] = []
    private var matchObservation: NSKeyValueObservation?
    private var appearanceObservation: NSKeyValueObservation?
    private var started = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func start() {
        guard !started else { return }
        started = true
        let local = NotificationCenter.default
        for name in [
            Notification.Name.ghosttyDefaultBackgroundDidChange,
            .ghosttyConfigDidReload,
            .systemAppearanceDidChange,
        ] {
            observe(name, on: local)
        }
        observe(DisplayAccessibilityOptions.didChangeNotification, on: NSWorkspace.shared.notificationCenter)
        matchObservation = defaults.observe(\.sidebarMatchTerminalBackground, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        // Match-off colours are dynamic system colors, so an app appearance
        // override (not only the OS switch) must recompute them.
        appearanceObservation = NSApp?.observe(\.effectiveAppearance, options: []) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        refresh()
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        tokens.append((center, token))
    }

    func refresh() {
        BreeChromePaletteStore.shared.update(BreeChromePalette(currentInputs()))
    }

    private func currentInputs() -> BreeChromePalette.Inputs {
        let app = GhosttyApp.shared
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        // Default is on (SidebarAppearanceCatalogSection.matchTerminalBackground).
        let matchesTerminal = defaults.object(forKey: Self.matchTerminalBackgroundKey) as? Bool ?? true

        var background = BreeRGBA(nsColor: app.defaultBackgroundColor).withAlpha(1)
        var foreground = BreeRGBA(nsColor: app.defaultForegroundColor).withAlpha(1)
        if !matchesTerminal {
            var resolvedLabel = NSColor.labelColor
            appearance.performAsCurrentDrawingAppearance {
                resolvedLabel = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
            }
            // The system dark window colour is a pure grey; start from the warm base instead.
            background = BreeRGBA(red: 0x1F / 255, green: 0x1E / 255, blue: 0x1D / 255)
            // labelColor carries alpha: composite it over the background.
            let label = BreeRGBA(nsColor: resolvedLabel)
            foreground = background.mixed(with: label.withAlpha(1), label.alpha)
        }

        let config = GhosttyConfig.loadForBree(preferredColorScheme: app.effectiveTerminalColorSchemePreference)
        let ansi = (0..<16).map { index in
            config.palette[index].map { BreeRGBA(nsColor: $0).withAlpha(1) } ?? foreground
        }
        return BreeChromePalette.Inputs(
            background: background,
            foreground: foreground,
            ansi: ansi,
            increaseContrast: DisplayAccessibilityOptions.current.increaseContrast
        )
    }

    nonisolated static let matchTerminalBackgroundKey = "sidebarMatchTerminalBackground"
}

extension UserDefaults {
    /// KVO hook for `sidebarMatchTerminalBackground`; the property name
    /// matches the UserDefaults key so observation fires only for this key.
    @objc dynamic var sidebarMatchTerminalBackground: Bool {
        bool(forKey: BreeChromePaletteProvider.matchTerminalBackgroundKey)
    }
}
