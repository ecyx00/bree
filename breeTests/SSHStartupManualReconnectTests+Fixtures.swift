import BreeCore
import BreeFoundation
import Darwin
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

extension SSHStartupManualReconnectTests {
    private final class BundleToken {}

    struct TerminalExitPromptFixture {
        let startupCommand: String
        let environment: [String: String]
        let temporaryDirectory: URL
    }

    struct TerminalExitPromptProcess {
        let process: Process
        let standardInput: Pipe
        let transcriptURL: URL
        let transcriptHandle: FileHandle
        let temporaryDirectory: URL
        let terminalPathURL: URL
    }

    /// These tests cover the Workspace reconnect path.
    static func makeRemoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "bree-macmini",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: 64007,
            relayID: String(repeating: "a", count: 16),
            relayToken: String(repeating: "b", count: 64),
            localSocketPath: "/tmp/bree-debug-test.sock",
            terminalStartupCommand: "ssh bree-macmini"
        )
    }

    /// Set only while priming, so a primed fixture exits before doing any work.
    static let primeExecEnvironmentKey = "BREE_TEST_PRIME_EXEC"

    /// The line a primeable fixture carries right after its shebang.
    static let primeExecGuard = "if [ -n \"${\(primeExecEnvironmentKey):-}\" ]; then exit 0; fi"

    /// Pays macOS's first-exec assessment for new fixtures before a timed wait.
    ///
    /// The first exec of every newly written file, scripts included, blocks
    /// while syspolicyd assesses it; later execs of the same file do not. On
    /// loaded fleet minis the first new file a fresh app host ran waited 6 to
    /// 13 s, longer than the 3 s prompt waits, so each fixture runs once here,
    /// untimed, as soon as it is written.
    static func primeFirstExec(_ executables: URL...) throws {
        for executable in executables {
            let result = runProcess(
                executablePath: executable.path,
                arguments: [],
                environment: ["PATH": "/usr/bin:/bin", primeExecEnvironmentKey: "1"],
                timeout: 120
            )
            try #require(
                !result.timedOut && result.status == 0,
                "priming \(executable.lastPathComponent) failed with status \(result.status): \(result.stderr)"
            )
        }
    }

    /// Writes an executable shell fixture and primes it (see `primeFirstExec`).
    static func writeShellFile(at url: URL, lines: [String]) throws {
        var lines = lines
        let isScript = lines.first?.hasPrefix("#!") == true
        if isScript {
            lines.insert(primeExecGuard, at: 1)
        }
        try lines.joined(separator: "\n")
            .appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
        guard isScript else { return }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        try primeFirstExec(url)
    }

    /// Foreground-auth token the supervisor command expects in its environment.
    static let persistentAttachSupervisorAuthToken = UUID().uuidString.lowercased()

    static func persistentAttachSupervisorCommand(replacingSystemSSHWith fakeSSH: URL) -> String {
        // Direct process signals belong to the attach supervisor that the app
        // builds for restore and reattach.
        SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-test-session",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "fixture.example.test",
                port: 2222,
                identityFile: nil,
                sshOptions: ["ControlMaster=no"],
                token: persistentAttachSupervisorAuthToken
            )
        ).replacingOccurrences(of: "/usr/bin/ssh", with: fakeSSH.path)
    }

    static func generatedSSHInitialStartupCommand(
        replacingSystemSSHWith fakeSSH: URL
    ) throws -> String {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(for: BundleToken.self)
        let socketPath = makeSocketPath("ssh-startup")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:9"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return malformedRequestResponse(raw: line)
            }

            switch method {
            case "workspace.create":
                return v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "remote": [
                            "enabled": true,
                            "state": "connecting",
                        ],
                    ]
                )
            default:
                return v2Response(id: id, ok: false, error: ["code": "unexpected", "message": "Unexpected method \(method)"])
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["BREE_SOCKET_PATH"] = socketPath
        environment["BREE_CLI_SENTRY_DISABLED"] = "1"
        environment["BREE_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh", "--no-focus", "--port", "2222",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/bree-ssh-%C",
                "--ssh-option", "RequestTTY no",
                "bree-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        #expect(serverHandled.wait(timeout: .now() + 5) == .success)
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))

        let requests = state.snapshot().compactMap(jsonObject)
        let configureRequest = try #require(
            requests.first { ($0["method"] as? String) == "workspace.remote.configure" }
        )
        let configureParams = try #require(configureRequest["params"] as? [String: Any])
        let startupCommand = try #require(configureParams["terminal_startup_command"] as? String)
        return try rewritingSystemSSH(in: startupCommand, with: fakeSSH)
    }

    private static func rewritingSystemSSH(
        in startupCommand: String,
        with fakeSSH: URL
    ) throws -> String {
        let systemSSHPath = "/usr/bin/ssh"
        let commandURL = URL(
            fileURLWithPath: startupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: commandURL.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            let script = try String(contentsOf: commandURL, encoding: .utf8)
            try #require(script.contains(systemSSHPath))
            var scriptLines = script
                .replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
                .components(separatedBy: "\n")
            try #require(scriptLines.first?.hasPrefix("#!") == true)
            // The launcher deletes itself when it runs; a primed run exits first.
            scriptLines.insert(primeExecGuard, at: 1)
            try scriptLines.joined(separator: "\n")
                .write(to: commandURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: commandURL.path
            )
            try primeFirstExec(commandURL)
            return startupCommand
        }

        if startupCommand.contains(systemSSHPath) {
            return startupCommand.replacingOccurrences(of: systemSSHPath, with: fakeSSH.path)
        }

        return try #require(SSHStartupCommandTestSupport.replacingPinnedSSH(
            in: startupCommand, with: fakeSSH.path
        ))
    }

    private static func makeTerminalExitPromptFixture() throws -> TerminalExitPromptFixture {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-exit-prompt-fixture-\(UUID().uuidString)", isDirectory: true)
        let fakeCLI = root.appendingPathComponent("bree")
        let fakeSSH = root.appendingPathComponent("ssh")
        let fakeSleep = root.appendingPathComponent("sleep")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        do {
            try writeShellFile(at: fakeCLI, lines: ["#!/bin/sh", "exit 0"])
            try writeShellFile(at: fakeSSH, lines: [
                "#!/bin/sh",
                "printf '%s\\n' 'Permission denied (publickey).' >&2",
                "exit 255",
            ])
            try writeShellFile(at: fakeSleep, lines: ["#!/bin/sh", "exit 0"])
            for executable in [fakeCLI, fakeSSH, fakeSleep] {
                try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }

            let startupCommand = try generatedSSHInitialStartupCommand(
                replacingSystemSSHWith: fakeSSH
            )
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(root.path):\(environment["PATH"] ?? "/usr/bin:/bin")"
            environment["BREE_BUNDLED_CLI_PATH"] = fakeCLI.path
            environment["BREE_SOCKET_PATH"] = "/tmp/bree-debug-test.sock"
            environment["BREE_WORKSPACE_ID"] = "11111111-1111-1111-1111-111111111111"
            environment["BREE_SURFACE_ID"] = "22222222-2222-2222-2222-222222222222"
            environment["BREE_SSH_RECONNECT_LIMIT"] = "0"
            environment["BREE_SSH_RECONNECT_DELAY_SECONDS"] = "2"
            environment["BREE_SSH_RECONNECT_MAX_DELAY_SECONDS"] = "2"
            return TerminalExitPromptFixture(
                startupCommand: startupCommand,
                environment: environment,
                temporaryDirectory: root
            )
        } catch {
            try? fileManager.removeItem(at: root)
            throw error
        }
    }

    static func makeTerminalExitPromptProcess(
        _ suppliedFixture: TerminalExitPromptFixture? = nil
    ) throws -> TerminalExitPromptProcess {
        let fixture = try suppliedFixture ?? makeTerminalExitPromptFixture()
        let transcriptURL = fixture.temporaryDirectory.appendingPathComponent("transcript.txt")
        try Data().write(to: transcriptURL)
        let transcriptHandle = try FileHandle(forWritingTo: transcriptURL)
        let terminalPathURL = fixture.temporaryDirectory.appendingPathComponent("terminal-path.txt")
        let process = Process()
        let standardInput = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q", "-F", "/dev/null", "/bin/sh", "-c",
            "/usr/bin/tty > \"$BREE_TEST_PROMPT_TTY_PATH\"\n" + fixture.startupCommand,
        ]
        var environment = fixture.environment
        environment["BREE_TEST_PROMPT_TTY_PATH"] = terminalPathURL.path
        process.environment = environment
        process.standardInput = standardInput
        process.standardOutput = transcriptHandle
        process.standardError = FileHandle.nullDevice
        do {
            try SSHStartupCommandTestSupport.startProcess(process)
        } catch {
            try? transcriptHandle.close()
            try? FileManager.default.removeItem(at: fixture.temporaryDirectory)
            throw error
        }
        return TerminalExitPromptProcess(
            process: process,
            standardInput: standardInput,
            transcriptURL: transcriptURL,
            transcriptHandle: transcriptHandle,
            temporaryDirectory: fixture.temporaryDirectory,
            terminalPathURL: terminalPathURL
        )
    }
}
