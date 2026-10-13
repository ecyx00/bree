import Foundation

/// `bree recover` helpers.
extension BREECLI {
    private struct RecoverySession: Codable {
        let id: String
        let cwd: String?
        let lastMessage: String?
        let tasks: [RecoveryTask]?

        enum CodingKeys: String, CodingKey {
            case id, cwd, lastMessage = "last_message", tasks
        }
    }

    private struct RecoveryTask: Codable {
        let id: String
    }

    static let recoveryUsage = """
    Usage: bree recover [options]

    Find interrupted local Claude sessions through sr. Pass --session to open
    one exact session in an isolated workspace running sr codex.

    Options:
      --query <text>       Filter sessions by id, path, task, or transcript text
      --session <id>       Recover one exact session in a new workspace
      --limit <n>          Maximum search results (default: 4)
      --focus              Focus the last created workspace
      --json               Print the discovered sessions as JSON; do not launch
    """

    func runRecoveryCommand(
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        if hasHelpRequest(beforeSeparator: commandArgs) {
            print(Self.recoveryUsage)
            return
        }
        let (query, rem0) = parseOption(commandArgs, name: "--query")
        let (session, rem1) = parseOption(rem0, name: "--session")
        let (limitRaw, rem2) = parseOption(rem1, name: "--limit")
        var remainder = rem2
        let focus = remainder.contains("--focus")
        remainder.removeAll { $0 == "--focus" }
        try Self.recoverRejectUnexpected(remainder)
        let limit = try Self.recoverParseLimit(limitRaw ?? "4")
        guard limit <= 500 else { throw CLIError(message: "--limit must be 1...500") }
        let sessions = try loadRecoverySessions(query: query, limit: limit, session: session)
        if jsonOutput {
            print(String(data: try JSONEncoder().encode(sessions), encoding: .utf8) ?? "[]")
            return
        }
        if session == nil {
            if sessions.isEmpty { print("No recoverable sessions found.") }
            for item in sessions {
                print("\(item.id)\t\(item.cwd ?? "")\t\(item.lastMessage ?? "")")
            }
            return
        }
        let selected = session.map { id in sessions.filter { $0.id == id } } ?? sessions
        guard !selected.isEmpty else {
            throw CLIError(message: session.map { "Recovery session \($0) was not found." } ?? "No recoverable sessions found.")
        }
        for (index, item) in selected.prefix(limit).enumerated() {
            let prompt = try loadRecoveryPrompt(sessionID: item.id)
            let quotedPrompt = "'" + prompt.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
            let command = "sr codex \(quotedPrompt)"
            var args = ["--name", "Recover · \(item.id.prefix(8))", "--cwd", item.cwd ?? NSHomeDirectory(), "--command", command]
            if focus && index == min(selected.count, limit) - 1 {
                args += ["--focus", "true"]
            } else {
                args += ["--focus", "false"]
            }
            try runWorkspaceCreateCommand(
                commandName: "recover",
                commandArgs: args,
                client: client,
                jsonOutput: false,
                idFormat: idFormat,
                windowOverride: windowOverride,
                honorJSONOutput: false
            )
        }
    }

    private func loadRecoverySessions(query: String?, limit: Int, session: String?) throws -> [RecoverySession] {
        var args = ["recover", "list", "--json", "--limit", String(limit)]
        if let session { args = ["recover", "show", "--session", session, "--json"] }
        else if let query, !query.isEmpty { args += ["--query", query] }
        let data = try runRecoverySubrouter(args)
        return try JSONDecoder().decode([RecoverySession].self, from: data)
    }

    private func loadRecoveryPrompt(sessionID: String) throws -> String {
        try String(decoding: runRecoverySubrouter(["recover", "prompt", "--session", sessionID]), as: UTF8.self)
    }

    private func runRecoverySubrouter(_ arguments: [String]) throws -> Data {
        let result = CLIProcessRunner.runProcess(
            executablePath: "/usr/bin/env",
            arguments: ["sr"] + arguments,
            timeout: 30
        )
        guard !result.timedOut, result.status == 0 else {
            throw CLIError(message: result.timedOut ? "sr recover timed out" : "sr recover failed: \(result.stderr)")
        }
        return Data(result.stdout.utf8)
    }

    private static func recoverParseLimit(_ raw: String) throws -> Int {
        guard let value = Int(raw), value > 0 else {
            throw CLIError(message: String(
                localized: "cli.vault.error.invalidLimit",
                defaultValue: "--limit requires a positive number"
            ))
        }
        return value
    }

    /// Fail closed on anything unrecognized.
    private static func recoverRejectUnexpected(_ remainder: [String]) throws {
        guard let unexpected = remainder.first else { return }
        throw CLIError(message: String(format: String(
            localized: "cli.vault.error.unexpectedArgument",
            defaultValue: "Unexpected argument '%@' for Bree %@"
        ), unexpected, "recover"))
    }
}
