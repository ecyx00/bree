import BreeFoundation
import BreeSettings
import Foundation

/// Posted by the host when a sidebar menu or command-palette action should open the template gallery.
public extension Notification.Name {
    static let customSidebarTemplateGalleryRequested = Notification.Name("bree.settings.customSidebarTemplateGalleryRequested")
}

/// Holds a gallery request until the progressively mounted Custom Sidebars
/// section is ready to present it.
// lint:allow namespace-type — one-shot, main-actor handoff from a host menu to the lazily mounted Custom Sidebars section (#15931); candidate to become an injected SettingsRuntime value.
@MainActor
public final class CustomSidebarTemplateGalleryRequest {
    public static let shared = CustomSidebarTemplateGalleryRequest()

    private var pending = false

    private init() {}

    public func request() {
        pending = true
        NotificationCenter.default.post(name: .customSidebarTemplateGalleryRequested, object: nil)
    }

    public func consume() -> Bool {
        guard pending else { return false }
        pending = false
        return true
    }
}

/// Host-supplied callbacks the package's section views invoke for
/// actions that live outside the catalog — clearing browser history,
/// opening the user's editor on bree.json, sending feedback, posting
/// test notifications, restarting the app after a language change,
/// and launching the browser import workflow.
///
/// The package doesn't carry these implementations because they
/// depend on host-app services that have no place in a
/// Foundation-only settings package. The host implements this
/// protocol once and injects it via ``SettingsRuntime``; sections
/// check for `nil` callbacks and hide the corresponding buttons
/// when no host action is available.
@MainActor
public protocol SettingsHostActions: AnyObject, CloudMachinesSettingsActions {
    /// A registry snapshot used to populate the per-agent notification sound
    /// matrix. The host owns discovery so newly registered agents appear
    /// without a second list in the settings package.
    func notificationSoundAgentOptions() async -> [NotificationSoundAgentOption]

    /// Validates and prepares a custom notification sound before a matrix cell
    /// is persisted. Returning `false` keeps the previous cell untouched.
    func validateNotificationSoundFile(path: String) async -> Bool

    /// Deletes the user's browser history (visited-page suggestions,
    /// omnibar autocomplete cache). Idempotent.
    func clearBrowserHistory()

    /// Opens the bree JSON config file in the user's preferred
    /// external editor. The package's inline editor still works;
    /// this is the escape hatch for users who prefer their own
    /// editor.
    func openConfigInExternalEditor()

    /// Reads the existing config-backed automation rules for Settings status.
    func automationRulesStatus() async -> AutomationRulesStatus

    /// Opens ~/.bree/automations.json in the user's preferred editor.
    func openAutomationRulesInExternalEditor()

    /// Asks the running automation engine to reload its existing config file.
    /// Returns false when the host has no live automation engine.
    @discardableResult
    func reloadAutomationRules() -> Bool

    /// Names of custom sidebar files currently discovered by the host.
    func customSidebarNames() -> [String]

    /// Streams sidebar names after external filesystem changes, including an initial snapshot.
    func customSidebarNamesUpdates() async -> AsyncStream<[String]>

    /// Creates a starter custom sidebar and opens it in the preferred editor.
    func createCustomSidebar() -> CustomSidebarOnboardingResult

    /// Copies one bundled template into the custom-sidebar directory, selects it, and opens it.
    func installCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Installs a template and selects it without opening the editor.
    func useCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Temporarily selects a template for gallery preview.
    func previewCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult

    /// Keeps or discards the active gallery preview.
    func keepCustomSidebarPreview() -> CustomSidebarOnboardingResult
    func revertCustomSidebarPreview()

    /// Copies one bundled example into the custom-sidebar directory and opens it.
    func installCustomSidebarExample(id: String) -> CustomSidebarOnboardingResult

    /// Opens an existing discovered custom sidebar in the preferred editor.
    func openCustomSidebarInExternalEditor(named name: String)

    /// Creates the custom-sidebar directory when needed, then reveals it in Finder.
    func openCustomSidebarsFolder()

    /// Posts a synthetic test notification so the user can confirm
    /// the configured sound + behavior.
    func sendTestNotification()

    /// Opens System Settings to the bree notifications pane so the
    /// user can grant / revoke OS-level notification permission.
    func openSystemNotificationSettings()

    /// Returns the host's current macOS notification authorization state.
    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState

    /// Emits a fresh authorization state when the host observes a macOS
    /// notification permission change.
    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState>

    /// Asks the host to refresh macOS notification permission from
    /// `UNUserNotificationCenter`.
    func refreshDesktopNotificationAuthorizationStatus()

    /// Restarts the bree app. Used after the user changes the
    /// language picker, which requires a full process restart.
    func restartApp()

    /// Applies the current persisted control-socket configuration to the live server.
    func socketControlConfigurationDidChange()

    /// Live-reloads Ghostty after the adaptive-default-theme preference commits.
    func terminalAdaptiveDefaultThemeDidChange()

    /// Lists the current opt-in local tmux sessions using the host app's bundled CLI.
    func localTmuxSessions() async throws -> [LocalTmuxSessionSummary]

    /// Starts and attaches a named opt-in local tmux session.
    func startLocalTmuxSession(name: String) async throws

    /// Attaches an existing opt-in local tmux session.
    func attachLocalTmuxSession(_ session: LocalTmuxSessionSummary) async throws

    /// Opens the interactive terminal theme picker in a focused bree terminal pane.
    func openTerminalThemePicker()

    /// Theme directories, managed config file and current theme for the
    /// Settings theme gallery, or `nil` to show only the terminal picker button.
    func terminalThemeGalleryContext() -> TerminalThemeGalleryContext?

    /// Reloads terminals after the gallery rewrote the managed theme block.
    func terminalThemeConfigDidChange(phase: TerminalThemeReloadPhase)

    /// Opens a focused bree terminal pane running `bree import`, which lists other
    /// terminals' settings and imports the one the user picks.
    func openTerminalImport()

    /// Launches the host's browser-import flow (Safari / Chrome /
    /// Firefox source picker + profile selection + cookie prompt).
    func openBrowserImportFlow()

    /// Asks the OS for notification authorization. No-op if the user
    /// has already responded (granted or denied).
    func requestNotificationAuthorization()

    /// Opens the bree terminal config preview window (the legacy
    /// "Open Config" row in the App section). The host owns the
    /// window scene so the package can't open it directly.
    func openTerminalConfigWindow()

    /// Opens the user's workspace-layout action definitions for editing.
    func customizeWorkspaceLayouts()

    /// Persists an explicit menu-bar-only preference change in the host app.
    ///
    /// The host pairs the visible `app.menuBarOnly` setting with any hidden
    /// safety marker it needs before changing the process activation policy.
    ///
    /// - Returns: `true` when the host handled persistence for this change.
    @discardableResult
    func setMenuBarOnly(_ enabled: Bool) -> Bool

    /// Plays the currently configured notification sound so the user
    /// can preview it from the Settings UI.
    func previewNotificationSound(value: String, customFilePath: String)

    /// Returns the current number of saved browser-history entries, or
    /// `nil` if the host hasn't loaded the history store yet. The
    /// Browser section uses this to render a dynamic "N saved pages"
    /// subtitle next to the Clear History button.
    func browserHistoryEntryCount() -> Int?

    /// The current left-sidebar font size with the range + default the
    /// slider should use. Backed by the Ghostty config file, not
    /// `UserDefaults`, so it comes from the host rather than the catalog.
    func sidebarFontSize() -> SettingsFontSize

    /// Persists a new left-sidebar font size (in points) to the Ghostty
    /// config and live-reloads open windows. The host clamps to the valid
    /// range, so callers may pass any finite value.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. Callers should surface a save-failed message to
    ///   the user when this returns `false`, since the slider position no
    ///   longer reflects what is stored on disk.
    ///
    ///   The implementation performs the disk write off the main actor, so this
    ///   is `async`; call it from a `Task` in the slider/reset action.
    @discardableResult
    func setSidebarFontSize(_ points: Double) async -> Bool

    /// The customizable right-sidebar tabs in the user's order, hidden tabs
    /// included. Backed by host-owned mode metadata and tab preferences the
    /// package cannot read; empty when the host has no right sidebar
    /// (previews/tests).
    func rightSidebarTabs() -> [RightSidebarTabSettingsItem]

    /// Shows or hides one right-sidebar tab.
    ///
    /// - Returns: `false` when the host refused the change (hiding the last
    ///   visible tab); the card re-reads state so the toggle snaps back.
    @discardableResult
    func setRightSidebarTabVisible(id: String, visible: Bool) -> Bool

    /// Moves one right-sidebar tab by `offset` within the ordered tab list
    /// (negative is toward the front). Hidden tabs keep their slot.
    func moveRightSidebarTab(id: String, offset: Int)

    /// Yields a fresh tab list whenever the tabs change from any entrypoint
    /// (this card, the mode bar's context menu, shortcut rebinds that change
    /// the displayed digit hints).
    func rightSidebarTabsUpdates() -> AsyncStream<[RightSidebarTabSettingsItem]>

    /// The current workspace tab-bar font size with its range + default.
    /// Backed by the Ghostty config file (`surface-tab-bar-font-size`).
    func surfaceTabBarFontSize() -> SettingsFontSize

    /// Persists a new workspace tab-bar font size (in points) and reloads.
    /// The host clamps to the valid range.
    ///
    /// - Returns: `true` if the value was written and reloaded, `false` if
    ///   persistence failed. See ``setSidebarFontSize(_:)`` for how callers
    ///   should react to a `false` result and why this is `async`.
    @discardableResult
    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool

    /// Formats a point size for display next to a font-size slider
    /// (e.g. `12`, `13.5`), trimming trailing zeros.
    func formattedFontSize(_ points: Double) -> String

    /// The effective values of the Ghostty options Settings > Terminal edits
    /// natively, folded from the user's Ghostty config and bree's config in
    /// load order, with the file that last set each key. Reads the config
    /// files off the main actor.
    func terminalGhosttyOptions() async -> GhosttyTerminalOptionsSnapshot

    /// Writes one option's key to bree's Ghostty config and reloads the
    /// configuration so open terminals pick it up.
    ///
    /// - Returns: `false` when the write failed.
    @discardableResult
    func applyTerminalGhosttyOption(_ change: GhosttyTerminalOptionChange) async -> Bool

    /// The terminal colors in effect (theme included) and the part of them that
    /// bree's own Ghostty config overrides. Reads config files off the main actor.
    func terminalColorSnapshot() async -> GhosttyTerminalColorSnapshot

    /// Replaces every color override in bree's Ghostty config with `overrides`
    /// (an empty set removes them all) and reloads the configuration.
    ///
    /// - Returns: `false` when the write failed.
    @discardableResult
    func setTerminalColorOverrides(_ overrides: GhosttyTerminalColors) async -> Bool

    /// Shows the Sleepy Mode screensaver as a non-locking preview (any key/click
    /// exits, no Touch ID). The host owns the overlay window.
    func sleepyModePreview()

    /// Starts Sleepy Mode using the user's current settings. The host owns the
    /// overlay window.
    func sleepyModeStart()

    /// The app-owned Sleepy Mode settings store, so the Preferences section binds
    /// to the same instance the overlay renderer reads (rather than a package
    /// singleton). Previews/tests get a fresh isolated store via the default.
    func sleepyModeStore() -> SleepyModeSettingsStore

    /// Runs host-owned live-refresh side effects after the package resets every
    /// catalog-backed setting.
    func resetAllSettingsSideEffects()

    /// Invalidates host-owned shortcut caches after Settings persists a shortcut change.
    func notifyShortcutSettingsDidChange()

    /// Reloads bree.json after Settings writes it, so its values apply to
    /// UserDefaults and live chrome before the file watcher notices.
    func reloadSettingsFile()

    /// Whether the host can register `shortcut` as its system-wide hotkey.
    ///
    /// The macOS host applies Carbon conversion and app-reservation checks that
    /// the settings package cannot perform by itself.
    ///
    /// - Parameter shortcut: The complete Show/Hide shortcut proposed by Settings.
    /// - Returns: `true` when the host's runtime registrar can use the shortcut.
    func canRegisterSystemWideHotkey(_ shortcut: StoredShortcut) -> Bool

    /// Applies the host-side OS `AppleLanguages` override for a changed app
    /// language selection.
    func applyLanguageOverride(_ language: AppLanguage)
}

/// Host-provided summary of the existing config-backed automation rules.
public struct AutomationRulesStatus: Equatable, Sendable {
    public let configPath: String
    public let ruleCount: Int
    public let enabledCount: Int
    public let configExists: Bool
    public let hasError: Bool

    public init(
        configPath: String,
        ruleCount: Int,
        enabledCount: Int,
        configExists: Bool,
        hasError: Bool = false
    ) {
        self.configPath = configPath
        self.ruleCount = max(0, ruleCount)
        self.enabledCount = min(max(0, enabledCount), max(0, ruleCount))
        self.configExists = configExists
        self.hasError = hasError
    }

    /// Number of configured rules that are currently disabled.
    public var disabledCount: Int {
        ruleCount - enabledCount
    }
}

/// One right-sidebar tab as the Sidebar section's customization card renders
/// it. `id` is the host's stable mode identifier (the mode raw value).
public struct RightSidebarTabSettingsItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbolName: String
    public let isVisible: Bool
    /// Resolved switch-shortcut label (e.g. `⌃4`); empty when unbound.
    public let shortcutLabel: String

    public init(
        id: String,
        title: String,
        symbolName: String,
        isVisible: Bool,
        shortcutLabel: String
    ) {
        self.id = id
        self.title = title
        self.symbolName = symbolName
        self.isVisible = isVisible
        self.shortcutLabel = shortcutLabel
    }
}

public extension SettingsHostActions {
    /// Returns the registry-backed agent choices shown by notification sound settings.
    func notificationSoundAgentOptions() -> [NotificationSoundAgentOption] { [] }

    /// Validates a candidate custom notification sound path on the host.
    func validateNotificationSoundFile(path: String) async -> Bool { false }

    /// Empty automation summary for previews and package-only hosts.
    func automationRulesStatus() async -> AutomationRulesStatus {
        AutomationRulesStatus(
            configPath: "\(BreeIdentity.current.dotDirectoryTildePath)/automations.json",
            ruleCount: 0,
            enabledCount: 0,
            configExists: false
        )
    }

    /// Default no-op for hosts without app-owned automation files.
    func openAutomationRulesInExternalEditor() {}

    /// Default failure for hosts without a live automation engine.
    @discardableResult
    func reloadAutomationRules() -> Bool { false }

    /// Default no-op for previews and tests without a live control socket.
    func socketControlConfigurationDidChange() {}

    /// Right-sidebar tab defaults for previews, tests, and package-only
    /// hosts: no tabs, refuse mutations, no updates.
    func rightSidebarTabs() -> [RightSidebarTabSettingsItem] { [] }
    @discardableResult
    func setRightSidebarTabVisible(id: String, visible: Bool) -> Bool { false }
    func moveRightSidebarTab(id: String, offset: Int) {}
    func rightSidebarTabsUpdates() -> AsyncStream<[RightSidebarTabSettingsItem]> {
        AsyncStream { $0.finish() }
    }

    /// Default no-op for package-only settings hosts without Ghostty.
    func terminalAdaptiveDefaultThemeDidChange() {}

    /// Package-only previews expose no local tmux runtime.
    func localTmuxSessions() async throws -> [LocalTmuxSessionSummary] { [] }
    func startLocalTmuxSession(name: String) async throws {
        throw LocalTmuxSettingsActionError.unavailable
    }
    func attachLocalTmuxSession(_ session: LocalTmuxSessionSummary) async throws {
        throw LocalTmuxSettingsActionError.unavailable
    }

    /// Default no-op for package-only settings hosts without a terminal theme picker.
    func openTerminalThemePicker() {}

    /// Package-only hosts have no Ghostty config, so the gallery stays hidden.
    func terminalThemeGalleryContext() -> TerminalThemeGalleryContext? { nil }
    func terminalThemeConfigDidChange(phase: TerminalThemeReloadPhase) {}

    /// Default no-op for package-only settings hosts without a bundled bree CLI.
    func openTerminalImport() {}

    /// Default no-op for hosts with no app-owned reset side effects.
    func resetAllSettingsSideEffects() {}

    /// Default no-op for hosts with no app-owned shortcut caches.
    func notifyShortcutSettingsDidChange() {}

    /// Default no-op for hosts without a settings file store.
    func reloadSettingsFile() {}

    /// Custom-sidebar defaults for package previews and tests without a live host.
    func customSidebarNames() -> [String] { [] }

    func customSidebarNamesUpdates() async -> AsyncStream<[String]> {
        let names = customSidebarNames()
        return AsyncStream { continuation in
            continuation.yield(names)
            continuation.finish()
        }
    }
    func createCustomSidebar() -> CustomSidebarOnboardingResult {
        .writeFailed
    }
    func installCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func useCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func previewCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        _ = id
        return .writeFailed
    }
    func keepCustomSidebarPreview() -> CustomSidebarOnboardingResult { .templateUnavailable }
    func revertCustomSidebarPreview() {}

    func installCustomSidebarExample(id: String) -> CustomSidebarOnboardingResult {
        installCustomSidebarTemplate(id: id)
    }
    func openCustomSidebarInExternalEditor(named name: String) { _ = name }
    func openCustomSidebarsFolder() {}

    /// Default no-op for package previews and tests without host layout editing.
    func customizeWorkspaceLayouts() {}

    /// Default package-only validation for previews and non-macOS hosts.
    func canRegisterSystemWideHotkey(_ shortcut: StoredShortcut) -> Bool {
        ShortcutAction.showHideAllWindows.shortcutBindingPolicyResult(
            for: shortcut
        ) == .accepted
    }

    /// Default no-op for package previews and tests without app-language ownership.
    func applyLanguageOverride(_ language: AppLanguage) {}

    /// Default no-op preview action for hosts without a Sleepy Mode overlay.
    func sleepyModePreview() {}
    /// Default no-op start action for hosts without a Sleepy Mode overlay.
    func sleepyModeStart() {}
    /// Default isolated store for previews/tests with no Sleepy Mode host.
    func sleepyModeStore() -> SleepyModeSettingsStore { SleepyModeSettingsStore() }

    /// Default no-op for package previews and tests that have no activation-policy host.
    func setMenuBarOnly(_ enabled: Bool) -> Bool { false }

    func browserHistoryEntryCount() -> Int? { nil }

    /// Default: unknown permission state, for previews and tests without a host.
    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState { .unknown }

    /// Default: no live permission updates, for previews and tests without a host.
    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState> {
        AsyncStream { $0.finish() }
    }

    /// Default: no refresh hook, for previews and tests without a host.
    func refreshDesktopNotificationAuthorizationStatus() {}

    func sidebarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 12.5, minimum: 10, maximum: 20, defaultValue: 12.5)
    }

    func setSidebarFontSize(_ points: Double) async -> Bool { true }

    func surfaceTabBarFontSize() -> SettingsFontSize {
        SettingsFontSize(points: 11, minimum: 8, maximum: 14, defaultValue: 11)
    }

    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool { true }

    func formattedFontSize(_ points: Double) -> String {
        let scaled = (points * 100).rounded()
        let whole = Int(scaled / 100)
        let fraction = abs(Int(scaled) % 100)
        if fraction == 0 { return "\(whole)" }
        if fraction % 10 == 0 { return "\(whole).\(fraction / 10)" }
        return "\(whole).\(fraction < 10 ? "0" : "")\(fraction)"
    }
}

/// No-op ``SettingsHostActions`` for previews, tests, and any context
/// that renders settings without a live host. Lets the runtime expose a
/// non-optional ``SettingsRuntime/hostActions`` so section views never
/// have to branch on an optional host.
@MainActor
public final class NoopSettingsHostActions: SettingsHostActions {
    public init() {}
    public func clearBrowserHistory() {}
    public func openConfigInExternalEditor() {}
    public func sendTestNotification() {}
    public func openSystemNotificationSettings() {}
    public func restartApp() {}
    public func openBrowserImportFlow() {}
    public func requestNotificationAuthorization() {}
    public func openTerminalConfigWindow() {}
    /// No-op notification sound preview used by tests, previews, and
    /// package-only settings hosts.
    public func previewNotificationSound(value: String, customFilePath: String) {}
    public func browserHistoryEntryCount() -> Int? { nil }
}
