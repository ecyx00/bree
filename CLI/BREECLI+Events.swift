import CoreFoundation
import BreeControlSocket
import Darwin
import Foundation

private struct EventStreamLimitReached: Error {}
private struct EventStreamSnapshotCaptured: Error {}

extension BREECLI {
    private struct EventsCommandOptions {
        var afterSeq: Int64?
        var cursorFile: String?
        var names: [String] = []
        var categories: [String] = []
        var reconnect = false
        var limit: Int?
        var timeout: TimeInterval?
        var snapshotOnly = false
        var printAck = true
        var printHeartbeats = true
    }

    func runEventsCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?
    ) throws {
        var options = try parseEventsOptions(commandArgs)
        if options.afterSeq == nil, let cursorFile = options.cursorFile {
            options.afterSeq = try readEventCursor(from: cursorFile)
        }

        var lastSeq = options.afterSeq
        var emittedEvents = 0
        // The --timeout budget is measured on a MONOTONIC clock so a
        // wall-clock change (NTP step, timezone, manual set) can neither
        // expire the whole command instantly nor extend it indefinitely.
        // The socket layer takes wall-clock Dates, so each blocking call
        // derives a fresh short-lived Date from the monotonic remainder;
        // a wall jump can then only skew the single wait in flight, never
        // the accumulated budget.
        let budgetClock = ContinuousClock()
        let budgetDeadline = options.timeout.map { budgetClock.now.advanced(by: .seconds($0)) }
        func remainingBudget() -> TimeInterval? {
            guard let budgetDeadline else { return nil }
            let remaining = budgetClock.now.duration(to: budgetDeadline)
            let seconds = Double(remaining.components.seconds)
                + Double(remaining.components.attoseconds) / 1e18
            return max(0, seconds)
        }
        func socketDeadline() -> Date? {
            remainingBudget().map { Date(timeIntervalSinceNow: $0) }
        }
        func timeoutError() -> CLIError {
            CLIError(message: String(
                localized: "cli.events.error.timeout",
                defaultValue: "Timed out waiting for a matching event"
            ))
        }

        while true {
            if let remaining = remainingBudget(), remaining <= 0 {
                throw timeoutError()
            }
            let client = SocketClient(path: socketPath)
            do {
                if let connectDeadline = socketDeadline() {
                    try client.connect(deadline: connectDeadline)
                } else {
                    try client.connect()
                }
                // Connection setup may have consumed the rest of the budget;
                // re-check before starting authentication so it always gets a
                // non-negative timeout.
                let authRemaining = remainingBudget()
                if let authRemaining, authRemaining <= 0 {
                    throw timeoutError()
                }
                try authenticateClientIfNeeded(
                    client,
                    explicitPassword: explicitPassword,
                    socketPath: socketPath,
                    responseTimeout: authRemaining,
                    deadline: socketDeadline()
                )

                var params: [String: Any] = [
                    "include_heartbeats": true
                ]
                if let lastSeq {
                    params["after_seq"] = NSNumber(value: lastSeq)
                }
                if !options.names.isEmpty {
                    params["names"] = options.names
                }
                if !options.categories.isEmpty {
                    params["categories"] = options.categories
                }

                try client.streamV2(
                    method: "events.stream",
                    params: params,
                    deadline: socketDeadline()
                ) { line in
                    guard !line.isEmpty else { return }
                    let frame = try parseEventStreamFrame(line)
                    let type = frame["type"] as? String ?? ""

                    let eventSequence: Int64?
                    if type == "event" {
                        guard let seq = int64Value(frame["seq"]) else {
                            throw CLIError(message: "Invalid event stream frame: event missing numeric seq")
                        }
                        eventSequence = seq
                    } else {
                        eventSequence = nil
                    }

                    let shouldPrint =
                        (type != "ack" || options.printAck)
                        && (type != "heartbeat" || options.printHeartbeats)
                    if shouldPrint {
                        print(line)
                        fflush(stdout)
                    }

                    if type == "ack", options.snapshotOnly {
                        throw EventStreamSnapshotCaptured()
                    }

                    if let eventSequence {
                        if let cursorFile = options.cursorFile {
                            try writeEventCursor(eventSequence, to: cursorFile)
                        }
                        lastSeq = eventSequence
                        emittedEvents += 1
                        if let limit = options.limit, emittedEvents >= limit {
                            throw EventStreamLimitReached()
                        }
                    }
                }
            } catch is EventStreamSnapshotCaptured {
                client.close()
                return
            } catch is EventStreamLimitReached {
                client.close()
                return
            } catch {
                client.close()
                if let remaining = remainingBudget(), remaining <= 0 {
                    throw timeoutError()
                }
                guard options.reconnect, isTransientEventStreamError(error) else {
                    throw error
                }
                let remaining = remainingBudget() ?? 1
                guard remaining > 0 else {
                    throw timeoutError()
                }
                waitBeforeReconnectingEventStream(maximumDelay: remaining)
                continue
            }
        }
    }

    func isTransientEventStreamError(_ error: Error) -> Bool {
        // The decision itself lives in BreeControlSocket
        // (`EventStreamFailure.isTransient`) so it can be unit-tested without the
        // CLI target; this wrapper only maps CLI spellings onto it.
        if let cliError = error as? CLIError {
            return EventStreamFailure(
                socketFailureKind: cliError.socketFailureKind == .receiveTimeoutConfiguration
                    ? .receiveTimeoutConfiguration
                    : nil,
                message: cliError.message
            ).isTransient
        }
        return EventStreamFailure(
            message: "",
            untypedDescription: String(describing: error)
        ).isTransient
    }

    func waitBeforeReconnectingEventStream(maximumDelay: TimeInterval = 1) {
        let delay = min(1, max(0, maximumDelay))
        guard delay > 0 else { return }
        // This retry path runs on the CLI's synchronous command thread, which
        // pumps no run loop: a Timer + RunLoop.run() wait can spin or park
        // with `didFire` as its only exit. A bounded thread sleep is the
        // deterministic wait; the caller already clamps the delay to the
        // command's remaining --timeout budget, and killing the process (the
        // CLI's only cancellation) interrupts it.
        Thread.sleep(forTimeInterval: delay)
    }

    private func parseEventsOptions(_ args: [String]) throws -> EventsCommandOptions {
        var options = EventsCommandOptions()
        var index = 0
        while index < args.count {
            let arg = args[index]
            func requireValue() throws -> String {
                guard index + 1 < args.count else {
                    throw CLIError(message: "\(arg) requires a value")
                }
                index += 1
                return args[index]
            }

            switch arg {
            case "--after", "--after-seq":
                let raw = try requireValue()
                guard let seq = Int64(raw), seq >= 0 else {
                    throw CLIError(message: "\(arg) must be a non-negative integer")
                }
                options.afterSeq = seq
            case "--cursor-file":
                options.cursorFile = try requireValue()
            case "--name":
                options.names.append(try requireValue())
            case "--category":
                options.categories.append(try requireValue())
            case "--reconnect":
                options.reconnect = true
            case "--limit":
                let raw = try requireValue()
                guard let limit = Int(raw), limit > 0 else {
                    throw CLIError(message: "--limit must be greater than 0")
                }
                options.limit = limit
            case "--timeout":
                let raw = try requireValue()
                guard let timeout = TimeInterval(raw),
                      timeout.isFinite,
                      timeout > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.events.error.invalidTimeout",
                        defaultValue: "--timeout must be greater than 0"
                    ))
                }
                options.timeout = timeout
            case "--snapshot":
                options.snapshotOnly = true
            case "--no-ack":
                options.printAck = false
            case "--no-heartbeat", "--no-heartbeats":
                options.printHeartbeats = false
            default:
                throw CLIError(message: "Unknown events option: \(arg)")
            }
            index += 1
        }
        return options
    }

    private func parseEventStreamFrame(_ line: String) throws -> [String: Any] {
        guard let data = line.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CLIError(message: "Invalid event stream frame: \(line)")
        }
        if let ok = object["ok"] as? Bool, ok == false {
            let error = object["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "event stream error"
            throw CLIError(message: message)
        }
        return object
    }

    private func readEventCursor(from path: String) throws -> Int64? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw CLIError(message: "Failed to read events cursor file \(url.path): \(String(describing: error))")
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sequence = Int64(trimmed), sequence >= 0 else {
            throw CLIError(message: "Malformed events cursor file \(url.path): expected a non-negative sequence number")
        }
        return sequence
    }

    private func writeEventCursor(_ seq: Int64, to path: String) throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "\(seq)\n".write(to: url, atomically: true, encoding: .utf8)
    }

    private func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let type = String(cString: number.objCType)
            guard ["c", "C", "s", "S", "i", "I", "l", "L", "q", "Q"].contains(type) else { return nil }
            let int64 = number.int64Value
            guard number.compare(NSNumber(value: int64)) == .orderedSame else { return nil }
            return int64
        }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}

// MARK: - agent wait / wait-output

private struct WaitStreamFinished: Error {}

/// Exit codes shared by `agent wait` and `wait-output` (documented in docs/cli-contract.md).
private enum WaitExit {
    static let timedOut: Int32 = 124
    static let surfaceClosed: Int32 = 2
}

extension BREECLI {
    static let agentWaitUsage = """
    Usage: bree agent wait [<surface>|--surface <id|ref|index>] [--workspace <id|ref|index>] --until idle|needs-input [--timeout <seconds>]

    Wait until the agent on a terminal surface becomes idle or needs input.
    Returns at once when it already is. Without --timeout it waits forever.

    Exit status: 0 reached, 1 error (including a surface with no agent),
    2 surface closed while waiting, 124 timed out.
    """

    static let waitOutputUsage = """
    Usage: bree wait-output --regex <pattern> [--workspace <id|ref|index>] [--surface <id|ref|index>] [--timeout <seconds>]

    Wait until a line matching the regular expression newly appears on the visible
    screen of a terminal surface, print that line and exit 0. Lines that already
    matched when the command started do not count. Without --timeout it waits forever.

    Exit status: 0 matched, 1 error, 2 surface closed while waiting, 124 timed out.
    """

    private func parseWaitTimeout(_ raw: String?) throws -> TimeInterval? {
        guard let raw else { return nil }
        guard let seconds = Double(raw), seconds > 0 else {
            throw CLIError(message: "--timeout must be greater than 0")
        }
        return seconds
    }

    func runAgentWaitCommand(commandArgs: [String], client: SocketClient, socketPath: String, explicitPassword: String?) throws {
        let (workspaceFlag, rem00) = parseOption(commandArgs, name: "--workspace")
        let (surfaceFlag, rem0) = parseOption(rem00, name: "--surface")
        let (untilRaw, rem1) = parseOption(rem0, name: "--until")
        let (timeoutRaw, rem2) = parseOption(rem1, name: "--timeout")
        let positional = rem2.filter { $0 != "--json" }
        guard positional.count <= 1, !positional.contains(where: { $0.hasPrefix("-") }) else {
            throw CLIError(message: Self.agentWaitUsage)
        }
        let target: String
        switch untilRaw?.lowercased() {
        case "idle": target = "idle"
        case "needs-input", "needsinput", "needs_input": target = "needsInput"
        default: throw CLIError(message: Self.agentWaitUsage)
        }
        let timeout = try parseWaitTimeout(timeoutRaw)
        let rawSurface = surfaceFlag ?? positional.first
            ?? (workspaceFlag == nil ? ProcessInfo.processInfo.environment["BREE_SURFACE_ID"] : nil)
        var params: [String: Any] = [:]
        let wsId = try normalizeWorkspaceHandle(workspaceFlag, client: client)
        if let wsId { params["workspace_id"] = wsId }
        if let surface = try normalizeSurfaceHandle(rawSurface, client: client, workspaceHandle: wsId) {
            params["surface_id"] = surface
        }

        let state = try client.sendV2(method: "agent.state", params: params)
        guard state["agent"] as? Bool == true else {
            throw CLIError(message: "No agent reports state on this surface")
        }
        let surfaceId = (state["surface_id"] as? String) ?? ""
        let workspaceId = (state["workspace_id"] as? String) ?? ""
        let counterKey = target == "idle" ? "idle_seq" : "needs_input_seq"
        let baseline = (state[counterKey] as? NSNumber)?.intValue ?? 0
        let label = target == "idle" ? "idle" : "waiting for input"
        if state["lifecycle"] as? String == target {
            print("Agent is \(label)")
            return
        }

        let budgetClock = ContinuousClock()
        let deadline = timeout.map { budgetClock.now.advanced(by: .seconds($0)) }
        func remaining() -> TimeInterval? {
            guard let deadline else { return nil }
            let d = budgetClock.now.duration(to: deadline)
            return max(0, Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
        }
        func socketDeadline() -> Date? { remaining().map { Date(timeIntervalSinceNow: $0) } }
        func timedOut() -> CLIError {
            CLIError(
                message: "Timed out after \(timeoutRaw ?? "")s waiting for the agent to become \(label)",
                exitCode: WaitExit.timedOut
            )
        }
        func closed() -> CLIError {
            CLIError(message: "Surface closed while waiting for the agent", exitCode: WaitExit.surfaceClosed)
        }

        // A second connection: the first one stays a plain request channel.
        let stream = SocketClient(path: socketPath)
        defer { stream.close() }
        do {
            if let d = socketDeadline() { try stream.connect(deadline: d) } else { try stream.connect() }
            try authenticateClientIfNeeded(
                stream,
                explicitPassword: explicitPassword,
                socketPath: socketPath,
                responseTimeout: remaining(),
                deadline: socketDeadline()
            )
            var streamParams: [String: Any] = [
                "names": ["agent.lifecycle.changed", "surface.closed", "pane.closed", "workspace.closed"],
                "include_heartbeats": false,
            ]
            if let seq = state["event_seq"] as? NSNumber { streamParams["after_seq"] = seq }
            var outcome: CLIError?
            do {
                try stream.streamV2(method: "events.stream", params: streamParams, deadline: socketDeadline()) { line in
                    guard !line.isEmpty else { return }
                    let frame = try parseEventStreamFrame(line)
                    guard frame["type"] as? String == "event" else { return }
                    let payload = frame["payload"] as? [String: Any] ?? [:]
                    switch frame["name"] as? String {
                    case "surface.closed" where frame["surface_id"] as? String == surfaceId,
                         "workspace.closed" where frame["workspace_id"] as? String == workspaceId:
                        outcome = closed()
                        throw WaitStreamFinished()
                    case "pane.closed":
                        if (payload["closed_surface_ids"] as? [String])?.contains(surfaceId) == true {
                            outcome = closed()
                            throw WaitStreamFinished()
                        }
                    case "agent.lifecycle.changed" where frame["surface_id"] as? String == surfaceId:
                        if payload["agent"] as? Bool == false {
                            outcome = CLIError(message: "The agent exited while waiting")
                            throw WaitStreamFinished()
                        }
                        let seq = (payload[counterKey] as? NSNumber)?.intValue ?? 0
                        if payload["lifecycle"] as? String == target || seq > baseline {
                            throw WaitStreamFinished()
                        }
                    default: break
                    }
                }
            } catch is WaitStreamFinished {
                if let outcome { throw outcome }
                print("Agent is \(label)")
                return
            }
            // The stream ended without a verdict: the app closed it or the deadline passed.
            if let r = remaining(), r <= 0 { throw timedOut() }
            throw CLIError(message: "Event stream ended before the agent became \(label)")
        } catch let error as CLIError where error.exitCode != 1 {
            throw error
        } catch {
            if let r = remaining(), r <= 0 { throw timedOut() }
            throw error
        }
    }

    func runWaitOutputCommand(commandArgs: [String], client: SocketClient, windowOverride: String?) throws {
        let (wsArg, rem0) = parseOption(commandArgs, name: "--workspace")
        let (sfArg, rem1) = parseOption(rem0, name: "--surface")
        let (windowOpt, rem2) = parseOption(rem1, name: "--window")
        let (regexRaw, rem3) = parseOption(rem2, name: "--regex")
        let (timeoutRaw, rem4) = parseOption(rem3, name: "--timeout")
        let trailing = rem4.filter { $0 != "--json" }
        guard let regexRaw, trailing.isEmpty else { throw CLIError(message: Self.waitOutputUsage) }
        guard let regex = try? NSRegularExpression(pattern: regexRaw, options: [.anchorsMatchLines]) else {
            throw CLIError(message: "Invalid regular expression: \(regexRaw)")
        }
        let timeout = try parseWaitTimeout(timeoutRaw)

        let windowRaw = windowOpt ?? windowOverride
        let workspaceArg = wsArg ?? Self.callerWorkspaceForSurfaceHandle(sfArg, windowRaw: windowRaw)
        let surfaceArg = sfArg ?? (wsArg == nil && windowRaw == nil ? ProcessInfo.processInfo.environment["BREE_SURFACE_ID"] : nil)
        var params: [String: Any] = [:]
        let winId = try normalizeWindowHandle(windowRaw, client: client)
        if let winId { params["window_id"] = winId }
        let wsId = try normalizeWorkspaceHandle(workspaceArg, client: client, windowHandle: winId)
        if let wsId { params["workspace_id"] = wsId }
        if let sfId = try normalizeSurfaceHandle(surfaceArg, client: client, workspaceHandle: wsId, windowHandle: winId) {
            params["surface_id"] = sfId
        }

        func matches(_ text: String) -> [String] {
            text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).filter {
                regex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil
            }
        }
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now.advanced(by: .seconds($0)) }
        // The visible screen is polled only while this command runs. Lines that
        // matched at the start (such as the typed command itself) are the baseline;
        // it follows the count down when the screen scrolls.
        var baseline = matches(((try client.sendV2(method: "surface.read_text", params: params))["text"] as? String) ?? "").count
        while true {
            if let deadline, clock.now >= deadline {
                throw CLIError(
                    message: "Timed out after \(timeoutRaw ?? "")s waiting for output matching \(regexRaw)",
                    exitCode: WaitExit.timedOut
                )
            }
            Thread.sleep(forTimeInterval: 0.25)
            let text: String
            do {
                text = ((try client.sendV2(method: "surface.read_text", params: params))["text"] as? String) ?? ""
            } catch let error as CLIError where error.v2Code == "not_found" {
                throw CLIError(message: "Surface closed while waiting for output", exitCode: WaitExit.surfaceClosed)
            }
            let found = matches(text)
            if found.count > baseline, let line = found.last {
                print(line)
                return
            }
            baseline = min(baseline, found.count)
        }
    }
}

extension BREECLI {
    static let snapshotsUsage = """
    Usage: bree snapshots list
           bree snapshots restore <id>

    list     Show the rolling layout snapshots, newest first (at most 24, one per 5 minutes of change).
    restore  Make a snapshot the saved layout. It applies on the next launch of Bree.
             Until Bree quits, the running app stops saving its own layout so the
             restored one is not overwritten; the layout it replaces is kept as a new snapshot.
    """

    func runSnapshotsCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let args = commandArgs.filter { $0 != "--json" }
        switch (args.first?.lowercased(), args.count) {
        case ("list", 1):
            let payload = try client.sendV2(method: "snapshots.list")
            if jsonOutput { print(jsonString(payload)); return }
            let entries = payload["snapshots"] as? [[String: Any]] ?? []
            if entries.isEmpty { print("No layout snapshots yet"); return }
            for entry in entries {
                print("\(entry["id"] as? String ?? "")  \(entry["date"] as? String ?? "")  \(entry["bytes"] as? Int ?? 0) bytes")
            }
        case ("restore", 2):
            let payload = try client.sendV2(method: "snapshots.restore", params: ["id": args[1]])
            if jsonOutput { print(jsonString(payload)); return }
            print("""
            Snapshot \(args[1]) is now the saved layout. It applies on the next launch: quit Bree and open it again.
            Until you quit, this running app no longer saves its layout, so changes made now are not kept.
            """)
        default:
            throw CLIError(message: Self.snapshotsUsage)
        }
    }
}
