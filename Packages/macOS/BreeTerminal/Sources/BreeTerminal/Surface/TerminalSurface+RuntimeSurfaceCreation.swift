internal import AppKit
internal import Foundation
internal import GhosttyKit
internal import BreeFoundation
internal import BreeTerminalCore
internal import BREEAgentLaunch
internal import Darwin
#if DEBUG
internal import BREEDebugLog
#endif

// MARK: - Native runtime-surface creation/config assembly

extension TerminalSurface {
    @MainActor
    func createNativeRuntimeSurface(
        app: ghostty_app_t,
        for view: any TerminalSurfaceNativeViewing,
        scaleFactors: (x: CGFloat, y: CGFloat, layer: CGFloat),
        agentCommandShims: AgentCommandShimSet?,
        spawnPolicy: TerminalSurfaceSpawnPolicy
    ) -> (createdSurface: ghostty_surface_t?, runtimeInitialInput: String?) {
        let baseConfig = runtimeCreationConfigTemplate()
        var surfaceConfig = ghostty_surface_config_new()
        let magnificationPercent = globalFontMagnificationPercent()
        surfaceConfig.font_size = BreeSurfaceConfigTemplate.runtimeFontSize(
            fromBasePoints: baseConfig.fontSize,
            percent: magnificationPercent
        )
        surfaceConfig.wait_after_command = baseConfig.waitAfterCommand
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view as NSView).toOpaque()
        ))
        let rendererRealization = rendererRealization
        let callbackTarget = TerminalSurfaceCallbackTarget(surface: self)
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(
            surfaceHost: view,
            surfaceController: self,
            terminalLifecycleID: terminalLifecycleId,
            titleOverride: agentPanelTitle,
            rendererMailboxDidDrain: { surfaceID in
                Task { @MainActor in
                    rendererRealization.scheduleRendererPresentationRepair(surfaceID: surfaceID)
                }
            },
            rendererFramePresented: { _, token in
                Task { @MainActor in
                    callbackTarget.surface?.rendererFrameDidPresent(token: token)
                }
            },
            rendererFrameFailed: { _, token, status in
                Task { @MainActor in
                    callbackTarget.surface?.rendererFrameDidFail(token: token, status: status)
                }
            },
        ))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceConfig.renderer_event_cb = terminalRendererEventCallback
        invalidateRuntimeClipboardRequests(in: surfaceCallbackContext, completingNativeRequests: surface != nil)
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext
        surfaceConfig.scale_factor = scaleFactors.layer
        surfaceConfig.context = surfaceContext
        surfaceConfig.io_mode = ioMode.ghosttyMode
        if ioMode.usesManualIO {
            // MANUAL I/O: ghostty spawns no process; typed input is delivered
            // to our callback and output is injected through
            // ghostty_surface_process_output.
            manualIOContext?.release()
            let box = Unmanaged.passRetained(
                TerminalManualIOWriteBox(onWrite: manualInputHandler ?? { _ in })
            )
            manualIOContext = box
            surfaceConfig.io_write_cb = terminalManualIOWriteCallback
            surfaceConfig.io_write_userdata = box.toOpaque()
        }
#if DEBUG
        let templateFontText = String(format: "%.2f", baseConfig.fontSize)
        let runtimeFontText = String(format: "%.2f", surfaceConfig.font_size)
        logDebugEvent(
            "zoom.create surface=\(id.uuidString.prefix(5)) context=\(GhosttySurfaceRuntimeProbe.contextName(surfaceContext)) " +
            "templateFont=\(templateFontText) runtimeFont=\(runtimeFontText)"
        )
#endif
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }

        var env = baseConfig.environmentVariables

        var protectedStartupEnvironmentKeys: Set<String> = []
        Self.applyManagedTerminalIdentityEnvironment(
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        func setManagedEnvironmentValue(_ key: String, _ value: String) {
            env[key] = value
            protectedStartupEnvironmentKeys.insert(key)
        }

        func currentManagedPath() -> String {
            let inheritedPath = env["PATH"]
                ?? ProcessInfo.processInfo.environment["PATH"]
                ?? ""
            return BreePathEnvironment().components(from: inheritedPath).joined(separator: ":")
        }

        let sanitizedPath = currentManagedPath()
        if env["PATH"] != nil || !sanitizedPath.isEmpty {
            setManagedEnvironmentValue("PATH", sanitizedPath)
        }

        if let resolvedUserShell = engine.resolvedUserShell {
            setManagedEnvironmentValue("SHELL", resolvedUserShell)
            // login(1) resets SHELL to the passwd shell; `local-tmux enter` needs the resolved one.
            setManagedEnvironmentValue("BREE_USER_SHELL", resolvedUserShell)
        }

        let socketPath = spawnPolicyProvider.controlSocketPath()
        Self.applyManagedBreeContextEnvironment(
            Self.breeContextEnvironment(
                workspaceId: tabId,
                surfaceId: id,
                terminalLifecycleId: terminalLifecycleId,
                socketPath: socketPath
            ),
            to: &env,
            protectedKeys: &protectedStartupEnvironmentKeys
        )
        setManagedEnvironmentValue("BREE_SOCKET", "")
        if let inheritedClaudeConfigDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"],
           !inheritedClaudeConfigDir.isEmpty {
            env["CLAUDE_CONFIG_DIR"] = ClaudeConfigDirectoryPath.preferredPath(inheritedClaudeConfigDir)
        }
        if let bundledCLIURL = Bundle.main.resourceURL?.appendingPathComponent("bin/bree"),
           runtimeFilesystem.isExecutableFile(bundledCLIURL.path) {
            setManagedEnvironmentValue("BREE_BUNDLED_CLI_PATH", bundledCLIURL.path)
        }
        if let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty {
            setManagedEnvironmentValue("BREE_BUNDLE_ID", bundleId)
        }

        // Port range for this workspace is snapshotted once per app session.
        do {
            let startPort = sessionPortBase + portOrdinal * sessionPortRangeSize
            setManagedEnvironmentValue("BREE_PORT", String(startPort))
            setManagedEnvironmentValue("BREE_PORT_END", String(startPort + sessionPortRangeSize - 1))
            setManagedEnvironmentValue("BREE_PORT_RANGE", String(sessionPortRangeSize))
        }

        for (key, value) in spawnPolicy.socketAuthenticationEnvironment
            where !key.isEmpty && !value.isEmpty {
            setManagedEnvironmentValue(key, value)
        }
        setManagedEnvironmentValue(
            "BREE_CLAUDE_INTEGRATION_DISABLED",
            spawnPolicy.claudeHooksEnabled ? "0" : "1"
        )
        if !spawnPolicy.claudeHooksEnabled {
            setManagedEnvironmentValue("BREE_CLAUDE_HOOKS_DISABLED", "1")
        }
        // The codex wrapper shim is still installed (it stays on PATH so a
        // resumed codex routes through it), but when the Codex integration is
        // off the wrapper no-ops on this env var and injects no hooks, mirroring
        // the Claude toggle.
        if !spawnPolicy.codexHooksEnabled {
            setManagedEnvironmentValue("BREE_CODEX_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.piHooksEnabled {
            setManagedEnvironmentValue("BREE_PI_HOOKS_DISABLED", "1")
        }
        if let customClaudePath = spawnPolicy.customClaudePath {
            setManagedEnvironmentValue("BREE_CUSTOM_CLAUDE_PATH", customClaudePath)
        }
        setManagedEnvironmentValue(
            spawnPolicy.subagentNotificationEnvironmentKey,
            spawnPolicy.suppressSubagentNotifications ? "1" : "0"
        )
        if !spawnPolicy.cursorHooksEnabled {
            setManagedEnvironmentValue("BREE_CURSOR_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.geminiHooksEnabled {
            setManagedEnvironmentValue("BREE_GEMINI_HOOKS_DISABLED", "1")
        }
        if !spawnPolicy.kiroHooksEnabled {
            setManagedEnvironmentValue("BREE_KIRO_HOOKS_DISABLED", "1")
        }
        setManagedEnvironmentValue("BREE_KIRO_NOTIFICATION_LEVEL", spawnPolicy.kiroNotificationLevel)
        if !spawnPolicy.ampHooksEnabled {
            setManagedEnvironmentValue("BREE_AMP_HOOKS_DISABLED", "1")
        }

        if let cliBinURL = Bundle.main.resourceURL?.appendingPathComponent("bin") {
            let cliBinPath = cliBinURL.path
            let ghosttyCLIPath = cliBinURL.appendingPathComponent("ghostty").path
            if FileManager.default.isExecutableFile(atPath: ghosttyCLIPath) {
                setManagedEnvironmentValue("GHOSTTY_BIN", ghosttyCLIPath)
            }
            let currentPath = currentManagedPath()
            if !currentPath.split(separator: ":").contains(Substring(cliBinPath)) {
                setManagedEnvironmentValue(
                    "PATH",
                    Self.pathByPrependingUniqueDirectory(cliBinPath, to: currentPath)
                )
            }
        }

        if let agentCommandShims {
            setManagedEnvironmentValue("BREE_AGENT_COMMAND_SHIM_ROOT", agentCommandShims.directoryPath)
            for shim in agentCommandShims.shims {
                setManagedEnvironmentValue(shim.wrapperShimEnvironmentKey, shim.executablePath)
                setManagedEnvironmentValue(shim.wrapperShimRootEnvironmentKey, shim.directoryPath)
            }
            let currentPath = currentManagedPath()
            setManagedEnvironmentValue(
                "PATH",
                Self.pathByPrependingUniqueDirectory(agentCommandShims.directoryPath, to: currentPath)
            )
        }

        var managedShellPlan = TerminalManagedShellStartupPlan(command: nil, reportsPromptReadiness: false)
        var appliedShellIntegrationDirectory: String?
        if spawnPolicy.shellIntegrationEnabled,
           let integrationDir = Bundle.main.resourceURL?.appendingPathComponent("shell-integration").path,
           Self.shellIntegrationDirectoryExists(integrationDir) {
            appliedShellIntegrationDirectory = integrationDir
            setManagedEnvironmentValue("BREE_SHELL_INTEGRATION", "1")
            setManagedEnvironmentValue("BREE_SHELL_INTEGRATION_DIR", integrationDir)
            // zsh inline history suggestions (`terminal.inlineSuggestions`,
            // default on): the integration reads this once at startup.
            if UserDefaults.standard.object(forKey: "terminal.inlineSuggestions") as? Bool == false {
                setManagedEnvironmentValue("BREE_INLINE_SUGGESTIONS", "0")
            }
            // Warp-style clean grid: the shell integration blanks the prompt
            // and starts blocks at the bottom only when the docked shell
            // editor (`terminal.shellEditor`, default on) owns input.
            if UserDefaults.standard.object(forKey: "terminal.shellEditor") as? Bool ?? true {
                setManagedEnvironmentValue("BREE_SHELL_EDITOR", "1")
            }
            Self.applyManagedGitWatchEnvironment(
                watchGitStatusEnabled: spawnPolicy.watchGitStatusEnabled,
                to: &env,
                protectedKeys: &protectedStartupEnvironmentKeys
            )

            if let shell = engine.resolvedUserShell {
                managedShellPlan = Self.applyManagedShellStartupPlan(
                    shell: shell,
                    integrationDir: integrationDir,
                    userGhosttyShellIntegrationMode: engine.userGhosttyShellIntegrationMode,
                    to: &env,
                    protectedKeys: &protectedStartupEnvironmentKeys
                )
            }
        }
        env = Self.mergedStartupEnvironment(
            base: env,
            protectedKeys: protectedStartupEnvironmentKeys,
            additionalEnvironment: additionalEnvironment,
            initialEnvironmentOverrides: initialEnvironmentOverrides
        )
        let configuredInitialCommand = hasStartupRestoreAdmissionCommandOverride
            ? startupRestoreAdmissionCommandOverride
            : initialCommand
        spawnPolicyProvider.applyStartupCommandSecrets(
            to: &env,
            workspaceId: tabId,
            startupCommand: configuredInitialCommand
        )
        env["BREE_SOCKET"] = ""

        if !env.isEmpty {
            envVars.reserveCapacity(env.count)
            envStorage.reserveCapacity(env.count)
            for (key, value) in env {
                guard let keyPtr = strdup(key) else { continue }
                guard let valuePtr = strdup(value) else {
                    free(keyPtr)
                    continue
                }
                envStorage.append((keyPtr, valuePtr))
                envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
            }
        }

        let resolvedWorkingDirectory: String? = {
            if let workingDirectory, !workingDirectory.isEmpty {
                return workingDirectory
            }
            return baseConfig.workingDirectory
        }()
        let resolvedCommand = TerminalLaunchCommandPolicy().resolve(
            initialCommand: configuredInitialCommand,
            surfaceCommand: baseConfig.command,
            hasUserGhosttyCommand: engine.hasUserGhosttyCommand,
            managedShellCommand: managedShellPlan.command,
            resolvedShell: engine.resolvedUserShell
        )
        let runtimeInitialInput = nextRuntimeInitialInput
        let resolvedInitialInput: String? = {
            if let runtimeInitialInput, !runtimeInitialInput.isEmpty {
                return runtimeInitialInput
            }
            if suppressConfiguredInitialInput {
                return nil
            }
            if let initialInput, !initialInput.isEmpty {
                return initialInput
            }
            return baseConfig.initialInput
        }()
        // Admission holds startup input until the shell reports a prompt. A
        // process that cannot report one receives the input directly at spawn.
        let gatesStartupInputOnPrompt = startupRestoreAdmissionPhase != .unrestricted
            && TerminalShellPromptReadinessPolicy().reportsPromptReadiness(
                integrationDirectory: appliedShellIntegrationDirectory,
                resolvedCommand: resolvedCommand,
                hasUserGhosttyCommand: engine.hasUserGhosttyCommand,
                resolvedShell: engine.resolvedUserShell,
                managedShellCommand: managedShellPlan.command,
                environment: env,
                managedShellReportsPromptReadiness: managedShellPlan.reportsPromptReadiness
            )
        let createdSurface = withOptionalCString(resolvedCommand) { cCommand in
            surfaceConfig.command = cCommand
            return withOptionalCString(resolvedWorkingDirectory) { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                return withOptionalCString(
                    gatesStartupInputOnPrompt ? "" : resolvedInitialInput
                ) { cInitialInput in
                    surfaceConfig.initial_input = cInitialInput
                    return makeGhosttySurface(app: app, config: &surfaceConfig, envVars: &envVars)
                }
            }
        }
        if let createdSurface {
            if gatesStartupInputOnPrompt {
                startupInputGate.stage(resolvedInitialInput, generation: terminalLifecycleId)
            } else if startupRestoreAdmissionPhase != .unrestricted {
                // Direct delivery consumed this generation's input.
                startupInputGate.stage(nil, generation: terminalLifecycleId)
            }
            guard ghostty_surface_set_render_presented_callback(
                createdSurface,
                terminalRendererPresentedCallback,
                callbackContext.toOpaque()
            ), ghostty_surface_set_render_failed_callback(
                createdSurface,
                terminalRendererFailedCallback,
                callbackContext.toOpaque()
            ) else {
                ghostty_surface_free(createdSurface)
                return (createdSurface: nil, runtimeInitialInput: runtimeInitialInput)
            }
        }
        return (createdSurface, runtimeInitialInput)
    }

    private func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
        guard let value else {
            return body(nil)
        }
        return value.withCString(body)
    }

    private func makeGhosttySurface(
        app: ghostty_app_t,
        config surfaceConfig: inout ghostty_surface_config_s,
        envVars: inout [ghostty_env_var_s]
    ) -> ghostty_surface_t? {
        if envVars.isEmpty {
            return ghostty_surface_new(app, &surfaceConfig)
        }

        let envVarsCount = envVars.count
        return envVars.withUnsafeMutableBufferPointer { buffer in
            surfaceConfig.env_vars = buffer.baseAddress
            surfaceConfig.env_var_count = envVarsCount
            return ghostty_surface_new(app, &surfaceConfig)
        }
    }
}
