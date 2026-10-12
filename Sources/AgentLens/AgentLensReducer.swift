import CMUXAgentLaunch
import Foundation

/// One live Claude Code session as the Agent Lens card shows it. Pure value;
/// built only by ``AgentLensReducer`` from accepted hook events.
struct AgentLensCard: Equatable, Identifiable, Sendable {
    /// Display order: needs input first, then error, running, idle.
    enum State: Int, Comparable, Sendable {
        case needsInput = 0
        case error
        case running
        case idle

        static func < (lhs: State, rhs: State) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    struct Step: Equatable, Sendable {
        let tool: String
        let target: String?
    }

    struct Todos: Equatable, Sendable {
        let done: Int
        let total: Int
        /// The in-progress todo (`activeForm`, else `content`).
        let current: String?
    }

    var id: String
    var workspaceID: UUID
    var surfaceID: UUID?
    var project: String
    var state: State
    var startedAt: Date
    var lastEventAt: Date
    var step: Step?
    var todos: Todos?
    /// Files edited or written this session, most recent first.
    var files: [String]
    /// Filled by the store from the usage sampler, not by the reducer.
    var usage: AgentLensUsage?
    /// Subagents started by this session and not yet stopped (hook-counted).
    var runningSubagents = 0
    /// Last API request time from the cache-warm mod's store; filled by the store.
    var cacheRequestAt: Date?
    /// Claude's own session_id (UUID), from the event id or the transcript file name. `id` can be a
    /// cmux-side fallback (`cmux-<surface>`), which never matches Claude's on-disk session folders.
    var claudeSessionID: String?
    /// While `state == .needsInput`: true for a permission request (approval), false for a question,
    /// plan review or an agent waiting at its prompt.
    var needsApproval = false
}

struct AgentLensUsage: Equatable, Sendable {
    let contextFraction: Double?
    let costUSD: Double?
    let costIsLowerBound: Bool
}

/// Event to card state. No I/O and no clock: everything comes from the event.
enum AgentLensReducer {
    static let maxFiles = 200
    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]
    private static let blockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// The real Claude session UUID: the event id when UUID-shaped, else the transcript stem
    /// (`.../projects/<slug>/<session_id>.jsonl`).
    static func claudeSessionID(of event: WorkstreamEvent) -> String? {
        if UUID(uuidString: event.sessionId) != nil { return event.sessionId }
        guard let path = event.transcriptPath, path.hasSuffix(".jsonl") else { return nil }
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        return UUID(uuidString: stem) != nil ? stem : nil
    }

    /// Applies `event` to `card`.
    ///
    /// - Returns: The new card, or `nil` when the session has no card (not a
    ///   Claude event, no workspace yet, or the session ended).
    static func reduce(_ card: AgentLensCard?, event: WorkstreamEvent) -> AgentLensCard? {
        guard event.source == "claude" else { return card }
        if event.hookEventName == .sessionEnd { return nil }
        let eventWorkspace = event.workspaceId
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(UUID.init(uuidString:))
        guard var next = card ?? eventWorkspace.map({
            AgentLensCard(
                id: event.sessionId, workspaceID: $0, surfaceID: nil, project: "Claude",
                state: .idle, startedAt: event.receivedAt, lastEventAt: event.receivedAt,
                step: nil, todos: nil, files: [], usage: nil
            )
        }) else { return nil }

        if let eventWorkspace { next.workspaceID = eventWorkspace }
        if let surface = event.surfaceId.flatMap(UUID.init(uuidString:)) { next.surfaceID = surface }
        if let name = event.cwd.flatMap(projectName(fromCWD:)) { next.project = name }
        next.lastEventAt = max(next.lastEventAt, event.receivedAt)
        if let real = claudeSessionID(of: event) { next.claudeSessionID = real }

        let input = event.toolInputJSON.flatMap(parseObject)
        switch event.hookEventName {
        case .sessionStart:
            next.runningSubagents = 0
            next.state = .idle
            next.step = nil
        case .userPromptSubmit:
            next.state = .running
            next.step = nil
        case .preToolUse, .todoWrite:
            let tool = event.toolName ?? (event.hookEventName == .todoWrite ? "TodoWrite" : nil)
            if let tool {
                // Claude's settings install SubagentStop only (no SubagentStart),
                // so a spawn is counted from the parent's Agent/Task tool call.
                if tool == "Agent" || tool == "Task" { next.runningSubagents += 1 }
                if tool == "TodoWrite", let update = parseTodos(input) {
                    switch update {
                    case .set(let todos): next.todos = todos
                    case .clear: next.todos = nil
                    }
                }
                if editTools.contains(tool), let path = filePath(input) {
                    next.files.removeAll { $0 == path }
                    next.files.insert(path, at: 0)
                    if next.files.count > maxFiles { next.files.removeLast(next.files.count - maxFiles) }
                }
                next.step = AgentLensCard.Step(tool: tool, target: target(tool: tool, input: input))
            }
            next.state = (tool.map(blockingTools.contains) ?? false) ? .needsInput : .running
            next.needsApproval = false
        case .postToolUse:
            if next.state != .needsInput { next.state = .running }
        case .postToolUseFailure:
            next.state = .error
        case .permissionRequest, .askUserQuestion, .exitPlanMode:
            next.state = .needsInput
            next.needsApproval = event.hookEventName == .permissionRequest
        case .notification:
            // Claude also notifies when idle ("waiting for input"); only a
            // notification during a turn is a real wait.
            if next.state == .running { next.state = .needsInput; next.needsApproval = false }
        case .stop:
            next.state = event.isError == true ? .error : .idle
            next.step = nil
        case .subagentStop:
            next.runningSubagents = max(0, next.runningSubagents - 1)
        case .sessionEnd, .preCompact, .postCompact, .subagentStart:
            break
        }
        if event.isError == true, next.state == .running { next.state = .error }
        return next
    }

    // MARK: Parsing (defensive: unknown shapes are ignored, never guessed)

    static func parseObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    enum TodoUpdate: Equatable { case set(AgentLensCard.Todos), clear }

    /// `nil` when `input` is not a TodoWrite shape (card keeps its todos).
    static func parseTodos(_ input: [String: Any]?) -> TodoUpdate? {
        guard let list = input?["todos"] as? [[String: Any]] else { return nil }
        var done = 0
        var current: String?
        for item in list {
            guard let content = item["content"] as? String,
                  let status = item["status"] as? String else { return nil }
            if status == "completed" { done += 1 }
            if status == "in_progress", current == nil {
                current = (item["activeForm"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? content
            }
        }
        if list.isEmpty { return .clear }
        return .set(AgentLensCard.Todos(done: done, total: list.count, current: current))
    }

    private static func filePath(_ input: [String: Any]?) -> String? {
        let raw = (input?["file_path"] as? String) ?? (input?["notebook_path"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        return raw
    }

    private static func target(tool: String, input: [String: Any]?) -> String? {
        guard let input else { return nil }
        func last(_ path: String) -> String { (path as NSString).lastPathComponent }
        func clip(_ text: String) -> String? {
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            return trimmed.count > 48 ? String(trimmed.prefix(47)) + "…" : trimmed
        }
        switch tool {
        case "Edit", "MultiEdit", "Write", "Read", "NotebookEdit":
            return filePath(input).map(last)
        case "Bash": return (input["command"] as? String).flatMap(clip)
        case "Grep", "Glob": return (input["pattern"] as? String).flatMap(clip)
        case "WebFetch": return (input["url"] as? String).flatMap { URL(string: $0)?.host }
        case "WebSearch": return (input["query"] as? String).flatMap(clip)
        case "Task", "Agent": return (input["description"] as? String).flatMap(clip)
        case "Skill": return (input["skill"] as? String).flatMap(clip)
        default: return nil
        }
    }

    private static func projectName(fromCWD cwd: String) -> String? {
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}
