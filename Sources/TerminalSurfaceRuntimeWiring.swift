import AppKit
import Foundation
import BreeFoundation
import BreeTerminal
import BreeTerminalCore
import GhosttyKit
import BreeSettings
import struct BreeSettings.AgentIntegrationSettingsStore

// The app-side conformances and bridges injected into the BreeTerminal
// package through `GhosttyApp.terminalSurfaceRuntimeDependencies`. Each type
// here carries behavior verbatim from the legacy god-file reach-up it
// replaces; this file is intended composition-root residue.

// MARK: Engine

extension GhosttyApp: TerminalEngineHosting {
    var runtimeApp: ghostty_app_t? { app }
    var runtimeConfig: ghostty_config_t? { config }
    var terminalFontConfigurationRuntimePoints: Float32 {
        terminalFontConfigurationSnapshot()
            .configuredRuntimePoints
    }
    // `userGhosttyShellIntegrationMode` already matches the seam requirement.
}

// MARK: Views

/// Creates the concrete `GhosttyNSView` + `GhosttySurfaceScrollView` pair the
/// surface model historically constructed in its initializer.
struct TerminalSurfaceViewFactory: TerminalSurfaceViewProviding {
    let imageTransferPreparation: TerminalImageTransferPreparationService

    @MainActor
    func makeSurfaceViews(
        initialFrame: NSRect
    ) -> (surfaceView: any TerminalSurfaceNativeViewing, paneHost: any TerminalSurfacePaneHosting) {
        let view = GhosttyNSView(
            frame: initialFrame,
            imageTransferPreparation: imageTransferPreparation
        )
        return (view, GhosttySurfaceScrollView(surfaceView: view))
    }
}

// MARK: Spawn policy

/// Live settings/control-plane reads for spawn assembly (the legacy inline
/// reads of the integration-settings enums, `sidebarShellIntegration`,
/// `SidebarWorkspaceDetailDefaults`, and `TerminalController`'s socket path).
@MainActor
final class TerminalSurfaceSpawnPolicyBridge: TerminalSurfaceSpawnPolicyProviding {
    func currentSpawnPolicy() -> TerminalSurfaceSpawnPolicy {
        let integrations = AgentIntegrationSettingsStore(defaults: .standard)
        return TerminalSurfaceSpawnPolicy(
            socketAuthenticationEnvironment: TerminalController.shared.socketClientCapabilityEnvironment(),
            claudeHooksEnabled: integrations.claudeCodeHooksEnabled,
            codexHooksEnabled: integrations.codexHooksEnabled,
            customClaudePath: integrations.customClaudePath,
            subagentNotificationEnvironmentKey: AgentIntegrationSettingsStore.subagentSuppressionEnvironmentKey,
            suppressSubagentNotifications: integrations.suppressesSubagentNotifications,
            cursorHooksEnabled: integrations.cursorHooksEnabled,
            geminiHooksEnabled: integrations.geminiHooksEnabled,
            kiroHooksEnabled: integrations.kiroHooksEnabled,
            kiroNotificationLevel: integrations.kiroNotificationLevel.rawValue,
            ampHooksEnabled: integrations.ampHooksEnabled,
            shellIntegrationEnabled: UserDefaults.standard.object(forKey: "sidebarShellIntegration") as? Bool ?? true,
            watchGitStatusEnabled: SidebarWorkspaceDetailDefaults.watchGitStatusValue(defaults: .standard),
            piHooksEnabled: integrations.piHooksEnabled
        )
    }

    func controlSocketPath() -> String {
        TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
    }

    /// Hands the workspace's SSH foreground-auth token to an attach command
    /// built for that token. The command reads it from the environment, so it
    /// stays out of the process arguments. A command built for an earlier
    /// token does not get the current one, and its readiness report fails as
    /// it did when the token was part of the command.
    func applyStartupCommandSecrets(
        to environment: inout [String: String],
        workspaceId: UUID,
        startupCommand: String?
    ) {
        // The `bree ssh` first terminal starts before `workspace.remote.configure`
        // and runs a script file, so it relies on the token the CLI passed in
        // its initial environment. Leave that environment as it is.
        guard let startupCommand,
              startupCommand.contains(SSHForegroundAuthenticationLaunch.environmentKey),
              let token = AppDelegate.shared?.workspaceFor(tabId: workspaceId)?
                .remoteConfiguration?.foregroundAuthToken,
              !token.isEmpty else {
            return
        }
        let launch = SSHForegroundAuthenticationLaunch(token: token)
        if launch.isExpected(by: startupCommand) {
            // The workspace's current token replaces one replayed from an
            // earlier launch's initial environment.
            environment.merge(launch.environment) { _, workspaceToken in workspaceToken }
        }
    }
}

// MARK: Terminal output tee

/// Installs the libghostty PTY tee and keys drop state by surface id.
final class TerminalOutputByteTeeBridge: TerminalByteTeeBinding {
    private let scrollbackCheckpointActivity: TerminalScrollbackCheckpointActivity

    init(scrollbackCheckpointActivity: TerminalScrollbackCheckpointActivity) {
        self.scrollbackCheckpointActivity = scrollbackCheckpointActivity
        TerminalOutputStreamingMonitor.shared.attach(scrollbackCheckpointActivity)
    }

    /// Wraps the retained tee userdata; `release()` runs exactly where the
    /// surface released the legacy `Unmanaged` context.
    /// @unchecked Sendable: the Unmanaged box is exclusively owned by this
    /// lease from install until release, mirroring the teardown-request
    /// transport.
    final class Lease: TerminalByteTeeLease, @unchecked Sendable {
        private let context: Unmanaged<TerminalOutputTeeContext>
        private let scrollbackCheckpointActivity: TerminalScrollbackCheckpointActivity

        init(
            context: Unmanaged<TerminalOutputTeeContext>,
            scrollbackCheckpointActivity: TerminalScrollbackCheckpointActivity
        ) {
            self.context = context
            self.scrollbackCheckpointActivity = scrollbackCheckpointActivity
        }

        func release() {
            let teeContext = context.takeUnretainedValue()
            scrollbackCheckpointActivity.unregister(
                surfaceID: teeContext.surfaceID,
                registration: teeContext.scrollbackCheckpointFlags
            )
            context.release()
        }
    }

    @MainActor
    func installTee(
        on surface: ghostty_surface_t,
        workspaceID: UUID,
        surfaceID: UUID
    ) -> any TerminalByteTeeLease {
        let teeContext = Unmanaged.passRetained(TerminalOutputTeeContext(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            agentDefinitions: BreeTaskManagerCodingAgentDefinition.builtIns,
            promptDetectionGate: TerminalPromptDetectionGateController.shared.gate(for: surfaceID),
            scrollbackCheckpointFlags: scrollbackCheckpointActivity
                .register(surfaceID: surfaceID)
        ))
        ghostty_surface_set_pty_tee_cb(
            surface,
            breeTerminalOutputTeeCallback,
            teeContext.toOpaque()
        )
        return Lease(context: teeContext, scrollbackCheckpointActivity: scrollbackCheckpointActivity)
    }

    @MainActor
    func dropSurface(surfaceID: UUID) {
        TerminalPredictionCenter.shared.unregister(surfaceID: surfaceID)
        TerminalPromptDetectionGateController.shared.dropSurface(surfaceID)
    }
}

// MARK: Renderer reclamation

extension RendererRealizationController: TerminalRendererRealizationScheduling {}

// MARK: Agent hibernation

/// The app-owned safety tracker injected into the terminal input path.
@MainActor
final class TerminalAgentHibernationRecorder: AgentHibernationRecording {
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {
        guard AgentHibernationTrackingGate.isEnabled() else { return }
        AgentHibernationController.shared.recordTerminalInput(
            workspaceId: workspaceId,
            panelId: panelId
        )
    }
}

// MARK: Filesystem

extension TerminalSurfaceRuntimeFilesystem {
    static func live(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TerminalSurfaceRuntimeFilesystem {
        let hermesProfileAliasCatalog = HermesProfileAliasCatalog(
            wrapperDirectoryURL: homeDirectory
                .appendingPathComponent(".local/bin", isDirectory: true)
        )
        // Per-surface command shims are part of the lifetime of their pane.
        // Keep them beside bree's durable state so macOS's periodic `$TMPDIR`
        // cleanup cannot remove a live pane's Claude entry from `PATH`.
        let agentCommandShimRootDirectory = homeDirectory
            .appendingPathComponent(BreeIdentity.current.dotDirectoryName, isDirectory: true)
        return TerminalSurfaceRuntimeFilesystem(
            agentCommandShimRootDirectory: agentCommandShimRootDirectory,
            installAgentCommandShims: {
                let fileManager = FileManager.default
                return await TerminalSurface.installAgentCommandShimsIfPossible(
                    wrapperDirectoryURL: $0,
                    surfaceId: $1,
                    rootDirectory: $2,
                    enabledCommands: $3,
                    hermesProfileAliasCatalog: hermesProfileAliasCatalog,
                    fileManager: fileManager
                )
            },
            isExecutableFile: { FileManager.default.isExecutableFile(atPath: $0) }
        )
    }
}

// MARK: Construction

extension TerminalSurface {
    /// The legacy app-target initializer signature, forwarding to the package
    /// initializer with the process-wide collaborator bundle. Keeps every
    /// existing call site byte-identical while construction is injected
    /// (dissolves when a real composition root constructs surfaces).
    @MainActor
    convenience init(
        id: UUID = UUID(),
        tabId: UUID,
        context: ghostty_surface_context_e,
        configTemplate: BreeSurfaceConfigTemplate?,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        ioMode: TerminalSurfaceIOMode = .exec,
        isRemoteTerminal: Bool = false,
        allowsRemoteClipboardWrites: Bool = false,
        manualInputHandler: (@Sendable (TerminalManualInput) -> Void)? = nil,
        manualInputKeyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)? = nil,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate,
        preparePaneHost: @Sendable @MainActor (any TerminalSurfacePaneHosting) -> Void = { _ in }
    ) {
        var initialCommand = initialCommand
        var tmuxStartCommand = tmuxStartCommand
        if let plan = PersistentLocalShell.plan(
            id: id,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            isRemoteTerminal: isRemoteTerminal,
            ioMode: ioMode
        ) {
            initialCommand = plan.initialCommand
            tmuxStartCommand = plan.tmuxStart
        }
        self.init(
            id: id,
            tabId: tabId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement,
            ioMode: ioMode,
            isRemoteTerminal: isRemoteTerminal,
            allowsRemoteClipboardWrites: allowsRemoteClipboardWrites,
            manualInputHandler: manualInputHandler,
            manualInputKeyNameResolver: manualInputKeyNameResolver,
            runtimeSpawnPolicy: runtimeSpawnPolicy,
            preparePaneHost: preparePaneHost,
            dependencies: GhosttyApp.terminalSurfaceRuntimeDependencies
        )
    }
}

// MARK: Persistent local shells

/// Turns a new plain local shell into an `auto-<panelId>` tmux session when
/// `terminal.keepShellsRunningAfterQuit` is on. Restore and respawn raise
/// `suppressDepth` so existing terminals are never converted.
enum PersistentLocalShell {
    @MainActor static var suppressDepth = 0

    static func sessionName(_ id: UUID) -> String { "auto-\(id.uuidString.lowercased())" }

    @MainActor
    static func plan(
        id: UUID,
        workingDirectory: String?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        initialInput: String?,
        isRemoteTerminal: Bool,
        ioMode: TerminalSurfaceIOMode
    ) -> (initialCommand: String, tmuxStart: String)? {
        guard suppressDepth == 0,
              UserDefaults.standard.bool(forKey: "terminal.keepShellsRunningAfterQuit"),
              initialCommand == nil, tmuxStartCommand == nil, initialInput == nil,
              !isRemoteTerminal, ioMode == .exec,
              let cli = CLIForwardingLaunchRouter.bundledCLIURL() else { return nil }
        // The CLI creates the session inside the new PTY (`enter`), so nothing runs on the main actor.
        let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let command = "/usr/bin/env TMUX= \(quoted) local-tmux enter \(sessionName(id))"
        return (command, command)
    }

    /// Kills the session of a surface the user closed. Fire and forget.
    static func closeSession(panelId: UUID) {
        guard let cli = CLIForwardingLaunchRouter.bundledCLIURL() else { return }
        let process = Process()
        process.executableURL = cli
        process.arguments = ["local-tmux", "close", sessionName(panelId)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
