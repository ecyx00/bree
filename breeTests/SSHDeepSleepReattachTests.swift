import AppKit
import BreeCore
import BreeFoundation
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite(.serialized)
struct SSHDeepSleepReattachTests {
    private struct ProcessRunResult {
        let status: Int32
        let stderr: String
        let timedOut: Bool
    }

    @MainActor
    @Test func persistentAttachFailurePreservesReattachIdentityAndConnectionOwner() throws {
        let workspace = Workspace()
        let panel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to bree-macmini via shared local proxy 127.0.0.1:64007",
            target: "bree-macmini"
        )
        let expectedSessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)

        #expect(workspace.remoteConnectionState == .connected)
        #expect(workspace.isRemoteTerminalSurface(panel.id))
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        let terminalSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels.first { $0.id == panel.id }
        )
        #expect(terminalSnapshot.terminal?.remotePTYSessionID == expectedSessionID)
    }

    @MainActor
    @Test func connectedTransitionReattachesEveryPersistentPlaceholder() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        let first = try #require(workspace.focusedTerminalPanel)
        let second = try #require(workspace.newTerminalSplit(
            from: first.id,
            orientation: .horizontal,
            focus: false
        ))
        let originalSurfaces = [first.id: first.surface, second.id: second.surface]
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: first.id)
        workspace.markPersistentRemotePTYAttachFailed(surfaceId: second.id)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds == Set([first.id, second.id]))

        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to bree-macmini via shared local proxy 127.0.0.1:64007",
            target: "bree-macmini"
        )

        #expect(workspace.remoteDisconnectPlaceholderPanelIds.isEmpty)
        for panelID in [first.id, second.id] {
            let reattached = try #require(workspace.terminalPanel(for: panelID))
            #expect(reattached.surface !== originalSurfaces[panelID])
            let command = try #require(reattached.surface.initialCommand)
            #expect(command.contains("--require-existing"))
            #expect(command.contains(Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panelID)))
            #expect(workspace.isRemoteTerminalSurface(panelID))
        }
    }

    @MainActor
    @Test(arguments: [false, true])
    func contextMenuReconnectReattachesFailedPersistentPTY(pendingChildExit: Bool) throws {
        let previousAppDelegate = AppDelegate.shared
        let appDelegate = AppDelegate()
        let tabManager = TabManager()
        let windowID = appDelegate.registerMainWindowContextForTesting(tabManager: tabManager)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowID)
            AppDelegate.shared = previousAppDelegate
        }

        let workspace = try #require(tabManager.selectedWorkspace)
        let panel = try #require(workspace.focusedTerminalPanel)
        let originalSurface = panel.surface
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to bree-macmini via shared local proxy 127.0.0.1:64007",
            target: "bree-macmini"
        )
        if pendingChildExit {
            workspace.pendingRemoteTerminalChildExitSurfaceIds.insert(panel.id)
        } else {
            workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        }

        let menu = NSMenu()
        panel.hostedView.surfaceView.appendReconnectRemotePaneMenuItem(to: menu)
        let reconnectItem = try #require(menu.items.last)
        let action = try #require(reconnectItem.action)
        #expect(NSApplication.shared.sendAction(action, to: reconnectItem.target, from: reconnectItem))

        let reattached = try #require(workspace.terminalPanel(for: panel.id))
        #expect(reattached.surface !== originalSurface)
        let command = try #require(reattached.surface.initialCommand)
        #expect(command.contains("--require-existing"))
        #expect(command.contains(Workspace.defaultSSHPTYSessionID(workspaceId: workspace.id, panelId: panel.id)))
        #expect(!workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(!workspace.pendingRemoteTerminalChildExitSurfaceIds.contains(panel.id))
    }

    @MainActor
    @Test func confirmedSSHPTYExitRestartsWithInheritedCustomIdentity() throws {
        let workspace = Workspace()
        let foregroundAuthToken = "foreground-auth-restored-session"
        let configuredRemoteCommand = #"cd "/srv/project dir" && exec fish"#
        let configuration = Self.persistentConfiguration(
            foregroundAuthToken: foregroundAuthToken,
            configuredRemoteCommand: configuredRemoteCommand
        )
        let initialPanel = try #require(workspace.focusedTerminalPanel)
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let customSessionID = "ssh-restored-custom-session"
        let panel = try #require(workspace.newTerminalSplit(
            from: initialPanel.id,
            orientation: .horizontal,
            focus: false,
            remotePTYSessionID: customSessionID
        ))
        let resumeCommand = "printf resumed-session"
        #expect(workspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                command: resumeCommand,
                source: "process-detected",
                launchFlavor: .persistentSSH(SurfaceResumeRemoteContext(
                    workspaceID: workspace.id,
                    surfaceID: panel.id,
                    persistentPTYSessionID: customSessionID
                ))
            ),
            panelId: panel.id
        ))
        let originalSurface = panel.surface
        #expect(panel.surface.respawnAdditionalEnvironment["BREE_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)
        let ended = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: customSessionID)
        #expect(ended.clearedRemotePTYSession)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == nil)

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)
        workspace.applyRemoteConnectionStateUpdate(
            .connected,
            detail: "Connected to bree-macmini via shared local proxy 127.0.0.1:64007",
            target: "bree-macmini"
        )

        #expect(workspace.terminalPanel(for: panel.id)?.surface === originalSurface)
        #expect(workspace.remoteDisconnectPlaceholderPanelIds.contains(panel.id))
        #expect(workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(panel.id))

        #expect(workspace.reconnectRemoteConnection(surfaceId: panel.id))
        let restarted = try #require(workspace.terminalPanel(for: panel.id))
        #expect(restarted.surface !== originalSurface)
        let command = try #require(restarted.surface.initialCommand)
        #expect(command.contains(customSessionID))
        #expect(!command.contains("--require-existing"))
        #expect(command.contains("workspace.remote.foreground_auth_ready"))
        #expect(!command.contains(foregroundAuthToken))
        #expect(command.contains(SSHForegroundAuthenticationLaunch(token: foregroundAuthToken).commandMarker))
        #expect(command.contains("ssh-session-end"))
        let commandRange = try #require(
            command.range(of: #"--command-b64 [A-Za-z0-9+/=]+"#, options: .regularExpression)
        )
        let encodedCommand = String(command[commandRange])
            .split(separator: " ", maxSplits: 1)
            .last
            .map(String.init)
        let commandData = try #require(encodedCommand.flatMap { Data(base64Encoded: $0) })
        let decodedCommand = try #require(String(data: commandData, encoding: .utf8))
        // A persistent-SSH resume binding is no longer replayed into the restarted
        // PTY, so the restart runs the configured remote command like any shell.
        #expect(decodedCommand.contains(configuredRemoteCommand))
        #expect(!decodedCommand.contains(Data((resumeCommand + "\n").utf8).base64EncodedString()))
        #expect(decodedCommand.contains("64007"))
        #expect(restarted.surface.respawnAdditionalEnvironment["BREE_REMOTE_PTY_SESSION_ID"] == customSessionID)
        #expect(workspace.remotePTYSessionIDsByPanelId[panel.id] == customSessionID)
        #expect(!workspace.endedPersistentRemotePTYAttachSurfaceIds.contains(panel.id))
        let restartedSnapshot = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(restartedSnapshot.isRemoteTerminal == true)
        #expect(restartedSnapshot.remotePTYSessionID == customSessionID)
    }

    @MainActor
    @Test func confirmedRemotePTYExitIsNotSnapshottedAsLive() throws {
        let workspace = Workspace()
        workspace.configureRemoteConnection(Self.persistentConfiguration(), autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )
        _ = workspace.markRemotePTYAttachEnded(surfaceId: panel.id, sessionID: sessionID)

        workspace.markPersistentRemotePTYAttachFailed(surfaceId: panel.id)

        let terminal = try #require(
            workspace.sessionSnapshot(includeScrollback: false).panels
                .first { $0.id == panel.id }?.terminal
        )
        #expect(terminal.isRemoteTerminal == false)
        #expect(terminal.remotePTYSessionID == nil)
    }

    @MainActor
    @Test func confirmedPersistentPTYExitClearsConnectedPresentation() throws {
        let workspace = Workspace()
        let configuration = Self.persistentConfiguration()
        workspace.configureRemoteConnection(configuration, autoConnect: false)
        let panel = try #require(workspace.focusedTerminalPanel)
        let sessionID = Workspace.defaultSSHPTYSessionID(
            workspaceId: workspace.id,
            panelId: panel.id
        )
        #expect(
            workspace.markRemoteTerminalSessionConnected(
                surfaceId: panel.id,
                authority: .persistentTransport(try #require(workspace.remoteConfiguration).proxyBrokerTransportKey),
                terminalLifecycleID: panel.surface.terminalLifecycleId
            )
        )
        #expect(workspace.hasAuthoritativelyConnectedRemoteTerminal)
        #expect(workspace.remoteConnectionState == .connected)

        let ended = workspace.markRemotePTYAttachEnded(
            surfaceId: panel.id,
            sessionID: sessionID
        )

        #expect(ended.clearedRemotePTYSession)
        #expect(ended.untrackedRemoteTerminal)
        #expect(!workspace.hasAuthoritativelyConnectedRemoteTerminal)
        #expect(workspace.remoteConnectionState != .connected)
    }

    /// The attach wrapper resolves its retry budget before the loop starts, so
    /// the fallback, a well-formed operator budget, and the ceiling are all
    /// provable without paying for a full budget of attach attempts.
    @Test(arguments: [
        (nil, SSHReconnectBudget().fallbackLimit),
        ("2O", SSHReconnectBudget().fallbackLimit),
        ("0", SSHReconnectBudget().fallbackLimit),
        ("021", 21),
        ("21", 21),
        (String(SSHReconnectBudget().maximumLimit + 1), SSHReconnectBudget().maximumLimit),
    ] as [(String?, Int)])
    func foregroundAuthenticatedAttachResolvesRetryBudgetBeforeTheLoop(
        reconnectLimit: String?,
        expectedLimit: Int
    ) throws {
        let attachLines = SSHPTYAttachRetryScriptBuilder().lines(
            command: "bree_ssh_attach_attempt",
            reauthenticates: true
        )
        let budgetResolution = Array(attachLines.prefix { $0 != "while :; do" })
        #expect(
            budgetResolution.count < attachLines.count,
            "the attach retry loop marker moved; the budget probe would run the whole loop"
        )
        // The generated startup command embeds these same lines, so the probe
        // cannot drift away from what a real pane runs.
        let startupCommand = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: Self.foregroundAuth()
        )
        let clampLine = try #require(budgetResolution.first { $0.contains("BREE_SSH_RECONNECT_LIMIT") })
        #expect(startupCommand.contains(clampLine))

        var environment = ProcessInfo.processInfo.environment
        environment["BREE_SSH_RECONNECT_LIMIT"] = reconnectLimit
        let result = Self.runProcessCapturingStandardOutput(
            command: (budgetResolution + ["printf '%s' \"$bree_ssh_attach_reconnect_limit\""])
                .joined(separator: "\n"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        // Absent, malformed, and zero budgets fall back to the finite default;
        // a well-formed budget is honored up to the shared ceiling (#13959).
        #expect(result.stdout == String(expectedLimit), Comment(rawValue: result.stderr))
    }

    @Test(arguments: [(Optional("4"), Int32(255), "5", 4)])
    func foregroundAuthenticatedAttachUsesConfiguredRetryBudget(
        reconnectLimit: String?, expectedStatus: Int32, expectedAttempts: String, expectedSleepCount: Int
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-persistent-backoff-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("bree")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attach-attempts.txt")
        let authAttemptFile = root.appendingPathComponent("auth-attempts.txt")
        let sleepLog = root.appendingPathComponent("sleep-delays.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "case \" $* \" in", "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${BREE_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))", "    printf '%s' \"$count\" > \"${BREE_TEST_ATTEMPT_FILE}\"",
            "    if [ \"$count\" -lt 24 ]; then exit 255; fi", "    exit 253", "    ;;",
            "  *) exit 0 ;;", "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${BREE_TEST_SLEEP_LOG}\"",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${BREE_TEST_AUTH_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${BREE_TEST_AUTH_ATTEMPT_FILE}\"",
            "exit 0",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSSH.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["BREE_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["BREE_SOCKET_PATH"] = "/tmp/bree-debug-test.sock"
        environment["BREE_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["BREE_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["BREE_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["BREE_TEST_AUTH_ATTEMPT_FILE"] = authAttemptFile.path
        environment["BREE_TEST_SLEEP_LOG"] = sleepLog.path
        environment["BREE_SSH_RECONNECT_LIMIT"] = reconnectLimit
        environment["BREE_SSH_RECONNECT_DELAY_SECONDS"] = "2"
        environment["BREE_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "5"

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(
                sessionID: "ssh-test-session",
                foregroundAuth: Self.foregroundAuth()
            ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path),
            environment: environment,
            // Every attach attempt spawns uuidgen, the fake ssh, bree and
            // sleep, so the full budget costs ~4.5 s on an idle runner and
            // more under shard load. The deadline only bounds a hang; it
            // scales with the attempts the case expects to run.
            timeout: max(5, Double(expectedSleepCount + 1) * 2)
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == expectedStatus, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: authAttemptFile, encoding: .utf8) == expectedAttempts)
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == expectedAttempts)
        let delays = try String(contentsOf: sleepLog, encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(delays.count == expectedSleepCount)
        #expect(Array(delays.prefix(4)) == ["2", "4", "5", "5"])
        #expect(delays.last == "5")
    }

    @Test(arguments: [(nil, "0", "0"), ("100000", "0", "0"), (nil, "08", "09"), ("100000", "09", "08")])
    func invalidDelayIsClamped(reconnectLimit: String?, delay: String, maxDelay: String) throws {
        try Self.assertInvalidDelayIsClamped(reconnectLimit: reconnectLimit, delay: delay, maxDelay: maxDelay)
    }

    private static func assertInvalidDelayIsClamped(
        reconnectLimit: String?, delay: String, maxDelay: String
    ) throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-persistent-zero-delay-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("bree")
        let fakeSleep = root.appendingPathComponent("sleep")
        let attemptFile = root.appendingPathComponent("attach-attempts.txt")
        let sleepLog = root.appendingPathComponent("sleep-delays.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "case \" $* \" in", "  *\" ssh-pty-attach \"*)",
            "    count=$(cat \"${BREE_TEST_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "    count=$((count + 1))", "    printf '%s' \"$count\" > \"${BREE_TEST_ATTEMPT_FILE}\"",
            "    if [ \"$count\" -eq 1 ]; then exit 255; fi", "    exit 253", "    ;;",
            "  *) exit 0 ;;", "esac",
        ])
        try Self.writeShellFile(at: fakeSleep, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$1\" >> \"${BREE_TEST_SLEEP_LOG}\"",
        ])
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCLI.path)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeSleep.path)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["BREE_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["BREE_SOCKET_PATH"] = "/tmp/bree-debug-test.sock"
        environment["BREE_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["BREE_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["BREE_TEST_ATTEMPT_FILE"] = attemptFile.path
        environment["BREE_TEST_SLEEP_LOG"] = sleepLog.path
        environment["BREE_SSH_RECONNECT_DELAY_SECONDS"] = delay
        environment["BREE_SSH_RECONNECT_MAX_DELAY_SECONDS"] = maxDelay
        if let reconnectLimit {
            environment["BREE_SSH_RECONNECT_LIMIT"] = reconnectLimit
        }

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(sessionID: "ssh-test-session"),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 253, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: attemptFile, encoding: .utf8) == "2")
        #expect(try String(contentsOf: sleepLog, encoding: .utf8) == "2\n")
    }

    @Test func foregroundAuthenticationFailureDoesNotEnterAttachRetryLoop() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-foreground-auth-failure-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("bree")
        let fakeSSH = root.appendingPathComponent("ssh")
        let authAttemptFile = root.appendingPathComponent("auth-attempts.txt")
        let cliAttemptFile = root.appendingPathComponent("cli-attempts.txt")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try Self.writeShellFile(at: fakeCLI, lines: [
            "#!/bin/sh", "printf '%s\\n' \"$*\" >> \"${BREE_TEST_CLI_ATTEMPT_FILE}\"", "exit 0",
        ])
        try Self.writeShellFile(at: fakeSSH, lines: [
            "#!/bin/sh",
            "count=$(cat \"${BREE_TEST_AUTH_ATTEMPT_FILE}\" 2>/dev/null || printf 0)",
            "printf '%s' $((count + 1)) > \"${BREE_TEST_AUTH_ATTEMPT_FILE}\"",
            "printf '%s\\n' 'user@example.test: Permission denied (publickey,password).' >&2",
            "exit 255",
        ])
        for executable in [fakeCLI, fakeSSH] {
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
        environment["BREE_BUNDLED_CLI_PATH"] = fakeCLI.path
        environment["BREE_SOCKET_PATH"] = "/tmp/bree-debug-test.sock"
        environment["BREE_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
        environment["BREE_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
        environment["BREE_TEST_AUTH_ATTEMPT_FILE"] = authAttemptFile.path
        environment["BREE_TEST_CLI_ATTEMPT_FILE"] = cliAttemptFile.path

        let result = Self.runProcess(
            command: SSHPTYAttachStartupCommandBuilder.command(
                sessionID: "ssh-test-session",
                foregroundAuth: Self.foregroundAuth()
            ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path),
            environment: environment
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 255, Comment(rawValue: result.stderr))
        #expect(try String(contentsOf: authAttemptFile, encoding: .utf8) == "1")
        let cliAttempts = (try? String(contentsOf: cliAttemptFile, encoding: .utf8)) ?? ""
        #expect(!cliAttempts.contains("ssh-pty-attach"), "Failed foreground authentication must never start a PTY attach")
    }

    private static func foregroundAuth() -> SSHPTYAttachStartupCommandBuilder.ForegroundAuth {
        SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
            destination: "user@example.test", port: 22, identityFile: nil,
            sshOptions: ["ControlMaster=no", "ControlPath=none"], token: "test-auth-token"
        )
    }

    private static func persistentConfiguration(
        foregroundAuthToken: String? = nil,
        configuredRemoteCommand: String? = nil
    ) -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "bree-macmini", port: nil, identityFile: nil, sshOptions: [],
            localProxyPort: nil, relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/bree-debug-test.sock",
            terminalStartupCommand: SSHPTYAttachStartupCommandBuilder.command(requireExisting: false),
            configuredRemoteCommand: configuredRemoteCommand,
            foregroundAuthToken: foregroundAuthToken,
            preserveAfterTerminalExit: true, persistentDaemonSlot: "ssh-test"
        )
    }

    private static func writeShellFile(at url: URL, lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Runs a short shell probe and keeps its stdout, for scripts that report a
    /// resolved value instead of exercising a retry loop.
    private static func runProcessCapturingStandardOutput(
        command: String,
        environment: [String: String]
    ) -> (status: Int32, stdout: String, stderr: String, timedOut: Bool) {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return (-1, "", String(describing: error), false)
        }
        let timedOut = waitForProcessExit(process, timeout: 10) == .timedOut
        if timedOut {
            process.terminate()
            _ = waitForProcessExit(process, timeout: 1)
        }
        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, stdout, stderr, timedOut)
    }

    private static func runProcess(
        command: String,
        environment: [String: String],
        timeout: TimeInterval = 5
    ) -> ProcessRunResult {
        let process = Process()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrPipe
        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stderr: String(describing: error), timedOut: false)
        }
        let timedOut = waitForProcessExit(process, timeout: timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = waitForProcessExit(process, timeout: 1)
        }
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessRunResult(status: process.terminationStatus, stderr: stderr, timedOut: timedOut)
    }
}
