import Foundation

/// `bree queue`, `bree ask-human` and `bree agent explain`.
///
/// Argument parsing is pure and runs before the CLI connects (like the other Bree
/// feature commands), so a typo fails without a running app. The socket side is
/// Sources/TerminalController+AgentQueueExplain.swift (`agent.queue.*`,
/// `agent.explain`) and the existing `feed.push` / `feed.question.reply` path
/// (`ask-human`).
extension CMUXCLI {
    static let agentQueueAskCommands: Set<String> = ["queue", "ask-human"]

    /// Longest single `feed.push` wait. The app caps it at 120 s; stay below.
    static let askHumanChunkSeconds: TimeInterval = 110

    static let queueUsage = String(
        localized: "cli.queue.usage",
        defaultValue: """
        Usage: bree queue "<text>" [--surface <id|ref|index>]
               bree queue list [--surface <ref>]
               bree queue clear [--surface <ref>]

        Hand a message to the person without typing over them. The text waits in app memory (lost on quit; at most 20 per pane) and is typed with Enter, one message per time the pane's agent goes idle, and only while the prompt holds no draft or dialog. If the agent is already idle with a free prompt, the first message is typed at once.

        Without --surface the pane this command runs in (CMUX_SURFACE_ID) is used, else the focused pane. To queue the literal text "list" or "clear", put -- before it.

        Flags:
          --surface <id|ref|index>   Target terminal pane
          --json                     Print the socket reply as JSON

        Example:
          bree queue "run the tests again"
          bree queue list
        """
    )

    static let askHumanUsage = String(
        localized: "cli.askHuman.usage",
        defaultValue: """
        Usage: bree ask-human "<question>" -o <option> -o <option> [-o ...] [--timeout <seconds>]

        Ask the person a single-choice question. It appears in the Agent Inbox (and the Attention Center when run inside a pane). Prints the chosen option and exits 0.

        Exit codes:
          0   answered (the option is printed)
          2   --timeout elapsed without an answer
          3   the question was dismissed

        Flags:
          -o, --option <text>      An answer choice (repeat; at least two)
          --timeout <seconds>      Give up after this long (default: wait until answered)
          --json                   Print {"answer": ...} as JSON

        Example:
          choice=$(bree ask-human "Deploy now?" -o Yes -o Later --timeout 600)
        """
    )

    static let agentExplainUsage = String(
        localized: "cli.agentExplain.usage",
        defaultValue: """
        Usage: bree agent explain [--surface <id|ref|index>] [--json]

        Show why a pane shows its agent state: the current state, since when, the agent and hook event that set it, and the last 5 transitions, read from the Agent Journal. Read-only.

        Without --surface the pane this command runs in (CMUX_SURFACE_ID) is used, else the focused pane.
        """
    )

    // MARK: - Parsing

    enum QueueAction: Equatable {
        case add(String), list, clear
    }

    struct QueueRequest: Equatable {
        var action: QueueAction
        var surface: String?
    }

    struct AskHumanRequest: Equatable {
        var question: String
        var options: [String]
        var timeout: TimeInterval?
    }

    private static func flagValue(_ name: String, _ args: [String], _ index: inout Int) throws -> String {
        guard index < args.count, !args[index].hasPrefix("--"), !args[index].isEmpty else {
            throw CLIError(message: String(
                localized: "cli.bree.error.flagRequiresValue",
                defaultValue: "\(name) requires a value"
            ))
        }
        defer { index += 1 }
        return args[index]
    }

    private static func unexpectedArgument(_ arg: String, command: String) -> CLIError {
        CLIError(message: String(
            localized: "cli.bree.error.unexpectedArgument",
            defaultValue: "Unexpected argument '\(arg)' for bree \(command). Run bree \(command) --help for usage."
        ))
    }

    static func parseQueueArguments(_ args: [String]) throws -> QueueRequest {
        var surface: String?
        var words: [String] = []
        var literal = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if literal { words.append(arg); continue }
            switch arg {
            case "--": literal = true
            case "--json": continue
            case "--surface": surface = try flagValue(arg, args, &index)
            default:
                guard !arg.hasPrefix("--") else { throw unexpectedArgument(arg, command: "queue") }
                words.append(arg)
            }
        }
        guard let first = words.first else {
            throw CLIError(message: String(
                localized: "cli.queue.error.textRequired",
                defaultValue: "bree queue requires a message, or list / clear"
            ))
        }
        if !literal, first == "list" || first == "ls" || first == "clear" {
            if words.count > 1 { throw unexpectedArgument(words[1], command: "queue") }
            return QueueRequest(action: first == "clear" ? .clear : .list, surface: surface)
        }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.queue.error.textRequired",
                defaultValue: "bree queue requires a message, or list / clear"
            ))
        }
        return QueueRequest(action: .add(text), surface: surface)
    }

    static func parseAskHumanArguments(_ args: [String]) throws -> AskHumanRequest {
        var words: [String] = []
        var options: [String] = []
        var timeout: TimeInterval?
        var literal = false
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            if literal { words.append(arg); continue }
            switch arg {
            case "--": literal = true
            case "--json": continue
            case "-o", "--option":
                options.append(try flagValue(arg, args, &index))
            case "--timeout":
                let raw = try flagValue(arg, args, &index)
                guard let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 else {
                    throw CLIError(message: String(
                        localized: "cli.askHuman.error.invalidTimeout",
                        defaultValue: "--timeout must be a positive number of seconds"
                    ))
                }
                timeout = seconds
            default:
                guard !arg.hasPrefix("-") || arg == "-" else { throw unexpectedArgument(arg, command: "ask-human") }
                words.append(arg)
            }
        }
        let question = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw CLIError(message: String(
                localized: "cli.askHuman.error.questionRequired",
                defaultValue: "bree ask-human requires a question"
            ))
        }
        guard options.count >= 2, Set(options).count == options.count else {
            throw CLIError(message: String(
                localized: "cli.askHuman.error.optionsRequired",
                defaultValue: "bree ask-human requires at least two distinct options (-o)"
            ))
        }
        return AskHumanRequest(question: question, options: options, timeout: timeout)
    }

    static func parseAgentExplainArguments(_ args: [String]) throws -> String? {
        var surface: String?
        var index = 0
        while index < args.count {
            let arg = args[index]
            index += 1
            switch arg {
            case "--json": continue
            case "--surface": surface = try flagValue(arg, args, &index)
            default: throw unexpectedArgument(arg, command: "agent explain")
            }
        }
        return surface
    }

    /// Validates `queue` / `ask-human` / `agent explain` arguments before connecting.
    static func validateAgentQueueAskArguments(command: String, args: [String]) throws {
        switch command {
        case "queue": _ = try parseQueueArguments(args)
        case "ask-human": _ = try parseAskHumanArguments(args)
        default: break
        }
    }

    // MARK: - Running

    /// The target surface: `--surface`, else the calling pane, else nil (the app
    /// then uses the focused pane).
    private func agentQueueSurfaceParams(_ raw: String?, client: SocketClient) throws -> [String: Any] {
        let env = ProcessInfo.processInfo.environment
        let arg = raw ?? env["CMUX_SURFACE_ID"]
        var params: [String: Any] = [:]
        if let surface = try normalizeSurfaceHandle(arg, client: client) { params["surface_id"] = surface }
        return params
    }

    func runQueueCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let request = try Self.parseQueueArguments(commandArgs)
        var params = try agentQueueSurfaceParams(request.surface, client: client)
        let method: String
        switch request.action {
        case .add(let text): method = "agent.queue.add"; params["text"] = text
        case .list: method = "agent.queue.list"
        case .clear: method = "agent.queue.clear"
        }
        let payload = try client.sendV2(method: method, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        let count = payload["count"] as? Int ?? 0
        switch request.action {
        case .add:
            print((payload["delivered_now"] as? Bool) == true ? "typed" : "queued \(count)")
        case .list:
            for (index, message) in (payload["messages"] as? [String] ?? []).enumerated() {
                print("\(index + 1)\t\(message)")
            }
        case .clear:
            print("cleared \(payload["cleared"] as? Int ?? 0)")
        }
    }

    func runAskHumanCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool) throws {
        let request = try Self.parseAskHumanArguments(commandArgs)
        let env = ProcessInfo.processInfo.environment
        let requestId = UUID().uuidString
        let question: [String: Any] = [
            "question": request.question,
            "header": "Bree",
            "multiSelect": false,
            "options": request.options.map { ["label": $0] },
        ]
        var event: [String: Any] = [
            "session_id": "bree-ask-human-\(requestId)",
            "hook_event_name": "AskUserQuestion",
            "_source": "bree",
            "tool_name": "AskUserQuestion",
            "tool_input": ["questions": [question]],
            "_opencode_request_id": requestId,
            "cwd": FileManager.default.currentDirectoryPath,
        ]
        // Inside a pane the question attaches to it; outside, it is Inbox-only.
        if let workspace = env["CMUX_WORKSPACE_ID"], !workspace.isEmpty { event["workspace_id"] = workspace }
        if let surface = env["CMUX_SURFACE_ID"], !surface.isEmpty { event["surface_id"] = surface }

        let started = Date()
        while true {
            let remaining = request.timeout.map { $0 - Date().timeIntervalSince(started) }
            if let remaining, remaining < 0.25 { break }
            let wait = min(Self.askHumanChunkSeconds, remaining ?? Self.askHumanChunkSeconds)
            let payload = try client.sendV2(
                method: "feed.push",
                params: ["event": event, "wait_timeout_seconds": wait],
                responseTimeout: wait + 15
            )
            switch payload["status"] as? String {
            case "resolved":
                let decision = payload["decision"] as? [String: Any]
                guard let choice = (decision?["selections"] as? [String])?.first, !choice.isEmpty else {
                    cliWriteStderr(String(
                        localized: "cli.askHuman.dismissed",
                        defaultValue: "The question was dismissed.\n"
                    ))
                    exit(3)
                }
                if jsonOutput {
                    print(jsonString(["answer": choice]))
                } else {
                    print(choice)
                }
                return
            case "timed_out":
                continue
            default:
                throw CLIError(message: String(
                    localized: "cli.askHuman.error.notDelivered",
                    defaultValue: "The question could not be delivered to the app."
                ))
            }
        }
        cliWriteStderr(String(
            localized: "cli.askHuman.timedOut",
            defaultValue: "No answer before the timeout.\n"
        ))
        exit(2)
    }

    func runAgentExplainCommand(commandArgs: [String], client: SocketClient, jsonOutput: Bool, idFormat: CLIIDFormat) throws {
        let surface = try Self.parseAgentExplainArguments(commandArgs)
        let params = try agentQueueSurfaceParams(surface, client: client)
        let payload = try client.sendV2(method: "agent.explain", params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        func clock(_ ms: Any?) -> String {
            guard let value = (ms as? NSNumber)?.doubleValue else { return "?" }
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
        }
        func describe(_ t: [String: Any]) -> String {
            let hook = (t["hook_event"] as? String) ?? "-"
            let agent = (t["agent"] as? String) ?? "-"
            return "\(agent) via hook \(hook) (\(t["kind"] as? String ?? "-"), source \(t["source"] as? String ?? "-"))"
        }
        print("state: \(payload["state"] as? String ?? "unknown")")
        let agents = (payload["agents"] as? [String: String]) ?? [:]
        for key in agents.keys.sorted() { print("agent \(key): \(agents[key] ?? "")") }
        if let setBy = payload["set_by"] as? [String: Any] {
            let ago = (payload["since_ms"] as? NSNumber).map {
                max(0, Int(Date().timeIntervalSince1970 - $0.doubleValue / 1000))
            }
            print("since: \(clock(payload["since_ms"]))" + (ago.map { " (\($0)s ago)" } ?? ""))
            print("set by: \(describe(setBy))")
        } else if (payload["journal_available"] as? Bool) == false {
            print("journal: unavailable")
        } else {
            print("set by: no journal events for this pane")
        }
        if let queued = payload["queued"] as? Int, queued > 0 { print("queued: \(queued)") }
        let transitions = payload["transitions"] as? [[String: Any]] ?? []
        if !transitions.isEmpty { print("last transitions:") }
        for t in transitions {
            print("  \(clock(t["at_ms"]))  \(t["from"] as? String ?? "-") -> \(t["to"] as? String ?? "-")  \(describe(t))")
        }
    }
}
