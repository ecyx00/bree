import Foundation
import Testing
@testable import BreeFoundation

@Suite("Remote tmux session launch behavior")
struct RemoteTmuxSessionCommandBuilderTests {
    @Test("new session installs the integrated shell command for current and future panes")
    func createsIntegratedSession() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let shellCommand = #"exec "${SHELL:-/bin/bash}" --rcfile "$HOME/bree rc" -i"#
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "agent main",
                shellCommand: shellCommand
            )
            let result = try run(builder.remoteShellCommand, environment: environment)

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            #expect(try invocations(in: directory) == [
                ["has-session", "-t", "=agent main"],
                [
                    "new-session", "-d",
                    "-e", "BREE_BUNDLED_CLI_PATH=",
                    "-e", "BREE_PERSISTENT_PTY_EXEC_HELPER=",
                    "-e", "BREE_SHELL_INTEGRATION=",
                    "-e", "BREE_SHELL_INTEGRATION_DIR=",
                    "-e", "BREE_SOCKET_PATH=",
                    "-e", "BREE_SSH_ATTEMPT_ID=",
                    "-e", "BREE_TAB_ID=",
                    "-e", "BREE_TERMINAL_LIFECYCLE_ID=",
                    "-e", "BREE_WORKSPACE_ID=",
                    "-e", "BREE_INITIAL_COMMAND_FILE=",
                    "-e", "BREE_PANEL_ID=",
                    "-e", "BREE_SURFACE_ID=",
                    "-s", "agent main", shellCommand,
                ],
                ["set-environment", "-t", "=agent main", "-u", "BREE_BUNDLED_CLI_PATH"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_PERSISTENT_PTY_EXEC_HELPER"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_SHELL_INTEGRATION"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_SHELL_INTEGRATION_DIR"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_SOCKET_PATH"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_SSH_ATTEMPT_ID"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_TAB_ID"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_TERMINAL_LIFECYCLE_ID"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_WORKSPACE_ID"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_INITIAL_COMMAND_FILE"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_PANEL_ID"],
                ["set-environment", "-t", "=agent main", "-u", "BREE_SURFACE_ID"],
                ["set-option", "-t", "=agent main:", "default-command", shellCommand],
                ["attach-session", "-t", "=agent main"],
            ])
        }
    }

    @Test("new session binds current workspace metadata before its first shell starts")
    func newSessionBindsWorkspaceMetadataBeforeFirstShell() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let shellCommand = "exec integrated-shell"
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "fresh",
                shellCommand: shellCommand
            )
            let currentWorkspace = "11111111-1111-1111-1111-111111111111"
            let currentSurface = "22222222-2222-2222-2222-222222222222"
            let currentSocket = "127.0.0.1:55272"
            let currentEnvironment = [
                "BREE_BUNDLED_CLI_PATH": "/home/dev/.bree/bin/bree",
                "BREE_PERSISTENT_PTY_EXEC_HELPER": "/home/dev/.bree/bin/bree",
                "BREE_PANEL_ID": currentSurface,
                "BREE_SHELL_INTEGRATION": "1",
                "BREE_SHELL_INTEGRATION_DIR": "/home/dev/.bree/relay/55272.shell",
                "BREE_SOCKET_PATH": currentSocket,
                "BREE_SURFACE_ID": currentSurface,
                "BREE_TAB_ID": currentWorkspace,
                "BREE_WORKSPACE_ID": currentWorkspace,
            ]
            let result = try run(
                builder.remoteShellCommand,
                environment: environment.merging(currentEnvironment) { _, current in current }
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let newSessionCall = try #require(calls.first { $0.first == "new-session" })
            #expect(newSessionCall == [
                "new-session", "-d",
                "-e", "BREE_BUNDLED_CLI_PATH=/home/dev/.bree/bin/bree",
                "-e", "BREE_PERSISTENT_PTY_EXEC_HELPER=/home/dev/.bree/bin/bree",
                "-e", "BREE_SHELL_INTEGRATION=1",
                "-e", "BREE_SHELL_INTEGRATION_DIR=/home/dev/.bree/relay/55272.shell",
                "-e", "BREE_SOCKET_PATH=\(currentSocket)",
                "-e", "BREE_SSH_ATTEMPT_ID=",
                "-e", "BREE_TAB_ID=\(currentWorkspace)",
                "-e", "BREE_TERMINAL_LIFECYCLE_ID=",
                "-e", "BREE_WORKSPACE_ID=\(currentWorkspace)",
                "-e", "BREE_INITIAL_COMMAND_FILE=",
                "-e", "BREE_PANEL_ID=",
                "-e", "BREE_SURFACE_ID=",
                "-s", "fresh", shellCommand,
            ])

            let newSessionIndex = try #require(calls.firstIndex(of: newSessionCall))
            let setOptionIndex = try #require(calls.firstIndex {
                $0.first == "set-option"
            })
            for (key, value) in currentEnvironment where key != "BREE_PANEL_ID" && key != "BREE_SURFACE_ID" {
                let expectedCall = ["set-environment", "-t", "=fresh", key, value]
                let index = try #require(calls.firstIndex(of: expectedCall), "missing tmux call: \(expectedCall)")
                #expect(newSessionIndex < index)
                #expect(index < setOptionIndex)
            }
        }
    }

    @Test("new session passes the one-shot command payload only to its first shell")
    func newSessionPassesInitialCommandPayloadToFirstShell() throws {
        try withFakeTmux(sessionExists: false) { directory, environment in
            let initialCommandFile = "/home/dev/.bree/relay/55272.shell/initial-command.payload"
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "fresh-command",
                shellCommand: "exec integrated-shell"
            )
            let result = try run(
                builder.remoteShellCommand,
                environment: environment.merging([
                    "BREE_INITIAL_COMMAND_FILE": initialCommandFile,
                ]) { _, current in current }
            )

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let newSessionCall = try #require(calls.first { $0.first == "new-session" })
            #expect(newSessionCall.contains("BREE_INITIAL_COMMAND_FILE=\(initialCommandFile)"))

            let newSessionIndex = try #require(calls.firstIndex(of: newSessionCall))
            let clearCall = [
                "set-environment", "-t", "=fresh-command", "-u", "BREE_INITIAL_COMMAND_FILE",
            ]
            let clearIndex = try #require(calls.firstIndex(of: clearCall))
            let setOptionIndex = try #require(calls.firstIndex { $0.first == "set-option" })
            #expect(newSessionIndex < clearIndex)
            #expect(clearIndex < setOptionIndex)
        }
    }

    @Test("existing session rebinds workspace metadata before attach without mutating user options")
    func existingSessionRebindsWorkspaceMetadata() throws {
        try withFakeTmux(sessionExists: true) { directory, environment in
            let builder = RemoteTmuxSessionCommandBuilder(
                sessionName: "existing",
                shellCommand: "exec integrated-shell"
            )
            let currentWorkspace = "11111111-1111-1111-1111-111111111111"
            let currentSocket = "127.0.0.1:55272"
            let currentLifecycle = "33333333-3333-3333-3333-333333333333"
            let currentAttempt = "44444444-4444-4444-4444-444444444444"
            let result = try run(builder.remoteShellCommand, environment: environment.merging([
                "BREE_BUNDLED_CLI_PATH": "/home/dev/.bree/bin/bree",
                "BREE_PERSISTENT_PTY_EXEC_HELPER": "/home/dev/.bree/bin/bree",
                "BREE_PANEL_ID": "22222222-2222-2222-2222-222222222222",
                "BREE_SHELL_INTEGRATION_DIR": "/home/dev/.bree/relay/55272.shell",
                "BREE_SOCKET_PATH": currentSocket,
                "BREE_SSH_ATTEMPT_ID": currentAttempt,
                "BREE_SURFACE_ID": "22222222-2222-2222-2222-222222222222",
                "BREE_TAB_ID": currentWorkspace,
                "BREE_TERMINAL_LIFECYCLE_ID": currentLifecycle,
                "BREE_WORKSPACE_ID": currentWorkspace,
            ]) { _, current in current })

            #expect(result.status == 0)
            #expect(result.stderr.isEmpty)
            let calls = try invocations(in: directory)
            let attachIndex = try #require(calls.firstIndex(of: ["attach-session", "-t", "=existing"]))
            let expectedBeforeAttach = [
                ["set-environment", "-t", "=existing", "BREE_BUNDLED_CLI_PATH", "/home/dev/.bree/bin/bree"],
                ["set-environment", "-t", "=existing", "BREE_PERSISTENT_PTY_EXEC_HELPER", "/home/dev/.bree/bin/bree"],
                ["set-environment", "-t", "=existing", "BREE_SHELL_INTEGRATION_DIR", "/home/dev/.bree/relay/55272.shell"],
                ["set-environment", "-t", "=existing", "BREE_SOCKET_PATH", currentSocket],
                ["set-environment", "-t", "=existing", "BREE_SSH_ATTEMPT_ID", currentAttempt],
                ["set-environment", "-t", "=existing", "BREE_TAB_ID", currentWorkspace],
                ["set-environment", "-t", "=existing", "BREE_TERMINAL_LIFECYCLE_ID", currentLifecycle],
                ["set-environment", "-t", "=existing", "BREE_WORKSPACE_ID", currentWorkspace],
                ["set-environment", "-t", "=existing", "-u", "BREE_PANEL_ID"],
                ["set-environment", "-t", "=existing", "-u", "BREE_SURFACE_ID"],
            ]
            for expectedCall in expectedBeforeAttach {
                let index = try #require(calls.firstIndex(of: expectedCall), "missing tmux call: \(expectedCall)")
                #expect(index < attachIndex)
            }
            #expect(!calls.contains { $0.first == "set-option" })
        }
    }

    private func withFakeTmux(
        sessionExists: Bool,
        operation: (URL, [String: String]) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-tmux-session-\(UUID().uuidString)", isDirectory: true)
        let executableDirectory = directory.appendingPathComponent(".local/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: executableDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let executable = executableDirectory.appendingPathComponent("tmux")
        try """
        #!/bin/sh
        printf '%s\\034' "$@" >> "$BREE_TMUX_LOG"
        printf '\\n' >> "$BREE_TMUX_LOG"
        case "${1:-}" in
          has-session)
            [ -f "$BREE_TMUX_SESSION_STATE" ]
            ;;
          new-session)
            : > "$BREE_TMUX_SESSION_STATE"
            ;;
        esac
        """.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        let statePath = directory.appendingPathComponent("session-state").path
        if sessionExists {
            try Data().write(to: URL(fileURLWithPath: statePath))
        }
        try operation(directory, [
            "HOME": directory.path,
            "PATH": "/usr/bin:/bin",
            "BREE_TMUX_LOG": directory.appendingPathComponent("tmux.log").path,
            "BREE_TMUX_SESSION_STATE": statePath,
        ])
    }

    private func invocations(in directory: URL) throws -> [[String]] {
        String(
            decoding: try Data(contentsOf: directory.appendingPathComponent("tmux.log")),
            as: UTF8.self
        )
        .split(separator: "\n")
        .map { line in
            line.split(separator: "\u{1c}", omittingEmptySubsequences: true).map(String.init)
        }
    }

    private func run(
        _ command: String,
        environment: [String: String]
    ) throws -> (status: Int32, stderr: String) {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = environment
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: standardError.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
