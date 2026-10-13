import BreeAppKitSupportUI
import BreeFoundation
import AppKit
import SwiftUI
import BreeTerminalCore

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case auto

    var id: String { rawValue }

    static var visibleCases: [AppearanceMode] {
        [.dark]
    }

    var displayName: String {
        switch self {
        case .system:
            return String(localized: "appearance.system", defaultValue: "System")
        case .light:
            return String(localized: "appearance.light", defaultValue: "Light")
        case .dark:
            return String(localized: "appearance.dark", defaultValue: "Dark")
        case .auto:
            return String(localized: "appearance.auto", defaultValue: "Auto")
        }
    }
}

enum AppearanceSettings {
    struct LiveApplyEnvironment {
        let setApplicationAppearance: (NSAppearance?) -> Void
        let synchronizeTerminalThemeWithAppearance: (NSAppearance?, String) -> Void
        let systemAppearance: () -> NSAppearance?

        init(
            setApplicationAppearance: @escaping (NSAppearance?) -> Void,
            synchronizeTerminalThemeWithAppearance: @escaping (NSAppearance?, String) -> Void,
            systemAppearance: @escaping () -> NSAppearance?
        ) {
            self.setApplicationAppearance = setApplicationAppearance
            self.synchronizeTerminalThemeWithAppearance = synchronizeTerminalThemeWithAppearance
            self.systemAppearance = systemAppearance
        }

        static var live: LiveApplyEnvironment {
            AppearanceSettings.currentLiveEnvironmentProvider()()
        }
    }

    private static let liveEnvironmentProviderLock = NSLock()
    private static var liveEnvironmentProvider: () -> LiveApplyEnvironment = {
        AppearanceSettings.defaultLiveEnvironment()
    }

    private static func currentLiveEnvironmentProvider() -> () -> LiveApplyEnvironment {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        return liveEnvironmentProvider
    }

    private static func defaultLiveEnvironment() -> LiveApplyEnvironment {
        LiveApplyEnvironment(
            setApplicationAppearance: { appearance in
                NSApplication.shared.appearance = appearance
            },
            synchronizeTerminalThemeWithAppearance: { appearance, source in
                GhosttyApp.shared.synchronizeThemeWithAppearance(appearance, source: source)
            },
            systemAppearance: {
                AppearanceSettings.systemNSAppearance()
            }
        )
    }

    /// The system interface-style snapshot used by terminal color-scheme
    /// resolution. Lifted to ``TerminalSystemAppearance`` in BreeTerminalCore so
    /// the terminal config type no longer reaches up into the app's appearance
    /// settings; this alias keeps the `AppearanceSettings.SystemAppearance`
    /// call-site name byte-identical.
    typealias SystemAppearance = TerminalSystemAppearance

    static let appearanceModeKey = "appearanceMode"
    static let defaultMode: AppearanceMode = .dark

    /// Bree is dark only: whatever is stored (an old Light or System default,
    /// a settings file) resolves to dark.
    static func mode(for rawValue: String?) -> AppearanceMode {
        .dark
    }

    @discardableResult
    static func resolvedMode(defaults: UserDefaults = .standard) -> AppearanceMode {
        let stored = defaults.string(forKey: appearanceModeKey)
        let resolved = mode(for: stored)
        if stored != resolved.rawValue {
            defaults.set(resolved.rawValue, forKey: appearanceModeKey)
        }
        return resolved
    }

    /// Returns the Ghostty terminal color-scheme preference.
    /// - Note: `colorSchemePreference` keeps the `appAppearance` parameter for API compatibility
    ///   and intentionally ignores it.
    static func colorSchemePreference(
        appAppearance _: NSAppearance? = nil,
        defaults: UserDefaults = .standard,
        systemAppearance: SystemAppearance? = nil
    ) -> GhosttyConfig.ColorSchemePreference {
        terminalColorSchemePreference(defaults: defaults, systemAppearance: systemAppearance)
    }

    // Ghostty split-theme resolution follows bree's persisted appearance mode.
    // AppKit view/window appearances can lag during live mode changes.
    // The resolution itself now lives in BreeTerminalCore
    // (TerminalColorSchemePreference.resolve); this forwards the app's
    // normalized appearance mode into it so both surfaces share one source of
    // truth.
    static func terminalColorSchemePreference(
        defaults: UserDefaults = .standard,
        systemAppearance: SystemAppearance? = nil
    ) -> GhosttyConfig.ColorSchemePreference {
        TerminalColorSchemePreference.resolve(
            appearanceModeRawValue: mode(for: defaults.string(forKey: appearanceModeKey)).rawValue,
            systemAppearance: systemAppearance,
            defaults: defaults
        )
    }

    static func systemNSAppearance(defaults: UserDefaults = .standard) -> NSAppearance? {
        NSAppearance(named: SystemAppearance.current(defaults: defaults).prefersDark ? .darkAqua : .aqua)
    }

    static func colorSchemeOverride(for rawValue: String?) -> ColorScheme? {
        switch mode(for: rawValue) {
        case .system, .auto:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func colorScheme(for rawValue: String?, fallback: ColorScheme) -> ColorScheme {
        colorSchemeOverride(for: rawValue) ?? fallback
    }

    /// The window-level light/dark appearance translucent chrome composites
    /// against, resolved from the stored appearance mode and the app's live
    /// effective appearance.
    @MainActor
    static func currentAmbientColorScheme(defaults: UserDefaults = .standard) -> ColorScheme {
        effectiveColorScheme(
            for: defaults.string(forKey: appearanceModeKey),
            fallback: .light
        )
    }

    /// Resolves the color scheme the chrome should render with. Explicit modes
    /// win. After launch, system mode resolves from the app's live
    /// effectiveAppearance, which (unlike the AppleInterfaceStyle default) stays
    /// fresh on scripted appearance changes. During launch, use the ambient
    /// fallback because Tahoe can crash if effectiveAppearance is touched before
    /// applicationDidFinishLaunching.
    @MainActor
    static func effectiveColorScheme(
        for rawValue: String?,
        fallback: ColorScheme,
        isApplicationFinishedLaunching: @MainActor () -> Bool = AppIconLaunchState.isApplicationFinishedLaunching,
        effectivePrefersDark: @MainActor () -> Bool? = {
            guard let app = NSApp else { return nil }
            return app.effectiveAppearance.breePrefersDark
        }
    ) -> ColorScheme {
        if let override = colorSchemeOverride(for: rawValue) { return override }
        guard isApplicationFinishedLaunching() else { return fallback }
        guard let prefersDark = effectivePrefersDark() else { return fallback }
        return prefersDark ? .dark : .light
    }

    @discardableResult
    static func selectMode(
        _ mode: AppearanceMode,
        defaults: UserDefaults = .standard,
        source: String,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: mode.rawValue)
        defaults.set(normalized.rawValue, forKey: appearanceModeKey)
        applyLiveMode(normalized, source: source, environment: environment)
        return normalized
    }

    @discardableResult
    static func applyStoredMode(
        rawValue: String?,
        defaults: UserDefaults = .standard,
        source: String,
        duringLaunch: Bool = false,
        synchronizeTerminalTheme: Bool = true,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: rawValue)
        if rawValue != normalized.rawValue {
            defaults.set(normalized.rawValue, forKey: appearanceModeKey)
        }
        applyLiveMode(
            normalized,
            source: source,
            duringLaunch: duringLaunch,
            synchronizeTerminalTheme: synchronizeTerminalTheme,
            environment: environment
        )
        return normalized
    }

    @discardableResult
    static func applyLiveMode(
        _ mode: AppearanceMode,
        source: String,
        duringLaunch: Bool = false,
        synchronizeTerminalTheme: Bool = true,
        environment: LiveApplyEnvironment = .live
    ) -> AppearanceMode {
        let normalized = Self.mode(for: mode.rawValue)
        let appearance = applicationAppearance(
            for: normalized,
            duringLaunch: duringLaunch,
            environment: environment
        )
        environment.setApplicationAppearance(appearance)
        if synchronizeTerminalTheme {
            environment.synchronizeTerminalThemeWithAppearance(appearance, source)
        }
        return normalized
    }

    private static func applicationAppearance(
        for mode: AppearanceMode,
        duringLaunch: Bool,
        environment: LiveApplyEnvironment
    ) -> NSAppearance? {
        switch mode {
        case .system:
            return duringLaunch ? environment.systemAppearance() : nil
        case .light:
            return NSAppearance(named: .aqua)
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .auto:
            return nil
        }
    }

    static func setLiveEnvironmentProviderForTesting(_ provider: @escaping () -> LiveApplyEnvironment) {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        liveEnvironmentProvider = provider
    }

    static func resetLiveEnvironmentProviderForTesting() {
        liveEnvironmentProviderLock.lock()
        defer { liveEnvironmentProviderLock.unlock() }
        liveEnvironmentProvider = {
            AppearanceSettings.defaultLiveEnvironment()
        }
    }
}

final class AppearanceSettingsUserDefaultsObserver {
    struct Environment {
        let addDefaultsObserver: (@escaping @MainActor @Sendable () -> Void) -> NSObjectProtocol
        let removeObserver: (NSObjectProtocol) -> Void
        let currentRawValue: () -> String?
        let applyStoredMode: (String?, String) -> AppearanceMode

        static func live(
            defaults: UserDefaults = .standard,
            notificationCenter: NotificationCenter = .default
        ) -> Environment {
            Environment(
                addDefaultsObserver: { handler in
                    notificationCenter.addUserDefaultsObserver(object: nil) {
                        handler()
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
                        source: source
                    )
                }
            )
        }
    }

    static let shared = AppearanceSettingsUserDefaultsObserver()

    private let environment: Environment
    private var defaultsObserver: NSObjectProtocol?
    private var lastObservedRawValue: String?
    private var source: String

    init(
        environment: Environment = .live(),
        source: String = "breeApp.appearanceDefaultsChanged"
    ) {
        self.environment = environment
        self.source = source
    }

    deinit {
        stopObserving()
    }

    func startObserving(source: String? = nil) {
        if let source {
            self.source = source
        }
        lastObservedRawValue = environment.currentRawValue()
        guard defaultsObserver == nil else { return }
        defaultsObserver = environment.addDefaultsObserver { [weak self] in
            self?.applyIfChanged()
        }
    }

    func stopObserving() {
        guard let defaultsObserver else { return }
        environment.removeObserver(defaultsObserver)
        self.defaultsObserver = nil
    }

    private func applyIfChanged() {
        let rawValue = environment.currentRawValue()
        guard rawValue != lastObservedRawValue else { return }
        let appliedMode = environment.applyStoredMode(rawValue, source)
        lastObservedRawValue = appliedMode.rawValue
    }
}

/// Re-resolves and re-injects the color scheme at the window root.
///
/// In system mode, the ambient `colorScheme` supplied by the hosting bridge's
/// `@Environment` can go stale on scripted OS appearance changes (Shortcuts'
/// "Set Appearance", #6385) — SwiftUI doesn't reliably re-resolve it for
/// already-visible windows. So in system mode this modifier ignores the
/// ambient value and instead resolves fresh from `NSApp.effectiveAppearance`
/// (see `AppearanceSettings.effectiveColorScheme`), then re-injects the result
/// at the window root via `.environment(\.colorScheme, ...)` so it propagates
/// to every descendant that reads the ambient color scheme. Re-resolution is
/// keyed off `.systemAppearanceDidChange`, which `SystemAppearanceObserver`
/// posts whenever the effective appearance actually changes while in system
/// mode.
///
/// With `followsSurfaces`, a window that paints palette surfaces (Settings,
/// Quick View, popovers) takes its scheme from ``BreeSurfaceAppearance``
/// while "match terminal background" is on, so system controls and labels
/// stay readable on the theme-coloured surfaces. Off, the setting above rules.
private struct AppearanceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @State private var systemAppearanceGeneration = 0
    @State private var paletteStore = BreeChromePaletteStore.shared
    let rawValue: String?
    var followsSurfaces = false

    func body(content: Content) -> some View {
        let surfaceScheme = followsSurfaces ? BreeSurfaceAppearance.colorScheme(for: paletteStore.palette) : nil
        let override = surfaceScheme ?? AppearanceSettings.colorSchemeOverride(for: rawValue)
        let _ = systemAppearanceGeneration
        let effective = surfaceScheme
            ?? AppearanceSettings.effectiveColorScheme(for: rawValue, fallback: colorScheme)
        content
            .environment(\.colorScheme, effective)
            .preferredColorScheme(override)
            .breeAccentColorEnvironment()
            .onReceive(NotificationCenter.default.publisher(for: .systemAppearanceDidChange)) { _ in
                systemAppearanceGeneration &+= 1
            }
    }
}

/// Injects the resolved bree accent (``EnvironmentValues/breeAccentColor``)
/// for a SwiftUI root and keeps it current from the app delegate's
/// ``BreeAccentColorObserver``. Window roots get it through
/// `breeAppearanceColorScheme`; hosting views mounted outside a window root
/// (search overlays, titlebar accessories, popovers) apply it directly.
/// Native controls (toggles, pickers, prominent buttons) follow the palette's
/// monochrome accent, never the system blue. Sits inside the palette environment.
private struct BreeAccentTint: ViewModifier {
    @Environment(\.breePalette) private var palette
    func body(content: Content) -> some View { content.tint(palette.accentFill) }
}

struct BreeAccentColorEnvironmentModifier: ViewModifier {
    @State private var accentColor = AppDelegate.shared?.accentColor ?? BreeAccentColor()

    func body(content: Content) -> some View {
        content
            .modifier(BreeAccentTint())
            .environment(\.breeAccentColor, accentColor)
            .breePaletteEnvironment()
            .onReceive(NotificationCenter.default.publisher(for: BreeAccentColor.didChangeNotification)) { notification in
                if let observer = notification.object as? BreeAccentColorObserver {
                    accentColor = observer.current
                }
            }
    }
}

extension View {
    func breeAccentColorEnvironment() -> ModifiedContent<Self, BreeAccentColorEnvironmentModifier> {
        modifier(BreeAccentColorEnvironmentModifier())
    }

    func breeAppearanceColorScheme(_ rawValue: String?, followsSurfaces: Bool = false) -> some View {
        modifier(AppearanceColorSchemeModifier(rawValue: rawValue, followsSurfaces: followsSurfaces))
    }
}

/// The light/dark decision for windows and panels that paint palette
/// surfaces. It reuses the window chrome rule
/// (`WindowChromeColorResolver.readableColorScheme`, WCAG contrast) on the
/// palette's base surface, so it agrees with `WindowAppearanceSnapshot`.
/// `nil` when "match terminal background" is off: the palette then comes from
/// the system appearance and nothing needs forcing.
enum BreeSurfaceAppearance {
    static func colorScheme(
        for palette: BreeChromePalette,
        matchesTerminal: Bool = matchesTerminalBackground
    ) -> ColorScheme? {
        guard matchesTerminal else { return nil }
        return WindowChromeColorResolver().readableColorScheme(for: palette.ns.surfaceBase)
    }

    /// AppKit counterpart for panels and popovers; `nil` leaves the appearance inherited.
    static func nsAppearance(for palette: BreeChromePalette = .currentSnapshot) -> NSAppearance? {
        colorScheme(for: palette).map(WindowAppearanceSnapshot.appKitAppearance(for:))
    }

    /// Keeps `window.appearance` on the surface decision, live: it is set now
    /// and again on every palette change (theme, match toggle, accent). Call
    /// once per window.
    @MainActor
    static func follow(_ window: NSWindow) {
        window.appearance = nsAppearance()
        let box = ObserverBox()
        box.token = NotificationCenter.default.addObserver(
            forName: BreeChromePaletteStore.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak window, box] _ in
            MainActor.assumeIsolated {
                guard let window else {
                    if let token = box.token { NotificationCenter.default.removeObserver(token) }
                    return
                }
                window.appearance = nsAppearance()
            }
        }
    }

    private final class ObserverBox: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
    }

    static var matchesTerminalBackground: Bool {
        UserDefaults.standard.object(forKey: BreeChromePaletteProvider.matchTerminalBackgroundKey) as? Bool ?? true
    }
}

/// Applies ``BreeSurfaceAppearance`` to a SwiftUI subtree (popovers, panels)
/// that has no appearance-mode root of its own; live on palette changes.
private struct BreeSurfaceColorSchemeModifier: ViewModifier {
    @Environment(\.colorScheme) private var inherited
    @State private var paletteStore = BreeChromePaletteStore.shared

    func body(content: Content) -> some View {
        let scheme = BreeSurfaceAppearance.colorScheme(for: paletteStore.palette)
        content
            .environment(\.colorScheme, scheme ?? inherited)
            .preferredColorScheme(scheme)
    }
}

extension View {
    func breeSurfaceColorScheme() -> some View {
        modifier(BreeSurfaceColorSchemeModifier())
    }
}
