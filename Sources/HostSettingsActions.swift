import AppKit
import BreeWorkspaces
import BreeSettings
import BreeSettingsUI
import BreeSwiftRenderUI
import BreeFoundation
import Foundation
import OSLog
import SwiftUI
nonisolated private let hostSettingsLogger = Logger(subsystem: "com.bree.app", category: "Settings")
/// Routes Settings actions to app-owned services, keeping the package independent.
@MainActor
final class HostSettingsActions: SettingsHostActions {
    private let configFileURL: URL
    private let browserDataImportCoordinator: BrowserDataImportCoordinator
    private let automationConfigStore: AutomationConfigStore
    private let openAutomationRulesFile: @MainActor (URL) -> Void
    private let reportAutomationRulesError: @MainActor (Error) -> Void
    /// Serializes font-size config writes so rapid slider saves persist in order.
    private let fontConfigWriter = FontConfigWriter()

    /// AppKit window identifier the dedicated terminal-config window carries.
    /// Matches the value `ConfigSettingsView.configureWindow` assigns so the
    /// host reuses a config window opened from any entrypoint (the legacy
    /// in-app button's SwiftUI scene or this host-presented window).
    private let configWindowIdentifier = "bree.configEditor"

    /// Observes the `appIconMode` defaults key the settings package writes
    /// so the host can re-apply the dock/app-switcher icon when the user
    /// changes the App Icon picker. The package only persists the value;
    /// applying `NSApplication.shared.applicationIconImage` is host work.
    ///
    /// Uses the closure-based `NSKeyValueObservation` token API, the
    /// sanctioned seam for bridging a Foundation type that exposes change
    /// only via KVO (`UserDefaults`). The token is invalidated in `deinit`.
    private var appIconModeObservation: NSKeyValueObservation?

    /// Retains the AppKit window hosting ``ConfigSettingsView`` so repeated
    /// "Open Config" presses reuse the same dedicated terminal-config
    /// window instead of stacking duplicates.
    private var configWindow: NSWindow?
    private var configWindowCloseObserver: WindowCloseObserver?
    /// Owns the currently requested sound preview so a new selection cancels
    /// the old one and closing Settings does not leave an untracked playback
    /// task behind.
    private var notificationSoundPreviewTask: Task<Void, Never>?
    private var customSidebarPreview: (id: String, providerId: String, previousProviderId: String)?

    init(
        configFileURL: URL,
        browserDataImportCoordinator: BrowserDataImportCoordinator,
        automationConfigStore: AutomationConfigStore = AutomationConfigStore(),
        openAutomationRulesFile: @escaping @MainActor (URL) -> Void = {
            PreferredEditorService(defaults: .standard).open($0)
        },
        reportAutomationRulesError: @escaping @MainActor (Error) -> Void = { _ in
            let alert = NSAlert()
            alert.messageText = String(
                localized: "settings.automation.rules.createFailed.title",
                defaultValue: "Could Not Create Automation Rules"
            )
            alert.informativeText = String(
                localized: "settings.automation.rules.createFailed.message",
                defaultValue: "Check that the configuration folder is writable and the disk has free space, then try again."
            )
            alert.runModal()
        }
    ) {
        self.configFileURL = configFileURL
        self.automationConfigStore = automationConfigStore
        self.openAutomationRulesFile = openAutomationRulesFile
        self.reportAutomationRulesError = reportAutomationRulesError
        self.browserDataImportCoordinator = browserDataImportCoordinator
        startObservingAppIconMode()
    }

    deinit {
        appIconModeObservation?.invalidate()
        notificationSoundPreviewTask?.cancel()
    }

    private func startObservingAppIconMode() {
        // Apply once on construction so a value persisted before this
        // instance existed (e.g. from the config file) is reflected.
        AppIconSettings.applyIcon(AppIconSettings.resolvedMode())

        appIconModeObservation = UserDefaults.standard.observe(
            \.appIconMode,
            options: [.new]
        ) { _, _ in
            // KVO delivers on the thread that mutated the key; @AppStorage
            // writes happen on the main actor, so hop to it to apply.
            Task { @MainActor in
                AppIconSettings.applyIcon(AppIconSettings.resolvedMode())
            }
        }
    }

    func clearBrowserHistory() {
        BrowserHistoryStore.shared.clearHistory()
    }

    func sleepyModePreview() {
        SleepyModeController.shared.preview()
    }

    func sleepyModeStart() {
        SleepyModeController.shared.activate()
    }

    func sleepyModeStore() -> SleepyModeSettingsStore {
        SleepyModeController.shared.store
    }

    func resetAllSettingsSideEffects() {
        LanguageSettingsStore(defaults: .standard, domainName: ProcessDefaultsDomain.name).applyLanguageOverride(.system)
        PaneChromeSettings.notifyDidChange()
        TerminalAdaptiveDefaultThemeSettings.notifyDidChange()
        AppDelegate.shared?.reconcileSocketListenerConfiguration(source: "settings.reset_all")
    }

    func terminalAdaptiveDefaultThemeDidChange() {
        TerminalAdaptiveDefaultThemeSettings.notifyDidChange()
    }

    func openTerminalThemePicker() {
        // The native Settings entry point keeps CLI diagnostics private. The
        // interactive picker still owns stdout/the TTY, while raw helper and
        // launch errors on stderr are suppressed on this user-facing path.
        openBundledCLIInTerminalTab(arguments: "themes 2>/dev/null; exit", purpose: "theme picker")
    }

    func openTerminalImport() {
        // No trailing `exit`: the tab stays open so the import report can be read.
        openBundledCLIInTerminalTab(arguments: "import", purpose: "terminal import")
    }

    /// Opens a focused terminal tab in the selected workspace that runs the bundled
    /// bree CLI with `arguments`, the shared path for Settings rows backed by a CLI command.
    private func openBundledCLIInTerminalTab(arguments: String, purpose: String) {
        let cliURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin/bree", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            hostSettingsLogger.error("Settings \(purpose, privacy: .public) unavailable: bundled bree CLI missing")
            return
        }

        guard let appDelegate = AppDelegate.shared,
              let manager = appDelegate.activeTabManagerForCommands(),
              let workspace = manager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        let initialInput = "\(LocalSurfaceProvider.shellQuote(cliURL.path)) \(arguments)\n"
        do {
            let pane = try SurfacePaneFactory.makeTerminalPane(
                initialCommand: nil,
                initialInput: initialInput,
                workingDirectory: nil,
                at: .workspace(id: workspace.id, placement: .tab),
                focus: true
            )
            if let windowID = appDelegate.windowId(for: manager) {
                _ = appDelegate.focusMainWindow(windowId: windowID)
            }
            SurfacePaneFactory.focus(
                panelID: pane.panelID,
                in: pane.workspaceID
            )
        } catch {
            hostSettingsLogger.error("Failed to open Settings \(purpose, privacy: .public) terminal")
        }
    }

    func terminalThemeGalleryContext() -> TerminalThemeGalleryContext? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let configURL = BreeGhosttyConfigPathResolver().editableConfigURL(
            currentBundleIdentifier: Bundle.main.bundleIdentifier,
            appSupportDirectory: appSupport
        )
        let themeDirectories = GhosttyThemeDirectories(
            environment: ProcessInfo.processInfo.environment,
            bundledThemeDirectories: [Bundle.main.resourceURL?.appendingPathComponent("ghostty/themes", isDirectory: true)]
                .compactMap { $0 }
        ).urls
        return TerminalThemeGalleryContext(
            configFile: BreeManagedThemeConfigFile(url: configURL),
            themeDirectories: themeDirectories,
            readCurrentThemeValue: { GhosttyApp.userAppearanceConfigSummary().lastThemeDirective },
            prefersDarkAppearance: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        )
    }

    func terminalThemeConfigDidChange(phase: TerminalThemeReloadPhase) {
        let phaseName: String
        switch phase {
        case .preview: phaseName = "preview"
        case .final: phaseName = "final"
        }
        AppDelegate.shared?.reloadGhosttyConfigurationForBreeThemeSource(
            GhosttySurfaceConfigurationRefresh.breeThemeReloadSource(phase: phaseName)
        )
    }

    func notifyShortcutSettingsDidChange() {
        reloadSettingsFile()
    }

    func reloadSettingsFile() {
        // reload() already posts didChangeNotification when the file's
        // contents changed; posting again here double-notified every
        // listener. Only post when the reload saw no change, so callers
        // still get exactly one notification either way.
        if !KeyboardShortcutSettings.settingsFileStore.reload(notificationSourceURL: configFileURL) {
            KeyboardShortcutSettings.notifySettingsFileDidChange(sourceURL: configFileURL)
        }
    }

    func canRegisterSystemWideHotkey(
        _ shortcut: BreeSettings.StoredShortcut
    ) -> Bool {
        SystemWideHotkeySettings.registrationCandidate(
            for: StoredShortcut(breeSettingsStoredShortcut: shortcut)
        ) != nil
    }

    func applyLanguageOverride(_ language: AppLanguage) {
        LanguageSettingsStore(defaults: .standard, domainName: ProcessDefaultsDomain.name).applyLanguageOverride(language)
    }

    func openConfigInExternalEditor() {
        // Honor the user's configured editor (`preferredEditorCommand`),
        // falling back to the OS default. Opening the config file directly
        // through `NSWorkspace.shared.open` would route to the default
        // `.json` handler and ignore the bree setting.
        PreferredEditorService(defaults: .standard).open(configFileURL)
    }

    /// Reads the existing automation configuration off-main and summarizes it for Settings.
    func automationRulesStatus() async -> AutomationRulesStatus {
        let fileURL = automationConfigStore.fileURL
        let configExists = FileManager.default.fileExists(atPath: fileURL.path)
        do {
            let configuration = try await automationConfigStore.loadOffMain()
            let enabledCount = configuration.rules.reduce(into: 0) { count, rule in
                if rule.enabled { count += 1 }
            }
            return AutomationRulesStatus(
                configPath: fileURL.path,
                ruleCount: configuration.rules.count,
                enabledCount: enabledCount,
                configExists: configExists
            )
        } catch {
            hostSettingsLogger.error("Failed to load automation rules: \(String(describing: error), privacy: .private)")
            return AutomationRulesStatus(
                configPath: fileURL.path,
                ruleCount: 0,
                enabledCount: 0,
                configExists: configExists,
                hasError: true
            )
        }
    }

    /// Materializes the existing empty v1 configuration when needed, then opens it in the preferred editor.
    func openAutomationRulesInExternalEditor() {
        let fileURL = automationConfigStore.fileURL
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                try automationConfigStore.save(AutomationConfiguration())
            } catch {
                hostSettingsLogger.error("Failed to create automation rules: \(String(describing: error), privacy: .private)")
                reportAutomationRulesError(error)
                return
            }
        }
        openAutomationRulesFile(fileURL)
    }

    /// Routes a reload request to the already-attached automation engine.
    @discardableResult
    func reloadAutomationRules() -> Bool {
        if case .ok = TerminalController.shared.v2AutomationReload() {
            return true
        }
        return false
    }

    func customSidebarNames() -> [String] {
        BreeExtensionSidebarSelection.discoveredCustomSidebarNames(
            sidebarsDirectory: BreeExtensionSidebarSelection.customSidebarsDirectory
        )
    }

    func customSidebarNamesUpdates() async -> AsyncStream<[String]> {
        await CustomSidebarDiscovery(directory: BreeExtensionSidebarSelection.customSidebarsDirectory).updates()
    }

    func createCustomSidebar() -> CustomSidebarOnboardingResult {
        guard let template = CustomSidebarOnboardingAssets().starterTemplate() else {
            return .templateUnavailable
        }
        return installCustomSidebarTemplate(
            template,
            name: template.suggestedName,
            uniquingIfNeeded: true
        )
    }

    func installCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        installCustomSidebarTemplate(id: id, openEditor: true)
    }

    func useCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        installCustomSidebarTemplate(id: id, openEditor: false)
    }

    private func installCustomSidebarTemplate(id: String, openEditor: Bool) -> CustomSidebarOnboardingResult {
        guard BreeExtensionSidebarSelection.customSidebarsEnabled else { return .writeFailed }
        guard let template = CustomSidebarOnboardingAssets().exampleTemplate(id: id) else {
            return .templateUnavailable
        }
        let result = installCustomSidebarTemplate(
            template,
            name: template.suggestedName,
            uniquingIfNeeded: true,
            openEditor: openEditor
        )
        if case let .created(name) = result {
            BreeExtensionSidebarSelection.clearInMemoryTemplatePreview()
            customSidebarPreview = nil
            UserDefaults.standard.set(true, forKey: SettingCatalog().betaFeatures.customSidebars.userDefaultsKey)
            if template.descriptor.kind == .right {
                if AppDelegate.shared?.selectCustomSidebarInRightPanel(name: name) != true {
                    // A settings window can outlive the main window. Keep the
                    // new file usable through the left-sidebar picker if the
                    // right-panel host is unavailable.
                    BreeExtensionSidebarSelection.setProviderId(
                        BreeExtensionSidebarSelection.customSidebarProviderPrefix + name
                    )
                }
            } else {
                BreeExtensionSidebarSelection.setProviderId(
                    BreeExtensionSidebarSelection.customSidebarProviderPrefix + name
                )
            }
            NotificationCenter.default.post(
                name: .customSidebarReloadRequested,
                object: nil,
                userInfo: ["names": [name]]
            )
        }
        return result
    }

    func previewCustomSidebarTemplate(id: String) -> CustomSidebarOnboardingResult {
        revertCustomSidebarPreview()
        guard BreeExtensionSidebarSelection.customSidebarsEnabled else { return .writeFailed }
        guard let template = CustomSidebarOnboardingAssets().exampleTemplate(id: id) else {
            return .templateUnavailable
        }
        let previous = UserDefaults.standard.string(forKey: BreeExtensionSidebarSelection.defaultsKey)
            ?? BreeExtensionSidebarSelection.defaultProviderId
        let providerName = ".bree-preview-\(id)-\(UUID().uuidString.prefix(8).lowercased())"
        let providerId = BreeExtensionSidebarSelection.customSidebarProviderPrefix + providerName
        customSidebarPreview = (id: id, providerId: providerId, previousProviderId: previous)
        BreeExtensionSidebarSelection.setInMemoryTemplatePreview(providerId: providerId, source: template.source)
        BreeExtensionSidebarSelection.setProviderId(providerId)
        NotificationCenter.default.post(name: .customSidebarReloadRequested, object: nil)
        return .created(name: providerName)
    }

    func keepCustomSidebarPreview() -> CustomSidebarOnboardingResult {
        guard let preview = customSidebarPreview else { return .templateUnavailable }
        let result = useCustomSidebarTemplate(id: preview.id)
        if case .created = result {
            BreeExtensionSidebarSelection.clearInMemoryTemplatePreview()
            customSidebarPreview = nil
        }
        return result
    }

    func revertCustomSidebarPreview() {
        guard let preview = customSidebarPreview else { return }
        BreeExtensionSidebarSelection.clearInMemoryTemplatePreview()
        BreeExtensionSidebarSelection.setProviderId(preview.previousProviderId)
        NotificationCenter.default.post(name: .customSidebarReloadRequested, object: nil)
        customSidebarPreview = nil
    }

    func installCustomSidebarExample(id: String) -> CustomSidebarOnboardingResult {
        installCustomSidebarTemplate(id: id)
    }

    func openCustomSidebarInExternalEditor(named name: String) {
        guard let fileURL = BreeExtensionSidebarSelection.customSidebarFileURL(forName: name) else {
            return
        }
        PreferredEditorService(defaults: .standard).open(fileURL)
    }

    func openCustomSidebarsFolder() {
        do {
            let directory = try BreeExtensionSidebarSelection.ensureCustomSidebarsDirectory(
                BreeExtensionSidebarSelection.customSidebarsDirectory
            )
            NSWorkspace.shared.open(directory)
        } catch {
            hostSettingsLogger.error("failed to open custom sidebars folder: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func installCustomSidebarTemplate(
        _ template: CustomSidebarTemplate,
        name: String,
        uniquingIfNeeded: Bool,
        openEditor: Bool = true
    ) -> CustomSidebarOnboardingResult {
        switch BreeExtensionSidebarSelection.writeCustomSidebar(
            named: name,
            fileExtension: template.fileExtension,
            source: template.source,
            uniquingIfNeeded: uniquingIfNeeded,
            sidebarsDirectory: BreeExtensionSidebarSelection.customSidebarsDirectory
        ) {
        case let .created(createdName, fileURL):
            if openEditor {
                PreferredEditorService(defaults: .standard).open(fileURL)
            }
            return .created(name: createdName)
        case .invalidTemplate:
            return .templateUnavailable
        case .invalidName, .alreadyExists, .failed:
            return .writeFailed
        }
    }

    private static func desktopNotificationAuthorizationState(
        from state: NotificationAuthorizationState
    ) -> DesktopNotificationAuthorizationState {
        switch state {
        case .unknown: return .unknown
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .denied: return .denied
        case .provisional: return .provisional
        case .ephemeral: return .ephemeral
        }
    }

    func sendTestNotification() {
        TerminalNotificationStore.shared.sendSettingsTestNotification()
    }

    func openSystemNotificationSettings() {
        TerminalNotificationStore.shared.openNotificationSettings()
    }

    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState {
        Self.desktopNotificationAuthorizationState(from: TerminalNotificationStore.shared.authorizationState)
    }

    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState> {
        AsyncStream { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            let observer = SettingsObserverToken(
                NotificationCenter.default.addObserver(
                    forName: TerminalNotificationStore.authorizationStatusDidChangeNotification,
                    object: nil,
                    queue: nil
                ) { _ in
                    signalContinuation.yield(())
                }
            )
            let drainTask = Task { @MainActor in
                continuation.yield(
                    Self.desktopNotificationAuthorizationState(
                        from: TerminalNotificationStore.shared.authorizationState
                    )
                )
                for await _ in signals {
                    if Task.isCancelled { break }
                    continuation.yield(
                        Self.desktopNotificationAuthorizationState(
                            from: TerminalNotificationStore.shared.authorizationState
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observer.remove()
            }
        }
    }

    func refreshDesktopNotificationAuthorizationStatus() {
        TerminalNotificationStore.shared.refreshAuthorizationStatus()
    }

    // MARK: - Local session persistence

    func localTmuxSessions() async throws -> [LocalTmuxSessionSummary] {
        let data = try await runLocalTmuxCLI(arguments: ["local-tmux", "list", "--json"])
        do {
            return try LocalTmuxSessionListDecoder().decode(data)
        } catch {
            hostSettingsLogger.error("Bundled local-tmux CLI returned invalid session data")
            throw LocalTmuxSettingsActionError.invalidResponse
        }
    }

    func startLocalTmuxSession(name: String) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let workspace = AppDelegate.shared?.activeTabManagerForCommands()?.selectedWorkspace else {
            throw LocalTmuxSettingsActionError.unavailable
        }
        let workspaceID = workspace.id
        let cwd = workspace.currentDirectory
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        _ = try await runLocalTmuxCLI(arguments: Self.localTmuxStartArguments(
            name: trimmedName,
            workspaceID: workspaceID,
            cwd: cwd,
            socketPath: socketPath
        ))
    }

    nonisolated static func localTmuxStartArguments(
        name: String,
        workspaceID: UUID,
        cwd: String,
        socketPath: String
    ) -> [String] {
        ["--socket", socketPath, "local-tmux", "start", "--name", name,
         "--workspace", workspaceID.uuidString, "--cwd", cwd, "--json"]
    }

    func attachLocalTmuxSession(_ session: LocalTmuxSessionSummary) async throws {
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        var arguments = ["--socket", socketPath, "local-tmux", "attach"]
        switch session.selector {
        case .managed(let id, _):
            arguments.append(contentsOf: ["--id", id.uuidString])
        case .unmanaged(let name):
            // A tmux session name may start with "-", so pass it as a flag value.
            arguments.append(contentsOf: ["--name", name])
        }
        arguments.append("--json")
        _ = try await runLocalTmuxCLI(arguments: arguments)
    }

    private func runLocalTmuxCLI(arguments: [String]) async throws -> Data {
        guard let cliURL = CLIForwardingLaunchRouter.bundledCLIURL() else {
            throw LocalTmuxSettingsActionError.cliMissing
        }

        return try await Self.runLocalTmuxCLI(executableURL: cliURL, arguments: arguments)
    }

    nonisolated static func runLocalTmuxCLI(
        executableURL cliURL: URL,
        arguments: [String],
        runner: any CommandRunning = CommandRunner()
    ) async throws -> Data {
        try Task.checkCancellation()
        let result = await runner.run(
            directory: cliURL.deletingLastPathComponent().path,
            executable: cliURL.path,
            arguments: arguments,
            timeout: 30
        )
        try Task.checkCancellation()
        guard result.executionError == nil, !result.timedOut, result.exitStatus == 0 else {
            if let diagnostics = result.stderr, !diagnostics.isEmpty {
                hostSettingsLogger.error("Bundled local-tmux CLI failed: \(diagnostics, privacy: .private)")
            }
            throw LocalTmuxSettingsActionError.commandFailed
        }
        return Data((result.stdout ?? "").utf8)
    }

    // MARK: - Right sidebar tabs

    func rightSidebarTabs() -> [RightSidebarTabSettingsItem] {
        Self.rightSidebarTabItems()
    }

    @discardableResult
    func setRightSidebarTabVisible(id: String, visible: Bool) -> Bool {
        guard let mode = RightSidebarMode(rawValue: id) else { return false }
        return RightSidebarTabPreferences.setHidden(!visible, mode: mode)
    }

    func moveRightSidebarTab(id: String, offset: Int) {
        guard let mode = RightSidebarMode(rawValue: id) else { return }
        RightSidebarTabPreferences.move(mode, offset: offset)
    }

    func rightSidebarTabsUpdates() -> AsyncStream<[RightSidebarTabSettingsItem]> {
        AsyncStream { continuation in
            let (signals, signalContinuation) = AsyncStream<Void>.makeStream(
                bufferingPolicy: .bufferingNewest(1)
            )
            // Shortcut rebinds change the displayed digit labels, so both
            // notifications refresh the card. Tab-preference mutations post
            // both; the newest-1 buffer coalesces the pair into one refresh.
            let observers = [
                RightSidebarTabPreferences.didChangeNotification,
                KeyboardShortcutSettings.didChangeNotification,
            ].map { name in
                SettingsObserverToken(
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: nil,
                        queue: nil
                    ) { _ in
                        signalContinuation.yield(())
                    }
                )
            }
            let drainTask = Task { @MainActor in
                continuation.yield(Self.rightSidebarTabItems())
                for await _ in signals {
                    if Task.isCancelled { break }
                    continuation.yield(Self.rightSidebarTabItems())
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                drainTask.cancel()
                signalContinuation.finish()
                observers.forEach { $0.remove() }
            }
        }
    }

    private static func rightSidebarTabItems() -> [RightSidebarTabSettingsItem] {
        let available = RightSidebarMode.availableModes()
        let hidden = RightSidebarTabPreferences.hiddenModes()
        return RightSidebarTabPreferences.orderedModes()
            .filter(available.contains)
            .map { mode in
                let shortcut = mode.shortcutAction.map { KeyboardShortcutSettings.shortcut(for: $0) }
                    ?? .unbound
                return RightSidebarTabSettingsItem(
                    id: mode.rawValue,
                    title: mode.label,
                    symbolName: mode.symbolName,
                    isVisible: !hidden.contains(mode),
                    shortcutLabel: shortcut.isUnbound ? "" : shortcut.displayString
                )
            }
    }

    func restartApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    func socketControlConfigurationDidChange() {
        AppDelegate.shared?.reconcileSocketListenerConfiguration(
            source: "settings.automation.socketControlMode.commit"
        )
    }

    func openBrowserImportFlow() {
        browserDataImportCoordinator.presentImportDialog()
    }

    func requestNotificationAuthorization() {
        TerminalNotificationStore.shared.requestAuthorizationFromSettings()
    }

    func openTerminalConfigWindow() {
        NSApp.activate(ignoringOtherApps: true)

        // Legacy opened the dedicated config window via the SwiftUI
        // `openWindow(id: ConfigSettingsView.windowID)` environment. The
        // settings package can't reach that environment, so the host opens
        // the same `ConfigSettingsView` directly. Reuse the existing window
        // (identifier set by `ConfigSettingsView.configureWindow`) when one
        // is already open so repeated presses focus instead of duplicate.
        if let existing = existingConfigWindow() {
            existing.makeKeyAndOrderFront(nil)
            existing.orderFrontRegardless()
            return
        }

        let appearanceMode = UserDefaults.standard.string(forKey: AppearanceSettings.appearanceModeKey)
        let root = ConfigSettingsView()
            .breeFontMagnificationEnvironment()
            .breeAppearanceColorScheme(appearanceMode, followsSurfaces: true)
        let hostingController = NSHostingController(rootView: root)

        let window = NSWindow(contentViewController: hostingController)
        window.title = String(localized: "settings.config.windowTitle", defaultValue: "Config")
        window.identifier = NSUserInterfaceItemIdentifier(configWindowIdentifier)
        window.isReleasedWhenClosed = false
        BreeSurfaceAppearance.follow(window)
        window.setContentSize(NSSize(width: 980, height: 680))
        window.center()
        configWindow = window
        configWindowCloseObserver = WindowCloseObserver(window: window) { [weak self] in
            self?.releaseConfigWindow($0)
        }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func customizeWorkspaceLayouts() {
        guard let appDelegate = AppDelegate.shared else {
            SidebarWorkspaceGroupConfigOpener.openBreeConfigInEditor()
            return
        }
        appDelegate.openWorkspaceLayoutsCustomization()
    }

    func setMenuBarOnly(_ enabled: Bool) -> Bool {
        MenuBarOnlySettings.setEnabled(enabled)
        return true
    }

    private func existingConfigWindow() -> NSWindow? {
        if let configWindow, configWindow.isVisible || configWindow.isMiniaturized {
            return configWindow
        }
        return NSApp.windows.first {
            $0.identifier?.rawValue == configWindowIdentifier && ($0.isVisible || $0.isMiniaturized)
        }
    }

    private func releaseConfigWindow(_ window: NSWindow) {
        guard configWindow === window else { return }
        configWindowCloseObserver = nil
        window.contentView = nil
        window.contentViewController = nil
        configWindow = nil
    }

    func previewNotificationSound(value: String, customFilePath: String) {
        notificationSoundPreviewTask?.cancel()
        let task = Task { @MainActor [weak self] in
            _ = await NotificationSoundSettings.previewSound(
                value: value,
                customFilePath: customFilePath
            )
            guard !Task.isCancelled else { return }
            self?.notificationSoundPreviewTask = nil
        }
        notificationSoundPreviewTask = task
    }

    func browserHistoryEntryCount() -> Int? {
        guard BrowserHistoryStore.shared.isLoaded else { return nil }
        return BrowserHistoryStore.shared.entries.count
    }

    func sidebarFontSize() -> SettingsFontSize {
        // Reads the in-memory cache (kept current by config reloads) rather than
        // forcing a synchronous disk read on the main actor when Settings opens.
        SettingsFontSize(
            points: Double(GhosttyConfig.loadForBree().sidebarFontSize),
            minimum: BreeGhosttyConfigSettingEditor.minSidebarFontSize,
            maximum: BreeGhosttyConfigSettingEditor.maxSidebarFontSize,
            defaultValue: BreeGhosttyConfigSettingEditor.defaultSidebarFontSize
        )
    }

    func setSidebarFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: BreeGhosttyConfigSettingEditor.sidebarFontSizeKey,
            points: BreeGhosttyConfigSettingEditor().clampedSidebarFontSize(points),
            reloadSource: "settings.sidebar.fontSize"
        )
    }

    func surfaceTabBarFontSize() -> SettingsFontSize {
        // See ``sidebarFontSize()`` — uses the cached config to avoid main-actor disk I/O.
        SettingsFontSize(
            points: Double(GhosttyConfig.loadForBree().surfaceTabBarFontSize),
            minimum: BreeGhosttyConfigSettingEditor.minSurfaceTabBarFontSize,
            maximum: BreeGhosttyConfigSettingEditor.maxSurfaceTabBarFontSize,
            defaultValue: BreeGhosttyConfigSettingEditor.defaultSurfaceTabBarFontSize
        )
    }

    func setSurfaceTabBarFontSize(_ points: Double) async -> Bool {
        await persistFontSize(
            key: BreeGhosttyConfigSettingEditor.surfaceTabBarFontSizeKey,
            points: BreeGhosttyConfigSettingEditor().clampedSurfaceTabBarFontSize(points),
            reloadSource: "settings.terminal.tabBarFontSize"
        )
    }

    func formattedFontSize(_ points: Double) -> String {
        BreeGhosttyConfigSettingEditor().formattedFontSize(points)
    }

    func terminalGhosttyOptions() async -> GhosttyTerminalOptionsSnapshot {
        await Task.detached(priority: .userInitiated) {
            let resolved = GhosttyConfig.resolvedDirectiveValues(forKeys: GhosttyTerminalOptions.configKeys)
            let environment = ConfigSourceEnvironment.live()
            var sourcePaths: [GhosttyTerminalOptionKey: String] = [:]
            for (key, path) in resolved.lastSourcePaths {
                guard let optionKey = GhosttyTerminalOptionKey(rawValue: key) else { continue }
                sourcePaths[optionKey] = environment.abbreviatedPath(for: URL(fileURLWithPath: path))
            }
            return GhosttyTerminalOptionsSnapshot(
                options: GhosttyTerminalOptions(directives: resolved.values),
                sourcePaths: sourcePaths
            )
        }.value
    }

    func applyTerminalGhosttyOption(_ change: GhosttyTerminalOptionChange) async -> Bool {
        let key = change.key.rawValue
        guard await fontConfigWriter.write(key: key, values: change.configValues) else {
            hostSettingsLogger.warning("failed to persist \(key, privacy: .public)")
            return false
        }
        GhosttyApp.shared.reloadConfiguration(source: "settings.terminal.ghosttyOption")
        return true
    }

    func terminalColorSnapshot() async -> GhosttyTerminalColorSnapshot {
        await Task.detached(priority: .userInitiated) {
            let config = GhosttyConfig.loadForBree(useCache: false)
            func hex(_ color: NSColor) -> String { color.hexString().lowercased() }
            var effective: [GhosttyTerminalColorSlot: String] = [
                .background: hex(config.backgroundColor),
                .foreground: hex(config.foregroundColor),
                .cursor: hex(config.cursorColor),
                .selectionBackground: hex(config.selectionBackground),
                .selectionForeground: hex(config.selectionForeground),
            ]
            for index in GhosttyTerminalColorSlot.paletteRange {
                if let color = config.palette[index] { effective[.palette(index)] = hex(color) }
            }
            let breeConfigPath = ConfigSourceEnvironment.live().breeConfigURL.path
            let overrides = GhosttyConfig.resolvedDirectiveValues(
                forKeys: Set(GhosttyTerminalColorSlot.configKeys),
                configPaths: [breeConfigPath]
            ).values
            return GhosttyTerminalColorSnapshot(
                effective: GhosttyTerminalColors(hexBySlot: effective),
                overrides: GhosttyTerminalColors(directives: overrides)
            )
        }.value
    }

    func setTerminalColorOverrides(_ overrides: GhosttyTerminalColors) async -> Bool {
        for key in GhosttyTerminalColorSlot.configKeys {
            guard await fontConfigWriter.write(key: key, values: overrides.configValues(forKey: key)) else {
                hostSettingsLogger.warning("failed to persist \(key, privacy: .public)")
                return false
            }
        }
        GhosttyApp.shared.reloadConfiguration(source: "settings.terminal.colorOverrides")
        return true
    }

    /// Writes a clamped font-size value to bree's editable Ghostty config and
    /// triggers a live reload so open windows re-render at the new size.
    ///
    /// The disk write runs on the serial ``fontConfigWriter`` actor so the main
    /// actor is never blocked on file I/O during a slider drag or Reset tap, and
    /// rapid successive saves persist in submission order (last value wins). The
    /// reload then resumes on the main actor.
    ///
    /// - Returns: `true` on success, `false` if the write failed (a generic
    ///   warning is logged here; the Settings UI surfaces a save-failed message).
    private func persistFontSize(key: String, points: Double, reloadSource: String) async -> Bool {
        let formatted = BreeGhosttyConfigSettingEditor().formattedFontSize(points)
        guard await fontConfigWriter.write(key: key, value: formatted) else {
            hostSettingsLogger.warning("failed to persist \(key, privacy: .public)")
            return false
        }
        GhosttyApp.shared.reloadConfiguration(source: reloadSource)
        return true
    }

}

/// Wraps the opaque observer returned by `NotificationCenter.addObserver` so the
/// `@Sendable` stream-termination closure can hold it for removal. Objective-C
/// doesn't model `Sendable`; the token is immutable and only hands the opaque
/// observer back to NotificationCenter's thread-safe removal API. BreeSettings
/// has an identical internal token, which isn't `public`, so it's duplicated.
final class SettingsObserverToken: @unchecked Sendable {
    private let token: NSObjectProtocol

    init(_ token: NSObjectProtocol) {
        self.token = token
    }

    func remove() {
        NotificationCenter.default.removeObserver(token)
    }
}

/// Serializes bree Ghostty config writes from Settings (font sizes and the
/// Terminal section's Ghostty option rows) so rapid
/// successive saves apply in submission order instead of racing.
///
/// The Settings sliders fire a save on every release and Reset tap. Routed
/// through this single actor, the writes run one-at-a-time in arrival order —
/// each write is a full overwrite of the key, so the most recently submitted
/// value is always the one left on disk. The work runs off the main actor.
private actor FontConfigWriter {
    /// Writes a single bree-editable Ghostty config setting to disk.
    ///
    /// - Parameters:
    ///   - key: The Ghostty config key to write (e.g. `sidebar-font-size`).
    ///   - value: The already-formatted value to persist.
    /// - Returns: `true` if the write succeeded, `false` otherwise.
    func write(key: String, value: String) -> Bool {
        do {
            try ConfigSourceEnvironment.live().writeBreeConfigSetting(key: key, value: value)
            return true
        } catch {
            return false
        }
    }

    /// Writes one `key = value` line per value, replacing every existing
    /// assignment to `key` (for list keys such as `font-family`).
    func write(key: String, values: [String]) -> Bool {
        do {
            try ConfigSourceEnvironment.live().writeBreeConfigSetting(key: key, values: values)
            return true
        } catch {
            return false
        }
    }
}

private extension UserDefaults {
    /// KVO-observable accessor for the `appIconMode` defaults key.
    ///
    /// `UserDefaults` is KVO-compliant for any key accessed through a
    /// matching `@objc dynamic` property whose name equals the key, which
    /// lets ``HostSettingsActions`` observe App Icon changes the settings
    /// package writes via `@AppStorage`. The property name must stay equal
    /// to ``AppIconSettings/modeKey`` (`"appIconMode"`).
    @objc dynamic var appIconMode: String? {
        string(forKey: "appIconMode")
    }
}
