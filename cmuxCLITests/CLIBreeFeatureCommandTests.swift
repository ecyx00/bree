import Darwin
import Foundation
import Testing

/// Argument parsing for `cmux bottom-panel`, `attention`, `quick-view` and `pins`.
/// Invalid input must fail before the CLI connects to the socket; valid input must
/// reach the socket as the documented v2 method and params.
@Suite(.serialized)
struct CLIBreeFeatureCommandTests {
    private static let timeout: TimeInterval = 60

    // MARK: - Mapping to socket requests

    @Test func bottomPanelSubcommandsMapToTheirMethods() throws {
        for sub in ["open", "close", "toggle", "status"] {
            let run = try runCLI(arguments: ["bottom-panel", sub])
            #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
            #expect(run.requests.last?["method"] as? String == "bottom_panel.\(sub)")
        }
    }

    @Test func bottomPanelFocusAndWorkspaceFlagsReachTheSocket() throws {
        let workspace = "11111111-1111-1111-1111-111111111111"
        let run = try runCLI(arguments: ["bottom-panel", "open", "--focus", "--workspace", workspace])
        #expect(run.result.status == 0, Comment(rawValue: run.result.stderr + run.result.stdout))
        let params = try #require(run.requests.last?["params"] as? [String: Any])
        #expect(params["focus"] as? Bool == true)
        #expect(params["workspace_id"] as? String == workspace)
    }

    @Test func bottomPanelStatusDoesNotRequestFocus() throws {
        let run = try runCLI(arguments: ["bottom-panel", "status"])
        let params = try #require(run.requests.last?["params"] as? [String: Any])
        #expect(params["focus"] == nil)
    }

    @Test func attentionClearPassesTheOptionalId() throws {
        let all = try runCLI(arguments: ["attention", "clear"])
        #expect(all.requests.last?["method"] as? String == "attention.clear")
        #expect((all.requests.last?["params"] as? [String: Any])?["id"] == nil)

        let one = try runCLI(arguments: ["attention", "clear", "abc|changes"])
        #expect((one.requests.last?["params"] as? [String: Any])?["id"] as? String == "abc|changes")
    }

    @Test func quickViewOpenSendsAnAbsolutePath() throws {
        let absolute = try runCLI(arguments: ["quick-view", "open", "/usr/./share//note.md"])
        #expect(absolute.requests.last?["method"] as? String == "quick_view.open")
        #expect((absolute.requests.last?["params"] as? [String: Any])?["path"] as? String == "/usr/share/note.md")

        let relative = try runCLI(arguments: ["quick-view", "open", "note.md"])
        let sent = try #require((relative.requests.last?["params"] as? [String: Any])?["path"] as? String)
        #expect(sent.hasPrefix("/") && sent.hasSuffix("/note.md"))
    }

    @Test func pinsSubcommandsAndAliasesMapToTheirMethods() throws {
        let cases: [([String], String)] = [
            (["pins", "list"], "pins.list"),
            (["pins", "ls"], "pins.list"),
            (["pins", "add", "/tmp/a.md"], "pins.add"),
            (["pins", "remove", "/tmp/a.md"], "pins.remove"),
            (["pins", "rm", "/tmp/a.md"], "pins.remove"),
        ]
        for (arguments, method) in cases {
            let run = try runCLI(arguments: arguments)
            #expect(run.requests.last?["method"] as? String == method, Comment(rawValue: arguments.joined(separator: " ")))
        }
    }

    // MARK: - Rejected before connecting

    @Test func invalidArgumentsFailWithoutReachingTheSocket() throws {
        let invalid: [[String]] = [
            ["bottom-panel"],
            ["bottom-panel", "sideways"],
            ["bottom-panel", "status", "--focus"],
            ["bottom-panel", "open", "--focus=false"],
            ["bottom-panel", "open", "--workspace"],
            ["bottom-panel", "open", "--bogus"],
            ["bottom-panel", "open", "extra"],
            ["attention"],
            ["attention", "list", "--workspace", "workspace:1"],
            ["attention", "clear", "a", "b"],
            ["quick-view", "open"],
            ["quick-view", "open", "a.md", "b.md"],
            ["quick-view", "close", "a.md"],
            ["pins", "add"],
            ["pins", "list", "extra"],
        ]
        for arguments in invalid {
            let run = try runCLI(arguments: arguments)
            #expect(run.result.status != 0, Comment(rawValue: arguments.joined(separator: " ")))
            #expect(run.featureMethods.isEmpty, Comment(rawValue: arguments.joined(separator: " ")))
        }
    }

    @Test func helpPrintsUsageWithoutReachingTheSocket() throws {
        for command in ["bottom-panel", "attention", "quick-view", "pins"] {
            let run = try runCLI(arguments: [command, "--help"])
            #expect(run.result.status == 0, Comment(rawValue: run.result.stderr))
            #expect(run.result.stdout.contains("cmux \(command) <"), Comment(rawValue: run.result.stdout))
            #expect(run.featureMethods.isEmpty)
        }
    }

    // MARK: - Harness

    private struct Run {
        let result: CLIHookProcessRunner.Result
        let requests: [[String: Any]]

        /// Requests for the methods under test; the CLI may send unrelated ones of its own.
        var featureMethods: [String] {
            requests.compactMap { $0["method"] as? String }.filter { method in
                ["bottom_panel.", "attention.", "quick_view.", "pins."].contains { method.hasPrefix($0) }
            }
        }
    }

    private func runCLI(arguments: [String]) throws -> Run {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-cli-bree-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let socketPath = makeCodexHookSocketPath("bree")
        let listenerFD = try bindCodexHookUnixSocket(at: socketPath)
        let recorder = RequestRecorder()
        let server = Self.startMockServer(listenerFD: listenerFD, recorder: recorder)
        defer {
            server.stop.set()
            _ = server.done.wait(timeout: .now() + 5)
            Darwin.close(listenerFD)
            unlink(socketPath)
        }

        let result = CLIHookProcessRunner.run(
            executablePath: try BundledCLITestSupport.bundledCLIPath(for: CLITestBundleAnchor.self),
            arguments: arguments,
            environment: [
                "CMUX_SOCKET_PATH": socketPath,
                "CMUX_SOCKET_PASSWORD": "",
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "CFFIXED_USER_HOME": home.path,
                "HOME": home.path,
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
            ],
            standardInput: nil,
            timeout: Self.timeout
        )
        #expect(!result.timedOut, Comment(rawValue: result.stderr))
        return Run(result: result, requests: recorder.requests())
    }

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []

        func record(_ line: String) {
            lock.lock()
            lines.append(line)
            lock.unlock()
        }

        func requests() -> [[String: Any]] {
            lock.lock()
            let snapshot = lines
            lock.unlock()
            return snapshot.compactMap(codexHookJSONObject)
        }
    }

    private final class StopFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func set() {
            lock.lock()
            value = true
            lock.unlock()
        }
    }

    /// Accepts clients until `stop` is set and answers every v2 request with an
    /// empty successful result. Only requests the CLI actually sends are recorded.
    private static func startMockServer(
        listenerFD: Int32,
        recorder: RequestRecorder
    ) -> (done: DispatchSemaphore, stop: StopFlag) {
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { done.signal() }
            while !stop.isSet {
                var pollFD = pollfd(fd: listenerFD, events: Int16(POLLIN), revents: 0)
                let ready = Darwin.poll(&pollFD, 1, 100)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return
                }
                guard ready > 0 else { continue }
                let clientFD = Darwin.accept(listenerFD, nil, nil)
                if clientFD < 0 {
                    if errno == EINTR { continue }
                    return
                }
                serve(clientFD: clientFD, recorder: recorder)
            }
        }
        return (done, stop)
    }

    private static func serve(clientFD: Int32, recorder: RequestRecorder) {
        defer { Darwin.close(clientFD) }
        guard ignoreSIGPIPE(onAcceptedFixtureSocket: clientFD) else { return }
        var pending = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(clientFD, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return
            }
            if count == 0 { return }
            pending.append(buffer, count: count)
            while let newline = pending.firstRange(of: Data([0x0A])) {
                let lineData = pending.subdata(in: 0..<newline.lowerBound)
                pending.removeSubrange(0...newline.lowerBound)
                guard let line = String(data: lineData, encoding: .utf8) else { continue }
                recorder.record(line)
                let id = (codexHookJSONObject(line)?["id"] as? String) ?? "unknown"
                let response = codexHookV2Response(id: id, ok: true, result: ["open": false])
                guard writeAllToFixtureSocket(response + "\n", fd: clientFD) else { return }
            }
        }
    }
}
