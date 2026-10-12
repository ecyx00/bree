import XCTest
import Darwin

extension CLINotifyProcessIntegrationRegressionTests {
    func testSSHCommandGlobalWindowOverridesCallerEnvironment() throws {
        let cliPath = try bundledCLIPath()
        let socketPath = makeSocketPath("ssh-global-window")
        let listenerFD = try bindUnixSocket(at: socketPath)
        let state = MockSocketServerState()
        let workspaceID = "11111111-1111-1111-1111-111111111111"
        let workspaceRef = "workspace:8"
        let windowID = "22222222-2222-2222-2222-222222222222"
        let callerWorkspaceID = "33333333-3333-3333-3333-333333333333"
        let callerSurfaceID = "44444444-4444-4444-4444-444444444444"
        let surfaceID = "55555555-5555-5555-5555-555555555555"

        defer {
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let serverHandled = startMockServer(listenerFD: listenerFD, state: state) { line in
            guard let payload = self.jsonObject(line),
                  let id = payload["id"] as? String,
                  let method = payload["method"] as? String else {
                return self.malformedRequestResponse(raw: line)
            }

            switch method {
            case "window.focus":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
                return self.v2Response(id: id, ok: true, result: ["window_id": windowID])
            case "workspace.ssh.open":
                let params = payload["params"] as? [String: Any] ?? [:]
                XCTAssertEqual(params["window_id"] as? String, windowID)
                XCTAssertEqual(params["destination"] as? String, "cmux-macmini")
                XCTAssertEqual(params["focus"] as? Bool, false)
                XCTAssertNil(params["workspace_id"])
                XCTAssertNil(params["surface_id"])
                return self.v2Response(
                    id: id,
                    ok: true,
                    result: [
                        "workspace_id": workspaceID,
                        "workspace_ref": workspaceRef,
                        "surface_id": surfaceID,
                        "surface_ref": "surface:3",
                        "window_id": windowID,
                    ]
                )
            default:
                return self.v2Response(
                    id: id,
                    ok: false,
                    error: ["code": "unexpected", "message": "Unexpected method \(method)"]
                )
            }
        }

        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_SOCKET_PATH"] = socketPath
        environment["CMUX_WORKSPACE_ID"] = callerWorkspaceID
        environment["CMUX_SURFACE_ID"] = callerSurfaceID
        environment["CMUX_CLI_SENTRY_DISABLED"] = "1"
        environment["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

        let result = runProcess(
            executablePath: cliPath,
            arguments: [
                "--window", windowID,
                "ssh",
                "--no-focus",
                "cmux-macmini",
            ],
            environment: environment,
            timeout: 5
        )

        wait(for: [serverHandled], timeout: 5)
        XCTAssertFalse(result.timedOut, result.stderr)
        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stdout, "OK \(workspaceRef) surface:3\n")
        XCTAssertTrue(result.stderr.isEmpty, result.stderr)

        let requests = try state.commands.map { line -> [String: Any] in
            let data = try XCTUnwrap(line.data(using: .utf8))
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data, options: []) as? [String: Any])
        }
        XCTAssertEqual(
            requests.compactMap { $0["method"] as? String },
            ["window.focus", "workspace.ssh.open"]
        )
    }
}
