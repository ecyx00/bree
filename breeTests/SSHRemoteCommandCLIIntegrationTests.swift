import Darwin
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite(.serialized)
struct SSHRemoteCommandCLIIntegrationTests {
    private typealias Harness = SSHStartupManualReconnectTests

    private final class RemoteCommandBundleToken {}

    private struct RemoteCommandMockedSSHRun {
        let requests: [[String: Any]]
    }

    @Test
    func testSSHRejectsMixedTTYOptionClusterBeforeSocketUse() throws {
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: RemoteCommandBundleToken.self
        )
        let socketPath = Harness.makeSocketPath("mixed-tty-cluster")
        let listenerFD = try Harness.bindUnixSocket(at: socketPath)
        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }
        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in Darwin.close(clientFD) },
            onListenerClosed: {}
        )
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("BREE_") {
            environment.removeValue(forKey: key)
        }
        environment["BREE_SOCKET_PATH"] = socketPath

        let result = Harness.runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "--no-focus", "example.test", "-tq", "docker"],
            environment: environment,
            timeout: 5
        )

        #expect(result.status != 0, Comment(rawValue: result.stderr))
        #expect(
            (result.stdout + result.stderr).contains("mixed short-option cluster"),
            Comment(rawValue: result.stdout + result.stderr)
        )
    }

    @Test
    func testSCPOverridesTerminalTTYIntent() {
        let session = DetectedSSHSession(
            destination: "user@example.com",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: ["RequestTTY=force", "ProxyJump=bastion"]
        )

        let scpArguments = session.scpArgumentsForTesting(
            localPath: "/tmp/local.png",
            remotePath: "/tmp/bree-drop-123.png"
        )

        #expect(scpArguments.contains("RequestTTY=no"))
        #expect(!scpArguments.contains("RequestTTY=force"))
        #expect(scpArguments.contains("ProxyJump=bastion"))
    }

    @Test
    func testSSHLeadingTTYDisablePersistsRequestTTYForRestoration() throws {
        let cases: [(name: String, arguments: [String], option: String)] = [
            ("flag", ["-T"], "RequestTTY=no"),
            (
                "boolean alias",
                ["--ssh-option", "RequestTTY=false"],
                "RequestTTY=false"
            ),
            (
                "quoted alias",
                ["--ssh-option", "RequestTTY = \"false\""],
                "RequestTTY = \"false\""
            ),
        ]

        for testCase in cases {
            let run = try Self.runRemoteCommandMockedSSH(arguments: testCase.arguments)
            let createParams = try #require(
                Self.params(for: "workspace.create", in: run.requests),
                Comment(rawValue: testCase.name)
            )
            let configureParams = try #require(
                Self.params(for: "workspace.remote.configure", in: run.requests),
                Comment(rawValue: testCase.name)
            )
            let sshOptions = try #require(
                configureParams["ssh_options"] as? [String],
                Comment(rawValue: testCase.name)
            )
            let initialCommand = try #require(
                createParams["initial_command"] as? String,
                Comment(rawValue: testCase.name)
            )
            let restoredCommand = try #require(
                configureParams["terminal_startup_command"] as? String,
                Comment(rawValue: testCase.name)
            )
            let initialScript = Self.decodedReusableStartupScript(from: initialCommand) ?? initialCommand
            let restoredScript = Self.decodedReusableStartupScript(from: restoredCommand) ?? restoredCommand

            #expect(
                sshOptions.filter {
                    $0.filter { !$0.isWhitespace }
                        .lowercased()
                        .hasPrefix("requesttty=")
                } == [testCase.option],
                Comment(rawValue: testCase.name)
            )
            for script in [initialScript, restoredScript] {
                #expect(!script.contains("ssh-pty-attach"), Comment(rawValue: testCase.name))
            }
            #expect(configureParams["persistent_daemon_slot"] == nil, Comment(rawValue: testCase.name))
            #expect(configureParams["preserve_after_terminal_exit"] == nil, Comment(rawValue: testCase.name))
        }
    }

    private static func runRemoteCommandMockedSSH(
        arguments sshArguments: [String]
    ) throws -> RemoteCommandMockedSSHRun {
        let fileManager = FileManager.default
        let cliPath = try BundledCLITestSupport.bundledCLIPath(
            for: RemoteCommandBundleToken.self
        )
        let socketPath = Harness.makeSocketPath("ssh-remote-command")
        let homeURL = fileManager.temporaryDirectory
            .appendingPathComponent("bree-ssh-home-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: homeURL, withIntermediateDirectories: true)
        let listenerFD = try Harness.bindUnixSocket(at: socketPath)
        let state = Harness.MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let surfaceID = "33333333-3333-3333-3333-333333333333"
        let windowID = "22222222-2222-2222-2222-222222222222"

        defer {
            CLIMockAcceptLoopRegistry.shared.stop(listenerFD: listenerFD)
            Darwin.close(listenerFD)
            unlink(socketPath)
            try? fileManager.removeItem(at: homeURL)
        }

        CLIMockAcceptLoopRegistry.shared.start(
            listenerFD: listenerFD,
            onConnection: { clientFD in
                defer { Darwin.close(clientFD) }
                cliMockServeLineFramedConnection(clientFD: clientFD) { line in
                    state.append(line)
                    guard let payload = Harness.jsonObject(line),
                          let id = payload["id"] as? String,
                          let method = payload["method"] as? String else {
                        return Harness.malformedRequestResponse(raw: line)
                    }

                    switch method {
                    case "workspace.create":
                        return Harness.v2Response(
                            id: id,
                            ok: true,
                            result: [
                                "workspace_id": workspaceID,
                                "window_id": windowID,
                                "surface_id": surfaceID,
                            ]
                        )
                    case "surface.list":
                        return Harness.v2Response(
                            id: id,
                            ok: true,
                            result: [
                                "surfaces": [[
                                    "id": surfaceID,
                                    "ref": "surface:1",
                                    "index": 1,
                                    "focused": true,
                                ]],
                            ]
                        )
                    case "workspace.remote.configure":
                        return Harness.v2Response(
                            id: id,
                            ok: true,
                            result: ["remote": ["state": "connected"]]
                        )
                    default:
                        return Harness.v2Response(
                            id: id,
                            ok: false,
                            error: [
                                "code": "unexpected_method",
                                "message": "Unexpected method \(method)",
                            ]
                        )
                    }
                }
            },
            onListenerClosed: {}
        )

        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("BREE_") {
            environment.removeValue(forKey: key)
        }
        environment["BREE_SOCKET_PATH"] = socketPath
        environment["BREE_CLI_SENTRY_DISABLED"] = "1"
        environment["HOME"] = homeURL.path
        environment["CFFIXED_USER_HOME"] = homeURL.path
        environment["XDG_CONFIG_HOME"] = homeURL.appendingPathComponent("config").path
        environment["XDG_DATA_HOME"] = homeURL.appendingPathComponent("data").path
        environment["XDG_STATE_HOME"] = homeURL.appendingPathComponent("state").path

        let result = Harness.runProcess(
            executablePath: cliPath,
            arguments: ["ssh", "--no-focus", "example.test"] + sshArguments,
            environment: environment,
            timeout: 5
        )
        let sawTerminalRequest = waitForRemoteCommandMockSocketCommand(in: state) { line in
            line.contains(#""method":"workspace.remote.configure""#)
        }
        #expect(
            sawTerminalRequest,
            "Expected workspace.remote.configure, saw \(state.snapshot())"
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        #expect(result.status == 0, Comment(rawValue: result.stderr))
        #expect(result.stderr.isEmpty, Comment(rawValue: result.stderr))

        return RemoteCommandMockedSSHRun(
            requests: state.snapshot().compactMap(Harness.jsonObject)
        )
    }

    private static func waitForRemoteCommandMockSocketCommand(
        in state: Harness.MockSocketServerState,
        timeout: TimeInterval = 5,
        predicate: (String) -> Bool
    ) -> Bool {
        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            if state.snapshot().contains(where: predicate) {
                return true
            }
            RunLoop.current.run(until: Date.now.addingTimeInterval(0.01))
        }
        return state.snapshot().contains(where: predicate)
    }

    private static func decodedReusableStartupScript(from command: String) -> String? {
        SSHStartupCommandTestSupport.decodedScript(in: command)
    }

    private static func params(
        for method: String,
        in requests: [[String: Any]]
    ) -> [String: Any]? {
        requests
            .first { $0["method"] as? String == method }?["params"] as? [String: Any]
    }
}
