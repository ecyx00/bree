import Foundation
import BreeCore
import BreeFoundation
#if canImport(Security)
import Security
#endif

extension SessionRemoteWorkspaceSnapshot {
    func workspaceConfiguration(
        localSocketPath: String? = nil,
        allowPersistentPTYRestore: Bool = true,
        preserveSSHOptions: Bool = false,
        agentSocketPath overrideAgentSocketPath: String? = nil
    ) -> WorkspaceRemoteConfiguration? {
        let normalizedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedDestination.isEmpty,
              !normalizedDestination.isOptionLikeSSHDestination else { return nil }
        let normalizedManagedCloudVMID = WorkspaceRemoteConfiguration.normalizedOptionalValue(managedCloudVMID)
        if transport == .websocket {
            guard let normalizedManagedCloudVMID else { return nil }
            return WorkspaceRemoteConfiguration(
                transport: .websocket,
                terminalTransport: .ssh,
                destination: normalizedDestination,
                port: nil,
                identityFile: nil,
                sshOptions: [],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: WorkspaceRemoteConfiguration.normalizedOptionalValue(localSocketPath),
                managedCloudVMID: normalizedManagedCloudVMID,
                terminalStartupCommand: Self.defaultFreestyleSSHAttachCommand(vmID: normalizedManagedCloudVMID),
                agentSocketPath: nil,
                daemonWebSocketEndpoint: nil,
                preserveAfterTerminalExit: true,
                persistentDaemonSlot: Self.defaultFreestylePersistentDaemonSlot,
                skipDaemonBootstrap: true
            )
        }
        guard transport == .ssh else { return nil }
        let normalizedPort = port.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }

        if let configuration = tuiSSHConfiguration(agentSocketPath: overrideAgentSocketPath) { return configuration }
        if let configuration = legacyTmuxSSHConfiguration(agentSocketPath: overrideAgentSocketPath) { return configuration }
        if skipDaemonBootstrap != true, (terminalTransport ?? .ssh) == .ssh,
           preserveAfterTerminalExit == true {
            // Preserve the old descriptor for recovery, but never resume its daemon
            // or start a replacement workload under a different session owner.
            var configuration = WorkspaceRemoteConfiguration(destination: normalizedDestination,
                port: normalizedPort, identityFile: identityFile, sshOptions: sshOptions,
                localProxyPort: nil, relayPort: nil, relayID: nil, relayToken: nil,
                localSocketPath: nil, terminalStartupCommand: nil, preserveAfterTerminalExit: true)
            configuration.restoredSSHSession = self
            return configuration
        }

        let normalizedPersistentDaemonSlot = WorkspaceRemoteConfiguration.normalizedPersistentDaemonSlot(persistentDaemonSlot)
        let normalizedLocalSocketPath = WorkspaceRemoteConfiguration.normalizedOptionalValue(localSocketPath)
        let normalizedRelayPort = relayPort.flatMap { port in
            (1...65535).contains(port) ? port : nil
        }
        let preservedOptions = preserveSSHOptions
            ? WorkspaceRemoteConfiguration.trimmedSSHOptions(sshOptions)
            : Self.normalizedSSHOptions(sshOptions)
        let optionsWithRestoreControlDefaults = SSHPTYAttachStartupCommandBuilder.sshOptionsWithRestoreControlDefaults(
            preservedOptions,
            relayPort: normalizedRelayPort
        )
        let fallbackSSHOptions = preserveSSHOptions
            ? Self.normalizedSSHOptions(preservedOptions)
            : preservedOptions
        let managedCloudVMID = normalizedManagedCloudVMID
            ?? Self.legacyDefaultFreestyleVMID(destination: normalizedDestination, skipDaemonBootstrap: skipDaemonBootstrap)
        let defaultFreestyleVMID = skipDaemonBootstrap == true ? managedCloudVMID : nil
        let requestedTerminalTransport = terminalTransport ?? .ssh
        let restoredTerminalTransport: WorkspaceRemoteTerminalTransport = requestedTerminalTransport
            .isSupportedForRemoteConfiguration(
                managementTransport: .ssh,
                skipDaemonBootstrap: skipDaemonBootstrap == true
            )
            ? requestedTerminalTransport
            : .ssh
        let restoredTerminalProfile: WorkspaceRemoteTerminalProfile = defaultFreestyleVMID == nil
            ? (terminalProfile ?? .shell)
            : .shell
        let effectivePersistentDaemonSlot = normalizedPersistentDaemonSlot
            ?? (defaultFreestyleVMID == nil ? nil : Self.defaultFreestylePersistentDaemonSlot)
        let preservePTYSession =
            restoredTerminalTransport == .ssh &&
            allowPersistentPTYRestore &&
            preserveAfterTerminalExit == true &&
            skipDaemonBootstrap != true &&
            effectivePersistentDaemonSlot != nil &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil &&
            SSHPTYAttachStartupCommandBuilder.sshOptionsSupportReusableForegroundAuth(optionsWithRestoreControlDefaults)
        let restoreMoshRelayNamespace =
            restoredTerminalTransport == .mosh &&
            skipDaemonBootstrap != true &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil
        let restoreOrdinarySSHRelayNamespace =
            restoredTerminalTransport == .ssh &&
            !preservePTYSession &&
            skipDaemonBootstrap != true &&
            normalizedLocalSocketPath != nil &&
            normalizedRelayPort != nil
        let restoreRelayNamespace =
            preservePTYSession ||
            restoreMoshRelayNamespace ||
            restoreOrdinarySSHRelayNamespace
        let restoreDefaultFreestyleSSHD = defaultFreestyleVMID != nil
        let restoredSSHOptions = preservePTYSession ? optionsWithRestoreControlDefaults : fallbackSSHOptions
        let foregroundAuthToken = preservePTYSession ? UUID().uuidString.lowercased() : nil
        let foregroundAuth = foregroundAuthToken.map {
            SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: normalizedDestination,
                port: normalizedPort,
                identityFile: WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile),
                sshOptions: restoredSSHOptions,
                token: $0
            )
        }
        let restoredRelayID = restoreRelayNamespace
            ? UUID().uuidString.lowercased()
            : nil
        let restoredRelayToken = restoreRelayNamespace
            ? Self.restoreRelayTokenHex()
            : nil
        let restoredRemoteShellCommand = preservePTYSession
            ? normalizedRelayPort.map {
                SSHPTYAttachStartupCommandBuilder.restoredRemoteShellCommand(
                    relayPort: $0,
                    configuredRemoteCommand: configuredRemoteCommand
                )
            }
            : nil
        return WorkspaceRemoteConfiguration(
            transport: transport,
            terminalTransport: restoredTerminalTransport,
            terminalProfile: restoredTerminalProfile,
            destination: normalizedDestination,
            port: normalizedPort,
            identityFile: WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile),
            sshOptions: restoredSSHOptions,
            localProxyPort: nil,
            relayPort: restoreRelayNamespace ? normalizedRelayPort : nil,
            relayID: restoredRelayID,
            relayToken: restoredRelayToken,
            localSocketPath: restoreRelayNamespace ? normalizedLocalSocketPath : nil,
            managedCloudVMID: managedCloudVMID,
            terminalStartupCommand: {
                if preservePTYSession {
                    return SSHPTYAttachStartupCommandBuilder.command(
                        foregroundAuth: foregroundAuth,
                        remoteCommand: restoredRemoteShellCommand,
                        // Restored panels get explicit require-existing attach commands with their
                        // persisted session IDs; this workspace default is for new panes.
                        requireExisting: false
                    )
                }
                if let defaultFreestyleVMID {
                    return Self.defaultFreestyleSSHAttachCommand(vmID: defaultFreestyleVMID)
                }
                let fallbackCommand = sshReconnectCommand(
                    destination: normalizedDestination,
                    port: normalizedPort,
                    sshOptions: restoredSSHOptions,
                    terminalProfile: restoredTerminalProfile,
                    configuredRemoteCommand: configuredRemoteCommand
                )
                if restoreOrdinarySSHRelayNamespace,
                   let remoteRelayPort = normalizedRelayPort {
                    return lifecycleAwareSSHReconnectCommand(
                        destination: normalizedDestination,
                        port: normalizedPort,
                        sshOptions: restoredSSHOptions,
                        terminalProfile: restoredTerminalProfile,
                        configuredRemoteCommand: configuredRemoteCommand,
                        remoteRelayPort: remoteRelayPort
                    )
                }
                guard restoredTerminalTransport == .mosh else {
                    return fallbackCommand
                }
                let sshFallbackCommand: String
                if restoreMoshRelayNamespace,
                   let remoteRelayPort = normalizedRelayPort {
                    sshFallbackCommand = lifecycleAwareSSHReconnectCommand(
                        destination: normalizedDestination,
                        port: normalizedPort,
                        sshOptions: restoredSSHOptions,
                        terminalProfile: restoredTerminalProfile,
                        configuredRemoteCommand: configuredRemoteCommand,
                        remoteRelayPort: remoteRelayPort
                    )
                } else {
                    sshFallbackCommand = fallbackCommand
                }
                return moshReconnectCommand(
                    destination: normalizedDestination,
                    port: normalizedPort,
                    sshOptions: restoredSSHOptions,
                    terminalProfile: restoredTerminalProfile,
                    remoteRelayPort: restoreMoshRelayNamespace ? normalizedRelayPort : nil,
                    sshFallbackCommand: sshFallbackCommand
                )
            }(),
            configuredRemoteCommand: configuredRemoteCommand,
            foregroundAuthToken: foregroundAuthToken,
            agentSocketPath: WorkspaceRemoteConfiguration.resolvedAgentSocketPath(
                sshOptions: restoredSSHOptions,
                explicitAgentSocketPath: overrideAgentSocketPath
            ),
            daemonWebSocketEndpoint: nil,
            preserveAfterTerminalExit: preservePTYSession || restoreDefaultFreestyleSSHD,
            persistentDaemonSlot: (preservePTYSession || restoreDefaultFreestyleSSHD) ? effectivePersistentDaemonSlot : nil,
            skipDaemonBootstrap: skipDaemonBootstrap == true
        )
    }

    private static func restoreRelayTokenHex() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
#if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
#endif
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private func sshReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String]? = nil,
        terminalProfile: WorkspaceRemoteTerminalProfile = .shell,
        configuredRemoteCommand: String? = nil
    ) -> String {
        let normalizedOptions = reconnectSSHOptions ?? Self.normalizedSSHOptions(sshOptions)
        let remoteCommandArguments = Self.restoredRemoteCommandArguments(
            terminalProfile: terminalProfile,
            configuredRemoteCommand: configuredRemoteCommand
        )
        let invocationOptions = remoteCommandArguments.isEmpty
            ? normalizedOptions
            : Self.removingRemoteCommand(from: normalizedOptions)
        var arguments = sshBootstrapArguments(
            port: normalizedPort,
            sshOptions: invocationOptions
        )
        if !Self.hasSSHOptionKey(normalizedOptions, key: "RequestTTY") {
            arguments.append("-tt")
        }
        if !remoteCommandArguments.isEmpty {
            arguments = [arguments[0]]
                + SSHHostConfiguredRemoteCommand().overrideArguments
                + arguments.dropFirst()
        }
        arguments.append(normalizedDestination)
        if let remoteCommand = Self.openSSHRemoteCommand(from: remoteCommandArguments) {
            // OpenSSH flattens argv after the destination and the remote login
            // shell parses that string again. Keep the whole remote invocation
            // in one locally quoted argv element so its inner quoting survives.
            arguments.append(remoteCommand)
        }
        return arguments.map(Self.shellQuote).joined(separator: " ")
    }

    private func lifecycleAwareSSHReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String],
        terminalProfile: WorkspaceRemoteTerminalProfile,
        configuredRemoteCommand: String?,
        remoteRelayPort: Int
    ) -> String {
        let invocationSSHOptions = Self.removingRemoteCommand(from: reconnectSSHOptions)
        let sshArguments = sshBootstrapArguments(
            port: normalizedPort,
            sshOptions: invocationSSHOptions
        )
        let sessionSSHArguments = [sshArguments[0]]
            + SSHHostConfiguredRemoteCommand().overrideArguments
            + sshArguments.dropFirst()
        let remoteBootstrapScript = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: remoteRelayPort,
            shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
            configuredRemoteCommand: configuredRemoteCommand,
            bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder
                .bundledShellIntegrationScript(named: "bree-zsh-integration.zsh"),
            bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder
                .bundledShellIntegrationScript(named: "bree-bash-integration.bash"),
            bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder
                .bundledShellIntegrationScript(named: "fish/config.fish"),
            terminalProfile: terminalProfile
        )
        let failureMessage = String(
            localized: "cli.ssh.restore.lifecycleUnavailable",
            defaultValue: "[Bree] SSH restore stopped because Bree could not register the connection lifecycle. Reopen this remote workspace to reconnect."
        )
        let failureScript = "printf '%s\\n' \(Self.shellQuote(failureMessage)) >&2; exit 1"
        guard let staging = RemoteBootstrapStagingCommandBuilder(
            installerSSHArguments: sessionSSHArguments,
            destination: normalizedDestination,
            remoteRelayPort: remoteRelayPort,
            bootstrapScript: remoteBootstrapScript
        ) else {
            return "/bin/sh -c \(Self.shellQuote(failureScript))"
        }

        var terminalArguments = sessionSSHArguments
        if !Self.hasSSHOptionKey(invocationSSHOptions, key: "RequestTTY") {
            terminalArguments.append("-tt")
        }
        terminalArguments.append(normalizedDestination)
        let sshInvocation = terminalArguments
            .map(Self.shellQuote)
            .joined(separator: " ")
        let remoteCommandScript = [
            restoredSSHTerminalConnectedShellScript(
                remoteRelayPort: remoteRelayPort
            ),
            staging.remoteExecutionShellScript,
        ].joined(separator: "\n")
        // OpenSSH gives the command after the destination to the account's
        // configured login shell. Keep fish/csh/nushell from parsing the
        // POSIX lifecycle/relay script by making /bin/sh the command's
        // outermost interpreter explicitly.
        let remoteCommandTemplate = "/bin/sh -c \(Self.shellQuote(remoteCommandScript))"
        let script = ([
            "bree_restore_fail() { \(failureScript); }",
            "bree_restore_cli=\"${BREE_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$bree_restore_cli\" ] || [ ! -x \"$bree_restore_cli\" ]; then bree_restore_cli=\"$(command -v bree 2>/dev/null || true)\"; fi",
            "if [ -z \"$bree_restore_cli\" ] || [ -z \"${BREE_SOCKET_PATH:-}\" ] || [ -z \"${BREE_WORKSPACE_ID:-}\" ] || [ -z \"${BREE_SURFACE_ID:-}\" ] || [ -z \"${BREE_TERMINAL_LIFECYCLE_ID:-}\" ]; then bree_restore_fail; fi",
            "bree_restore_register_attempt() { bree_restore_launch_payload=\"{\\\"workspace_id\\\":\\\"$BREE_WORKSPACE_ID\\\",\\\"surface_id\\\":\\\"$BREE_SURFACE_ID\\\",\\\"terminal_lifecycle_id\\\":\\\"$BREE_TERMINAL_LIFECYCLE_ID\\\",\\\"attempt_id\\\":\\\"$BREE_SSH_ATTEMPT_ID\\\"}\"; BREE_CLI_RESPONSE_TIMEOUT_SEC=2 \"$bree_restore_cli\" --socket \"$BREE_SOCKET_PATH\" rpc workspace.remote.terminal_session_launching \"$bree_restore_launch_payload\" >/dev/null 2>&1; }",
        ] + SSHPTYAttachRetryScriptBuilder().launchRegistrationRetryLines(functionPrefix: "bree_restore") + [
            "bree_restore_begin_attempt",
            "bree_restore_launch_status=$?",
            "if [ \"$bree_restore_launch_status\" -ne 0 ]; then bree_restore_fail; fi",
            staging.preparationShellScript,
            "if [ \"$bree_remote_install_status\" -ne 0 ]; then bree_restore_fail; fi",
            "unset bree_remote_install_status",
            "bree_restore_workspace_id=\"${BREE_WORKSPACE_ID:-}\"",
            "bree_restore_surface_id=\"${BREE_SURFACE_ID:-}\"",
            "bree_restore_terminal_lifecycle_id=\"${BREE_TERMINAL_LIFECYCLE_ID:-}\"",
            "bree_restore_attempt_id=\"${BREE_SSH_ATTEMPT_ID:-}\"",
            "bree_restore_remote_command_template=\(Self.shellQuote(remoteCommandTemplate))",
            "bree_restore_remote_command=\"$(printf '%s' \"$bree_restore_remote_command_template\" | sed \"s/__BREE_WORKSPACE_ID__/$bree_restore_workspace_id/g; s/__BREE_SURFACE_ID__/$bree_restore_surface_id/g; s/__BREE_TERMINAL_LIFECYCLE_ID__/$bree_restore_terminal_lifecycle_id/g; s/__BREE_SSH_ATTEMPT_ID__/$bree_restore_attempt_id/g\")\"",
            "exec \(sshInvocation) \"$bree_restore_remote_command\"",
        ]).joined(separator: "\n")
        return "/bin/sh -c \(Self.shellQuote(script))"
    }

    private func restoredSSHTerminalConnectedShellScript(
        remoteRelayPort: Int
    ) -> String {
        [
            "if [ -n \"__BREE_SURFACE_ID__\" ]; then",
            "  bree_restore_terminal_connected='{\"workspace_id\":\"__BREE_WORKSPACE_ID__\",\"surface_id\":\"__BREE_SURFACE_ID__\",\"relay_port\":\(remoteRelayPort),\"terminal_lifecycle_id\":\"__BREE_TERMINAL_LIFECYCLE_ID__\",\"attempt_id\":\"__BREE_SSH_ATTEMPT_ID__\"}'",
            "  bree_restore_terminal_connected_acknowledged=0",
            "  bree_restore_terminal_connected_retry=0",
            "  while [ \"$bree_restore_terminal_connected_retry\" -lt 4 ]; do",
            "    bree_restore_remote_cli=\"$HOME/\(BreeIdentity.remoteDotDirectoryName)/bin/bree\"",
            "    if [ ! -x \"$bree_restore_remote_cli\" ]; then bree_restore_remote_cli=\"$(command -v bree 2>/dev/null || true)\"; fi",
            "    if [ -n \"$bree_restore_remote_cli\" ] && env -u BREE_SOCKET BREE_CLI_RESPONSE_TIMEOUT_SEC=0.5 BREE_SOCKET_PATH=\"127.0.0.1:\(remoteRelayPort)\" \"$bree_restore_remote_cli\" rpc workspace.remote.terminal_session_connected \"$bree_restore_terminal_connected\" >/dev/null 2>&1; then",
            "      bree_restore_terminal_connected_acknowledged=1",
            "      break",
            "    fi",
            "    bree_restore_terminal_connected_retry=$((bree_restore_terminal_connected_retry + 1))",
            "    if [ \"$bree_restore_terminal_connected_retry\" -lt 4 ]; then /bin/sleep 0.1; fi",
            "  done",
            "  if [ \"$bree_restore_terminal_connected_acknowledged\" -ne 1 ]; then exit 255; fi",
            "fi",
            "unset bree_restore_remote_cli bree_restore_terminal_connected bree_restore_terminal_connected_acknowledged bree_restore_terminal_connected_retry",
        ].joined(separator: "\n")
    }

    private func moshReconnectCommand(
        destination normalizedDestination: String,
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String],
        terminalProfile: WorkspaceRemoteTerminalProfile,
        remoteRelayPort: Int?,
        sshFallbackCommand: String
    ) -> String {
        // Mosh owns terminal allocation; the separately built SSH fallback
        // still receives the durable RequestTTY option.
        let invocationSSHOptions = SSHAgentSocketResolver().moshManagementOptions(
            from: Self.removingRemoteCommand(from: reconnectSSHOptions)
        )
        let sshArguments = sshBootstrapArguments(
            port: normalizedPort,
            sshOptions: invocationSSHOptions
        )
        let moshSSHArguments = [sshArguments[0]]
            + SSHHostConfiguredRemoteCommand().overrideArguments
            + sshArguments.dropFirst()
        var remoteCommandArguments = Self.restoredRemoteCommandArguments(
            terminalProfile: terminalProfile,
            configuredRemoteCommand: configuredRemoteCommand
        )
        var preparationShellScript: String?
        if let remoteRelayPort {
            let remoteBootstrapScript = RemoteInteractiveShellBootstrapBuilder.script(
                remoteRelayPort: remoteRelayPort,
                shellFeatures: RemoteInteractiveShellBootstrapBuilder.shellFeatures(),
                configuredRemoteCommand: configuredRemoteCommand,
                bundledZshIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "bree-zsh-integration.zsh"
                ),
                bundledBashIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "bree-bash-integration.bash"
                ),
                bundledFishIntegration: RemoteInteractiveShellBootstrapBuilder.bundledShellIntegrationScript(
                    named: "fish/config.fish"
                ),
                terminalProfile: terminalProfile
            )
            if let staging = RemoteBootstrapStagingCommandBuilder(
                installerSSHArguments: moshSSHArguments,
                destination: normalizedDestination,
                remoteRelayPort: remoteRelayPort,
                bootstrapScript: remoteBootstrapScript
            ) {
                remoteCommandArguments = staging.remoteExecutionCommandArguments
                preparationShellScript = staging.preparationShellScript
            }
        }
        return MoshTerminalCommandBuilder(
            capabilityProbeSSHArguments: moshSSHArguments,
            sessionSSHArguments: moshSSHArguments,
            destination: normalizedDestination,
            remoteCommandArguments: remoteCommandArguments,
            remoteRelayPort: remoteRelayPort,
            preparationShellScript: preparationShellScript,
            sshFallbackCommand: sshFallbackCommand,
            localMoshMissingMessage: String(
                localized: "cli.ssh.mosh.localMissing",
                defaultValue: "[Bree] Mosh is not installed locally; continuing over SSH."
            ),
            localMoshUnsupportedMessage: String(
                localized: "cli.ssh.mosh.localUnsupported",
                defaultValue: "[Bree] The local Mosh client lacks required SSH integration; continuing over SSH."
            ),
            remoteMoshMissingMessage: String(
                localized: "cli.ssh.mosh.remoteMissing",
                defaultValue: "[Bree] mosh-server is not installed on the remote host; continuing over SSH."
            ),
            remoteMoshProbeFailedMessage: String(
                localized: "cli.ssh.mosh.probeFailed",
                defaultValue: "[Bree] Could not verify remote Mosh support; continuing over SSH."
            ),
            remoteBootstrapInstallFailedMessage: String(
                localized: "cli.ssh.mosh.bootstrapInstallFailed",
                defaultValue: "[Bree] Remote bootstrap install failed; continuing over SSH."
            ),
            remoteMoshAddressFallbackMessage: String(
                localized: "cli.ssh.mosh.addressFallback",
                defaultValue: "[Bree] Remote SSH advertised an unusable address; resolving the Mosh address through the SSH connection."
            )
        ).command()
    }

    /// Returns the single durable program intent used by both Mosh and its
    /// direct SSH fallback. A terminal profile remains explicit and wins over
    /// the host-configured interactive command captured in the snapshot.
    private static func restoredRemoteCommandArguments(
        terminalProfile: WorkspaceRemoteTerminalProfile,
        configuredRemoteCommand: String?
    ) -> [String] {
        if !terminalProfile.remoteCommandArguments.isEmpty {
            return terminalProfile.remoteCommandArguments
        }
        guard terminalProfile.kind == .shell,
              let configuredRemoteCommand = configuredRemoteCommand?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !configuredRemoteCommand.isEmpty else {
            return []
        }
        return [
            "/bin/sh",
            "-c",
            #"exec "${SHELL:-/bin/sh}" -c "$1""#,
            "bree-remote-command",
            configuredRemoteCommand,
        ]
    }

    private static func openSSHRemoteCommand(from arguments: [String]) -> String? {
        guard !arguments.isEmpty else { return nil }
        return arguments.map(Self.shellQuote).joined(separator: " ")
    }

    private func sshBootstrapArguments(
        port normalizedPort: Int?,
        sshOptions reconnectSSHOptions: [String]? = nil
    ) -> [String] {
        var arguments = ["/usr/bin/ssh"]
        if let normalizedPort {
            arguments += ["-p", String(normalizedPort)]
        }
        if let identityFile = WorkspaceRemoteConfiguration.normalizedIdentityPath(identityFile) {
            arguments += ["-i", identityFile]
        }
        let normalizedOptions = reconnectSSHOptions ?? Self.normalizedSSHOptions(sshOptions)
        for option in normalizedOptions {
            arguments += ["-o", option]
        }
        return arguments
    }

    private static func normalizedSSHOptions(_ options: [String]) -> [String] {
        WorkspaceRemoteConfiguration.durableSSHOptions(options)
    }

    private static func hasSSHOptionKey(_ options: [String], key: String) -> Bool {
        WorkspaceRemoteConfiguration.hasSSHOptionKey(options, key: key)
    }

    private static func removingRemoteCommand(from options: [String]) -> [String] {
        SSHAgentSocketResolver().removingOptions(named: "RemoteCommand", from: options)
    }

    private static let defaultFreestylePersistentDaemonSlot = "bree-default-freestyle-sshd-v1"

    private static func legacyDefaultFreestyleVMID(destination: String, skipDaemonBootstrap: Bool?) -> String? {
        guard skipDaemonBootstrap == true else { return nil }
        let pattern = #"^([A-Za-z0-9._-]+)\+bree@vm-ssh\.freestyle\.sh$"#
        guard let match = destination.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let matched = String(destination[match])
        guard let plusRange = matched.range(of: "+bree@vm-ssh.freestyle.sh") else {
            return nil
        }
        return String(matched[..<plusRange.lowerBound])
    }

    private static func defaultFreestyleSSHAttachCommand(vmID: String) -> String {
        let lines = [
            "bree_freestyle_cli=\"${BREE_BUNDLED_CLI_PATH:-}\"",
            "if [ -z \"$bree_freestyle_cli\" ] || [ ! -x \"$bree_freestyle_cli\" ]; then bree_freestyle_cli=\"$(command -v bree 2>/dev/null || true)\"; fi",
            "if [ -z \"$bree_freestyle_cli\" ]; then printf '%s\\n' '[Bree] bundled CLI not found for Cloud VM SSH attach.' >&2; exit 127; fi",
            "BREE_SSH_RECONNECT_LIMIT=\"${BREE_SSH_RECONNECT_LIMIT:-\(SSHReconnectBudget().maximumLimit)}\"",
            "BREE_SSH_RECONNECT_DELAY_SECONDS=\"${BREE_SSH_RECONNECT_DELAY_SECONDS:-2}\"",
            "BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT=\"${BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT:-$BREE_SSH_RECONNECT_LIMIT}\"",
            "BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS=\"${BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS:-$BREE_SSH_RECONNECT_DELAY_SECONDS}\"",
            "export BREE_SSH_RECONNECT_LIMIT BREE_SSH_RECONNECT_DELAY_SECONDS",
            "export BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_LIMIT BREE_DEFAULT_FREESTYLE_ATTACH_RETRY_DELAY_SECONDS",
            "bree_freestyle_attach() {",
            "  if [ -n \"${BREE_SOCKET_PATH:-}\" ]; then",
            "    \"$bree_freestyle_cli\" --socket \"$BREE_SOCKET_PATH\" vm-pty-attach --id \(shellQuote(vmID)) --default-freestyle-sshd",
            "  else",
            "    \"$bree_freestyle_cli\" vm-pty-attach --id \(shellQuote(vmID)) --default-freestyle-sshd",
            "  fi",
            "}",
            "bree_freestyle_retry=0",
            "while :; do",
            "  if [ \"$bree_freestyle_retry\" -gt 0 ]; then",
            "    export BREE_CLOUD_RECONNECT_ATTEMPT=\"$bree_freestyle_retry\"",
            "  else",
            "    unset BREE_CLOUD_RECONNECT_ATTEMPT",
            "  fi",
            "  bree_freestyle_attach",
            "  bree_freestyle_status=$?",
            "  case \"$bree_freestyle_status\" in 254|255) ;; *) exit \"$bree_freestyle_status\" ;; esac",
            "  if [ \"$bree_freestyle_retry\" -ge \"$BREE_SSH_RECONNECT_LIMIT\" ]; then exit \"$bree_freestyle_status\"; fi",
            "  bree_freestyle_retry=$((bree_freestyle_retry + 1))",
            "  sleep \"$BREE_SSH_RECONNECT_DELAY_SECONDS\"",
            "done",
        ]
        return "/bin/sh -c \(shellQuote(lines.joined(separator: "\n")))"
    }

    private static func shellQuote(_ value: String) -> String {
        value.posixShellWord
    }
}
