import BreeFoundation
import Darwin
import Foundation
import Testing
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

// Regression coverage for https://github.com/ecyx00/bree/issues/7246:
// `bree ssh` against a host whose ~/.ssh/config sets `RequestTTY yes` and
// `RemoteCommand sudo su -` fails with OpenSSH's
// "Cannot execute command-line and remote command." (exit 255) and loops the
// reconnect banner. Every bree-controlled ssh invocation that supplies its own
// remote command must override the host-configured RemoteCommand (e.g.
// `-o RemoteCommand=none`), while the session hop that intentionally carries
// bree's own `-o RemoteCommand=<bootstrap>` keeps doing so.
//
// The fake `ssh` below mirrors OpenSSH's actual rule: a positional remote
// command is fatal iff no `-o RemoteCommand=...` override appears on the argv
// (the first RemoteCommand option wins, like OpenSSH's first-obtained-value
// semantics). It records one `invocation kind=<...> override=<...>` event per
// spawn so assertions can distinguish config dumps, control operations,
// interactive sessions, and command-carrying invocations.
@Suite(.serialized)
struct SSHConfiguredRemoteCommandHostTests {
    private typealias MockSocketServerState =
        CLINotifyProcessIntegrationRegressionTests.MockSocketServerState

    private let processSupport = CLINotifyProcessIntegrationRegressionTests(invocation: nil)

    @Test(arguments: [false, true])
    func sshStartupFallsBackToUnmanagedSessionWhenConfigurationResolutionIsUnavailable(
        usesMosh: Bool
    ) throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath(
            usesMosh ? "mosh-config-unavailable" : "ssh-config-unavailable"
        )
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "22222222-2222-2222-2222-222222222222"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let state = MockSocketServerState()
        let handled = processSupport.startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.create":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "surface_id": surfaceID,
                ])
            case "workspace.remote.configure":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "remote": ["enabled": true, "state": "connecting"],
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["BREE_SOCKET_PATH"] = socketPath
        environment["BREE_CLI_SENTRY_DISABLED"] = "1"
        environment["BREE_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        var arguments = [
            "ssh",
            "--no-focus",
        ]
        if usesMosh {
            arguments += ["--transport", "mosh"]
        }
        // Pin RequestTTY=no to cover the startup script built for sessions
        // without a TTY.
        arguments += [
            "--ssh-option", "RemoteCommand=printf explicit-fallback",
            "--ssh-option", "BreeTestInvalidOption=yes",
            "--ssh-option", "RequestTTY no",
            "bree-config-unavailable-host",
        ]
        let result = processSupport.runProcess(
            executablePath: cliPath,
            arguments: arguments,
            environment: environment,
            timeout: 20
        )
        #expect(
            XCTWaiter().wait(for: [handled], timeout: 5) == .completed,
            "cli mock socket was not handled within 5 seconds"
        )

        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        let requests = state.commands.compactMap(processSupport.jsonObject)
        let methods = requests.compactMap { $0["method"] as? String }
        #expect(methods.contains("workspace.create"), "\(methods)")
        #expect(methods.contains("workspace.remote.configure"), "\(methods)")
        let createParams = try #require(
            requests.first { $0["method"] as? String == "workspace.create" }?["params"]
                as? [String: Any]
        )
        let startupCommand = try #require(createParams["initial_command"] as? String)
        let startupURL = URL(fileURLWithPath: startupCommand)
        let startupArtifact = FileManager.default.fileExists(atPath: startupURL.path)
            ? try String(contentsOf: startupURL, encoding: .utf8)
            : startupCommand
        #expect(startupArtifact.contains("RemoteCommand=printf explicit-fallback"), "\(startupArtifact)")
        #expect(!startupArtifact.contains("ssh-pty-attach"), "\(startupArtifact)")
        #expect(!startupArtifact.contains("bree_mosh"), "\(startupArtifact)")
        let configureParams = try #require(
            requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"]
                as? [String: Any]
        )
        #expect(configureParams["configured_remote_command"] == nil)
        #expect(
            configureParams["terminal_transport"] as? String == "ssh",
            "An unmanaged OpenSSH fallback must persist the transport it actually launched: \(configureParams)"
        )
    }

    /// `bree ssh` bootstrap-install flow without a TTY (ControlMaster
    /// disabled → staged installer hop + session hop): a caller-supplied
    /// `RemoteCommand` is captured as the program to chain and retained in
    /// durable workspace options, while the session hop carries only bree's
    /// `-o RemoteCommand=<bootstrap>`.
    @Test
    func sshBootstrapStartupChainsExplicitRemoteCommandWithConnectionSharingDisabled() throws {
        let cliPath = try processSupport.bundledCLIPath()
        let socketPath = processSupport.makeSocketPath("ssh-rc-boot")
        let listenerFD = try processSupport.bindUnixSocket(at: socketPath)
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let harness = try makeRemoteCommandHostHarness(prefix: "bree-ssh-rc-bootstrap")
        let configuredRemoteCommand = #"printf 'caller %% %h %n %p %r'"#
        let expandedRemoteCommand = #"printf 'caller % resolved.example bree-remotecommand-host 2233 remote-token-user'"#

        defer {
            harness.cleanup()
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let captureState = MockSocketServerState()
        let captureHandled = processSupport.startMockServer(
            listenerFD: listenerFD,
            state: captureState
        ) { line in
            guard let payload = processSupport.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return processSupport.malformedRequestResponse(raw: line)
            }
            switch method {
            case "workspace.create":
                return processSupport.v2Response(id: id, ok: true, result: ["workspace_id": workspaceID])
            case "workspace.remote.configure":
                return processSupport.v2Response(id: id, ok: true, result: [
                    "workspace_id": workspaceID,
                    "workspace_ref": "workspace:9",
                    "remote": ["enabled": true, "state": "connecting"],
                ])
            default:
                return processSupport.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var captureEnvironment = ProcessInfo.processInfo.environment
        captureEnvironment["BREE_SOCKET_PATH"] = socketPath
        captureEnvironment["BREE_CLI_SENTRY_DISABLED"] = "1"
        captureEnvironment["BREE_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let captureResult = processSupport.runProcess(
            executablePath: cliPath,
            arguments: [
                "ssh",
                "--no-focus",
                "--port", "2233",
                "--ssh-option", "ControlMaster no",
                "--ssh-option", "ControlPath /tmp/bree-ssh-%C",
                "--ssh-option", "HostName=resolved.example",
                "--ssh-option", "User=remote-token-user",
                "--ssh-option", "RemoteCommand=\(configuredRemoteCommand)",
                // The staged startup script is only built without a TTY.
                "--ssh-option", "RequestTTY no",
                "bree-remotecommand-host",
            ],
            environment: captureEnvironment,
            timeout: 20
        )
        #expect(
            XCTWaiter().wait(for: [captureHandled], timeout: 5) == .completed,
            "cli mock socket was not handled within 5 seconds"
        )
        #expect(!captureResult.timedOut, Comment(rawValue: captureResult.stderr))
        #expect(captureResult.status == 0, Comment(rawValue: captureResult.stderr))

        let requests = captureState.commands.compactMap(processSupport.jsonObject)
        let createParams = try #require(
            requests.first { $0["method"] as? String == "workspace.create" }?["params"] as? [String: Any]
        )
        let startupCommand = try #require(createParams["initial_command"] as? String)
        let configureParams = try #require(
            requests.first { $0["method"] as? String == "workspace.remote.configure" }?["params"] as? [String: Any]
        )
        #expect(configureParams["configured_remote_command"] as? String == expandedRemoteCommand)
        let forwardedOptions = configureParams["ssh_options"] as? [String] ?? []
        #expect(
            forwardedOptions.contains("RemoteCommand=\(configuredRemoteCommand)"),
            """
            Durable workspace options must preserve the caller's tokenized RemoteCommand \
            so unmanaged OpenSSH fallbacks retain authoritative expansion: \(forwardedOptions)
            """
        )
        let executableStartupCommand = try harness.startupCommandUsingFakeSSH(startupCommand)

        let startupResult = processSupport.runProcess(
            executablePath: "/bin/sh",
            arguments: ["-c", executableStartupCommand],
            environment: harness.startupEnvironment(
                socketPath: socketPath,
                workspaceID: workspaceID,
                surfaceID: "22222222-2222-2222-2222-222222222222"
            ),
            timeout: 10
        )

        #expect(!startupResult.timedOut, Comment(rawValue: startupResult.stderr))
        #expect(
            !startupResult.stderr.contains("Cannot execute command-line and remote command."),
            "The bootstrap installer hop must override a host-configured RemoteCommand; stderr: \(startupResult.stderr)"
        )
        #expect(
            !startupResult.stderr.contains("[bree] ssh exited with status"),
            Comment(rawValue: startupResult.stderr)
        )
        #expect(startupResult.status == 0, Comment(rawValue: startupResult.stderr))

        let events = harness.recordedSSHEvents()
        #expect(
            events.contains("invocation kind=command override=none"),
            "The bootstrap installer hop must pass -o RemoteCommand=none; events: \(events)"
        )
        #expect(
            !events.contains("invocation kind=command override=absent"),
            "A bree-supplied command-line remote command reached ssh without a RemoteCommand override; events: \(events)"
        )
        #expect(
            events.contains("invocation kind=session override=custom"),
            "The interactive session hop must keep carrying bree's own -o RemoteCommand=<bootstrap>, not have it cleared to none; events: \(events)"
        )
        #expect(
            events.contains("remotecommand-options kind=session count=1"),
            "The interactive session must carry only bree's bootstrap RemoteCommand; events: \(events)"
        )
    }

    @Test
    func sshPTYAttachCarriesConfiguredRemoteCommandAcrossMissingSessionFallback() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-w-s",
            remoteCommand: "while true; do tmux attach -t work || sleep 5; done"
        )
        #expect(command.contains("--command-b64"))
        #expect(command.contains(Data("while true; do tmux attach -t work || sleep 5; done".utf8).base64EncodedString()))
        #expect(command.contains("--require-existing"))
    }

    /// The app-side restore/reattach startup script builder runs a
    /// foreground-auth `ssh ... <dest> true` hop that must override a
    /// host-configured RemoteCommand.
    @Test
    func sshPTYAttachForegroundAuthOverridesHostConfiguredRemoteCommand() throws {
        let command = SSHPTYAttachStartupCommandBuilder.command(
            sessionID: "ssh-w-s",
            foregroundAuth: SSHPTYAttachStartupCommandBuilder.ForegroundAuth(
                destination: "bree-remotecommand-host",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "ControlMaster=auto",
                    "ControlPersist=600",
                    "ControlPath=/tmp/bree-ssh-%C",
                    "RemoteCommand=printf caller-command",
                ],
                token: "auth-token"
            ),
            remoteCommand: "printf ready"
        )
        #expect(
            command.contains("-o RemoteCommand=none -T -- bree-remotecommand-host true"),
            "Restore foreground auth must override a host-configured RemoteCommand before running its command-line `true`; command: \(command)"
        )
        #expect(
            command.contains("/usr/bin/ssh -o"),
            "Restore foreground auth must use the same system OpenSSH executable as config resolution; command: \(command)"
        )
        #expect(
            !command.contains("RemoteCommand=printf caller-command"),
            """
            Restore foreground auth must not forward the durable caller RemoteCommand \
            alongside bree's override; command: \(command)
            """
        )
        #expect(!command.contains("-$$"), Comment(rawValue: command))
        #expect(
            command.contains("--lifecycle-id \"$bree_ssh_attach_lifecycle_id\""),
            Comment(rawValue: command)
        )
        #expect(command.contains("ssh-session-end --lifecycle-only"), Comment(rawValue: command))
    }
}
