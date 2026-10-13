import Foundation
import Testing
import BreeTerminal

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

private let fishExecutablePath = [
    "/opt/homebrew/bin/fish",
    "/usr/local/bin/fish",
    "/usr/bin/fish",
    "/bin/fish",
].first { FileManager.default.isExecutableFile(atPath: $0) }

@Suite(.serialized)
struct FishShellIntegrationTests {
    private struct ProcessRunResult {
        let status: Int32
        let stdout: String
        let stderr: String
        let timedOut: Bool
    }

    @Test
    func testApplyManagedFishStartupEnvironmentPreservesUserConfigHome() {
        var environment = ["XDG_CONFIG_HOME": "/Users/example/.config"]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedFishStartupEnvironment(
            integrationDir: "/Applications/bree.app/Contents/Resources/shell-integration",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["XDG_CONFIG_HOME"], "/Users/example/.config")
        expectEqual(environment["BREE_FISH_INTEGRATION_FILE"], "/Applications/bree.app/Contents/Resources/shell-integration/fish/config.fish")
        expectEqual(environment["BREE_FISH_USER_CONFIG_ALREADY_LOADED"], "1")
        expectFalse(protectedKeys.contains("XDG_CONFIG_HOME"))
        expectTrue(protectedKeys.contains("BREE_FISH_INTEGRATION_FILE"))
        expectTrue(protectedKeys.contains("BREE_FISH_USER_CONFIG_ALREADY_LOADED"))
    }

    @Test
    func testApplyManagedFishStartupEnvironmentAvoidsRecursiveConfigHome() {
        var environment = ["XDG_CONFIG_HOME": "/Applications/bree.app/Contents/Resources/shell-integration/"]
        var protectedKeys: Set<String> = []

        TerminalSurface.applyManagedFishStartupEnvironment(
            integrationDir: "/Applications/bree.app/Contents/Resources/shell-integration",
            to: &environment,
            protectedKeys: &protectedKeys
        )

        expectEqual(environment["XDG_CONFIG_HOME"], "/Applications/bree.app/Contents/Resources/shell-integration/")
        expectEqual(environment["BREE_FISH_INTEGRATION_FILE"], "/Applications/bree.app/Contents/Resources/shell-integration/fish/config.fish")
        expectEqual(environment["BREE_FISH_USER_CONFIG_ALREADY_LOADED"], "1")
        expectFalse(protectedKeys.contains("XDG_CONFIG_HOME"))
        expectTrue(protectedKeys.contains("BREE_FISH_INTEGRATION_FILE"))
        expectTrue(protectedKeys.contains("BREE_FISH_USER_CONFIG_ALREADY_LOADED"))
    }

    @Test
    func testManagedFishShellCommandLetsGhosttyApplyLoginExecWrapper() {
        let command = TerminalSurface.managedFishShellCommand(shell: "/Applications/Bree Dev fishsh.app/fish")

        expectEqual(command, "'/Applications/Bree Dev fishsh.app/fish' -il --init-command 'source \"$BREE_FISH_INTEGRATION_FILE\"'")
        expectFalse(command.hasPrefix("exec "))
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishIntegrationConfigParsesWhenFishIsAvailable() throws {
        let fishExecutable = try requireFishExecutable()
        let repoRoot = SwiftTestingAssertions.sourceURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationPath = repoRoot.appendingPathComponent("Resources/shell-integration/fish/config.fish")

        let result = runProcess(
            executablePath: fishExecutable,
            arguments: ["-n", integrationPath.path],
            environment: ProcessInfo.processInfo.environment,
            timeout: 5
        )

        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishIntegrationSourcesUserConfigAndReportsShellState() throws {
        _ = try requireFishExecutable()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-fish-shell-integration-\(UUID().uuidString)")
        let userConfigHome = root.appendingPathComponent("user-config", isDirectory: true)
        let logPath = root.appendingPathComponent("send.log", isDirectory: false)

        try writeUserFishConfig(at: userConfigHome)
        defer { try? fileManager.removeItem(at: root) }

        let result = try runInteractiveFish(
            command: """
            functions -e _bree_socket_is_unix
            function _bree_socket_is_unix
                return 0
            end
            functions -e _bree_send_bg
            function _bree_send_bg
                printf '%s\\n' $argv[1] >> "$BREE_TEST_LOG"
            end
            set -g _BREE_TTY_NAME ttys777
            set -g _BREE_TTY_REPORTED 0
            _bree_preexec
            _bree_prompt
            printf 'USER_CONFIG=%s\\n' "$BREE_USER_FISH_CONFIG_SOURCED"
            printf 'USER_CONFD=%s\\n' "$BREE_USER_FISH_CONFD_SOURCED"
            printf 'XDG_CONFIG_HOME=%s\\n' "$XDG_CONFIG_HOME"
            printf 'FUNCTION_PATH=%s\\n' (string join : $fish_function_path)
            printf 'COMPLETION_PATH=%s\\n' (string join : $fish_complete_path)
            printf 'FUNCTION_RESULT=%s\\n' (bree_test_function)
            printf 'CLAUDE_RESULT=%s\\n' (claude test)
            printf 'GROK_RESULT=%s\\n' (grok test)
            printf 'UNIVERSAL=%s\\n' "$BREE_UNIVERSAL_TEST"
            cat "$BREE_TEST_LOG"
            """,
            extraEnvironment: [
                "BREE_TEST_USER_CONFIG_HOME": userConfigHome.path,
                "BREE_TEST_LOG": logPath.path,
                "BREE_SOCKET_PATH": root.appendingPathComponent("bree-test.sock").path,
                "BREE_TAB_ID": "11111111-1111-1111-1111-111111111111",
                "BREE_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "BREE_TERMINAL_LIFECYCLE_ID": "33333333-3333-3333-3333-333333333333",
            ]
        )

        expectTrue(result.stdout.contains("USER_CONFIG=1"), result.stdout)
        expectTrue(result.stdout.contains("USER_CONFD=1"), result.stdout)
        expectTrue(result.stdout.contains("XDG_CONFIG_HOME=\(userConfigHome.path)"), result.stdout)
        expectTrue(result.stdout.contains("FUNCTION_PATH=\(userConfigHome.path)/fish/functions"), result.stdout)
        expectTrue(result.stdout.contains("COMPLETION_PATH=\(userConfigHome.path)/fish/completions"), result.stdout)
        expectTrue(result.stdout.contains("FUNCTION_RESULT=function-loaded"), result.stdout)
        expectTrue(result.stdout.contains("CLAUDE_RESULT=user-claude test"), result.stdout)
        expectTrue(result.stdout.contains("GROK_RESULT=user-grok test"), result.stdout)
        expectTrue(result.stdout.contains("UNIVERSAL=universal-loaded"), result.stdout)
        expectTrue(
            result.stdout.contains("report_tty ttys777 --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("report_shell_state running --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222 --terminal-lifecycle-id=33333333-3333-3333-3333-333333333333"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("ports_kick --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222 --reason=command"),
            result.stdout
        )
        expectTrue(
            result.stdout.contains("report_shell_state prompt --tab=11111111-1111-1111-1111-111111111111 --panel=22222222-2222-2222-2222-222222222222 --terminal-lifecycle-id=33333333-3333-3333-3333-333333333333"),
            result.stdout
        )
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishClaudeIntegrationToggleControlsWrapperAndShim() throws {
        _ = try requireFishExecutable()
        let probe = """
        if functions -q claude
            printf 'function=1\\n'
        else
            printf 'function=0\\n'
        end
        if set -q BREE_CLAUDE_WRAPPER_SHIM; and test -x "$BREE_CLAUDE_WRAPPER_SHIM"
            printf 'shim=1\\n'
        else
            printf 'shim=0\\n'
        end
        """

        let enabled = try runInteractiveFish(command: probe)
        expectTrue(enabled.stdout.contains("function=1"), enabled.stdout)
        expectTrue(enabled.stdout.contains("shim=1"), enabled.stdout)

        let disabled = try runInteractiveFish(
            command: probe,
            extraEnvironment: ["BREE_CLAUDE_INTEGRATION_DISABLED": "1"]
        )
        expectTrue(disabled.stdout.contains("function=0"), disabled.stdout)
        expectTrue(disabled.stdout.contains("shim=0"), disabled.stdout)
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testFishIntegrationRelayPromptReportsPWD() throws {
        _ = try requireFishExecutable()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-fish-relay-pwd-\(UUID().uuidString)")
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        let remoteDirectory = root.appendingPathComponent("remote-cwd", isDirectory: true)
        let logPath = root.appendingPathComponent("relay.log", isDirectory: false)
        let breePath = binDir.appendingPathComponent("bree", isDirectory: false)

        try fileManager.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: remoteDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: breePath,
            body: """
            #!/bin/sh
            printf '%s\\n' "$*" >> "\(logPath.path)"
            """
        )

        let result = try runInteractiveFish(
            command: """
            printf '' > "\(logPath.path)"
            cd "\(remoteDirectory.path)"
            set -g _BREE_TTY_REPORTED 1
            set -g _BREE_PORTS_LAST_RUN (_bree_now)
            set -g _BREE_PWD_LAST_PWD /tmp/local-launch
            _bree_prompt
            for _bree_i in (seq 1 20)
                test -s "\(logPath.path)"; and break
                sleep 0.05
            end
            cat "\(logPath.path)"
            """,
            extraEnvironment: [
                "BREE_SOCKET_PATH": "127.0.0.1:64011",
                "BREE_WORKSPACE_ID": "11111111-1111-1111-1111-111111111111",
                "BREE_TAB_ID": "22222222-2222-2222-2222-222222222222",
                "BREE_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "BREE_BUNDLED_CLI_PATH": breePath.path,
            ]
        )

        expectTrue(
            result.stdout.contains(#"rpc surface.report_pwd {"workspace_id":"11111111-1111-1111-1111-111111111111","path":"\#(remoteDirectory.path)","surface_id":"22222222-2222-2222-2222-222222222222"}"#),
            result.stdout
        )
    }

    @Test(.enabled(if: fishExecutablePath != nil))
    func testReattachedTmuxFishAdoptsSessionWorkspaceBinding() throws {
        _ = try requireFishExecutable()
        let result = try runInteractiveFish(
            command: """
            function tmux
                if test "$argv[1]" = show-environment
                    if test "$argv[2]" = -g
                        printf '%s\\n' 'BREE_SOCKET_PATH=127.0.0.1:63135' 'BREE_SSH_ATTEMPT_ID=stale-attempt' 'BREE_TAB_ID=stale-workspace' 'BREE_TERMINAL_LIFECYCLE_ID=stale-lifecycle' 'BREE_WORKSPACE_ID=stale-workspace'
                    else
                        printf '%s\\n' 'BREE_SOCKET_PATH=127.0.0.1:55272' 'BREE_SSH_ATTEMPT_ID=current-attempt' 'BREE_TAB_ID=current-workspace' 'BREE_TERMINAL_LIFECYCLE_ID=current-lifecycle' 'BREE_WORKSPACE_ID=current-workspace'
                    end
                end
            end
            _bree_tmux_sync_bree_environment
            printf 'workspace=%s\\nsocket=%s\\nlifecycle=%s\\nattempt=%s\\nsurface=%s\\npanel=%s\\n' \
                "$BREE_WORKSPACE_ID" "$BREE_SOCKET_PATH" "$BREE_TERMINAL_LIFECYCLE_ID" "$BREE_SSH_ATTEMPT_ID" \
                (set -q BREE_SURFACE_ID; and printf %s "$BREE_SURFACE_ID"; or printf %s '<unset>') \
                (set -q BREE_PANEL_ID; and printf %s "$BREE_PANEL_ID"; or printf %s '<unset>')
            """,
            extraEnvironment: [
                "BREE_PANEL_ID": "stale-surface",
                "BREE_SOCKET_PATH": "127.0.0.1:63135",
                "BREE_SURFACE_ID": "stale-surface",
                "BREE_TAB_ID": "stale-workspace",
                "BREE_TERMINAL_LIFECYCLE_ID": "stale-lifecycle",
                "BREE_SSH_ATTEMPT_ID": "stale-attempt",
                "BREE_WORKSPACE_ID": "stale-workspace",
                "TMUX": "/tmp/tmux-test,1,0",
            ]
        )

        expectTrue(result.stdout.contains("workspace=current-workspace"), result.stdout)
        expectTrue(result.stdout.contains("socket=127.0.0.1:55272"), result.stdout)
        expectTrue(result.stdout.contains("lifecycle=current-lifecycle"), result.stdout)
        expectTrue(result.stdout.contains("attempt=current-attempt"), result.stdout)
        expectTrue(result.stdout.contains("surface=<unset>"), result.stdout)
        expectTrue(result.stdout.contains("panel=<unset>"), result.stdout)
    }

    @Test
    func testGeneratedFishBootstrapStagesIntegrationAndPreservesUserConfigHome() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-fish-shell-bootstrap-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let bin = root.appendingPathComponent("bin")
        let userConfigHome = root.appendingPathComponent("user-config")
        let capturePath = root.appendingPathComponent("fish-env.txt")
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: userConfigHome, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        try writeExecutableShellFile(
            at: bin.appendingPathComponent("fish"),
            body: """
            #!/bin/sh
            {
              printf 'XDG_CONFIG_HOME=%s\\n' "$XDG_CONFIG_HOME"
              printf 'BREE_FISH_INTEGRATION_FILE=%s\\n' "$BREE_FISH_INTEGRATION_FILE"
              printf 'BREE_FISH_USER_CONFIG_ALREADY_LOADED=%s\\n' "$BREE_FISH_USER_CONFIG_ALREADY_LOADED"
              printf 'ARGS=%s\\n' "$*"
              printf 'CONFIG<<EOF\\n'
              cat "$BREE_FISH_INTEGRATION_FILE"
              printf '\\nEOF\\n'
            } > "$BREE_CAPTURE_FISH"
            """
        )
        let persistentPTYExecHelper = bin.appendingPathComponent("persistent-pty-exec-helper")
        try writeExecutableShellFile(
            at: persistentPTYExecHelper,
            body: """
            #!/bin/sh
            [ "${1:-}" = "--internal-persistent-pty-exec" ] || exit 2
            shift
            executable="${1:-}"
            [ -n "$executable" ] || exit 2
            shift
            [ "${1:-}" = "$executable" ] || exit 2
            shift
            exec "$executable" "$@"
            """
        )

        let script = RemoteInteractiveShellBootstrapBuilder.script(
            remoteRelayPort: 0,
            shellFeatures: "",
            bundledFishIntegration: "set -gx BREE_FISH_TEST_INTEGRATION 1"
        )
        let result = runProcess(
            executablePath: "/usr/bin/env",
            arguments: [
                "HOME=\(home.path)",
                "SHELL=\(bin.appendingPathComponent("fish").path)",
                "PATH=\(bin.path):/usr/bin:/bin",
                "TERM=xterm-256color",
                "USER=\(NSUserName())",
                "XDG_CONFIG_HOME=\(userConfigHome.path)",
                "BREE_CAPTURE_FISH=\(capturePath.path)",
                "BREE_PERSISTENT_PTY_EXEC_HELPER=\(persistentPTYExecHelper.path)",
                "/bin/sh",
                "-c",
                script,
            ],
            timeout: 5
        )

        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)

        let output = try String(contentsOf: capturePath, encoding: .utf8)
        expectTrue(output.contains("XDG_CONFIG_HOME=\(userConfigHome.path)"), output)
        expectTrue(output.contains("BREE_FISH_INTEGRATION_FILE=\(home.path)/.bree/relay/0.shell/fish/config.fish"), output)
        expectTrue(output.contains("BREE_FISH_USER_CONFIG_ALREADY_LOADED=1"), output)
        expectTrue(output.contains("ARGS=-il --init-command source \"$BREE_FISH_INTEGRATION_FILE\""), output)
        expectTrue(output.contains("set -gx BREE_FISH_TEST_INTEGRATION 1"), output)
    }

    private func writeUserFishConfig(at userConfigHome: URL) throws {
        let userFishConfig = userConfigHome.appendingPathComponent("fish/config.fish", isDirectory: false)
        let userFishConfD = userConfigHome.appendingPathComponent("fish/conf.d/bree-test.fish", isDirectory: false)
        let userFishFunction = userConfigHome.appendingPathComponent("fish/functions/bree_test_function.fish", isDirectory: false)
        let userFishCompletion = userConfigHome.appendingPathComponent("fish/completions/bree-test.fish", isDirectory: false)
        let userFishVariables = userConfigHome.appendingPathComponent("fish/fish_variables", isDirectory: false)
        let fileManager = FileManager.default

        try [
            userFishConfig,
            userFishConfD,
            userFishFunction,
            userFishCompletion,
            userFishVariables,
        ].forEach {
            try fileManager.createDirectory(at: $0.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try """
        set -gx BREE_USER_FISH_CONFIG_SOURCED 1
        function claude
            echo user-claude $argv
        end
        function grok
            echo user-grok $argv
        end
        """
            .write(to: userFishConfig, atomically: true, encoding: .utf8)
        try "set -gx BREE_USER_FISH_CONFD_SOURCED 1\n"
            .write(to: userFishConfD, atomically: true, encoding: .utf8)
        try """
        function bree_test_function
            echo function-loaded
        end
        """.write(to: userFishFunction, atomically: true, encoding: .utf8)
        try "complete -c bree-test -f\n"
            .write(to: userFishCompletion, atomically: true, encoding: .utf8)
        try """
        # This file contains fish universal variable definitions.
        # VERSION: 3.0
        SETUVAR BREE_UNIVERSAL_TEST:universal\\x2dloaded
        """.write(to: userFishVariables, atomically: true, encoding: .utf8)
    }

    private func requireFishExecutable() throws -> String {
        guard let fish = fishExecutablePath else {
            Issue.record("fish is not installed")
            throw CancellationError()
        }
        return fish
    }

    private func runInteractiveFish(
        command: String,
        extraEnvironment: [String: String] = [:]
    ) throws -> (stdout: String, stderr: String) {
        let fishExecutable = try requireFishExecutable()
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-fish-shell-integration-\(UUID().uuidString)")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let repoRoot = SwiftTestingAssertions.sourceURL()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let integrationDir = repoRoot.appendingPathComponent("Resources/shell-integration", isDirectory: true)
        let testIntegrationDir = root.appendingPathComponent("shell integration with spaces", isDirectory: true)
        try fileManager.copyItem(at: integrationDir, to: testIntegrationDir)
        let testBinDir = testIntegrationDir.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: testBinDir, withIntermediateDirectories: true)
        try writeExecutableShellFile(at: testBinDir.appendingPathComponent("bree-claude-wrapper"), body: "#!/bin/sh\necho bree-claude-wrapper \"$@\"\n")
        try writeExecutableShellFile(at: testBinDir.appendingPathComponent("grok"), body: "#!/bin/sh\necho bree-grok-wrapper \"$@\"\n")
        let integrationFile = testIntegrationDir.appendingPathComponent("fish/config.fish", isDirectory: false)

        var environment: [String: String] = [
            "HOME": root.path,
            "TERM": "xterm-256color",
            "SHELL": fishExecutable,
            "USER": NSUserName(),
            "XDG_CONFIG_HOME": extraEnvironment["BREE_TEST_USER_CONFIG_HOME"] ?? root.appendingPathComponent("user-config").path,
            "BREE_SHELL_INTEGRATION": "1",
            "BREE_SHELL_INTEGRATION_DIR": testIntegrationDir.path,
            "BREE_FISH_INTEGRATION_FILE": integrationFile.path,
            "BREE_FISH_USER_CONFIG_ALREADY_LOADED": "1",
        ]
        extraEnvironment.forEach { environment[$0] = $1 }
        environment.removeValue(forKey: "BREE_TEST_USER_CONFIG_HOME")

        let result = runProcess(
            executablePath: fishExecutable,
            arguments: ["-i", "--init-command", #"source "$BREE_FISH_INTEGRATION_FILE""#, "-c", command],
            environment: environment,
            timeout: 5
        )
        expectFalse(result.timedOut, result.stderr)
        expectEqual(result.status, 0, result.stderr)
        return (
            stdout: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func writeExecutableShellFile(at url: URL, body: String) throws {
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval
    ) -> ProcessRunResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ProcessRunResult(status: -1, stdout: "", stderr: String(describing: error), timedOut: false)
        }


        let timedOut = waitForProcessExit(process, timeout: timeout) == .timedOut
        if timedOut {
            process.terminate()
            _ = waitForProcessExit(process, timeout: 1)
        }

        return ProcessRunResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }
}
