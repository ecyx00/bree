import BREEAgentLaunch
import Foundation

extension BREECLI {
    // MARK: - Generic agent hook system

    // The client deadline must fire before the generated agent-hook timeout.
    static let feedHookProcessTimeoutMilliseconds = 120_000
    static let feedHookClientDeadlineSeconds = Double(feedHookProcessTimeoutMilliseconds) / 1_000 - 2
    static let feedHookDecisionWaitSeconds = feedHookClientDeadlineSeconds - 3
    /// Configuration for a hook-based agent integration.
    struct AgentHookDef {
        let name: String            // CLI name: "cursor", "gemini", etc.
        let displayName: String     // Human-readable: "Cursor", "Gemini"
        let statusKey: String       // Key for set_status: "cursor", "gemini"
        let configDir: String       // Relative to ~: ".cursor", ".gemini"
        let configFile: String      // File name: "hooks.json", "settings.json"
        let configDirEnvOverride: String? // e.g. "CODEX_HOME" overrides configDir
        let configDirEnvOverrideSubpath: String? // e.g. "GROK_HOME" + "hooks"
        let createConfigDirIfMissing: Bool // for agents whose hook dir is created lazily
        let configDirResolver: (@Sendable () -> String)?
        // identity-lint: allow help text names the bree dot dir; wording fix pending, not a path Bree uses
        let sessionStoreSuffix: String // e.g. "cursor" -> ~/.bree/cursor-hook-sessions.json
        let disableEnvVar: String   // e.g. "BREE_CURSOR_HOOKS_DISABLED"
        let hookMarker: String      // Marker in commands: "bree hooks cursor"
        let binaryName: String
        let format: HookFormat
        let events: [HookEvent]
        let aliases: Set<String>
        /// How installed hooks find the bree instance that owns them.
        ///
        /// `.ambient` is appropriate when an agent preserves the launch environment. `.pinned`
        /// embeds the installing CLI and socket, which is required for agents that sanitize hook
        /// subprocess environments and keeps callbacks attributed to the correct tagged app.
        let dispatch: HookDispatch
        let publishesStopNotification: Bool
        /// Whether this agent's `SessionEnd`/`session-end` hook fires once per
        /// conversation turn rather than at a true session teardown.
        ///
        /// Restorable agents (grok, antigravity, hermes-agent) re-emit their
        /// session-end event after every turn, so the `.sessionEnd` handler must
        /// treat it as a non-destructive turn boundary (`recordPromptStop`) and
        /// must not consume the session or clear the surface resume binding —
        /// otherwise the restore record is destroyed after the first turn and
        /// nothing survives a quit/relaunch. See
        /// https://github.com/ecyx00/bree/issues/5000.
        ///
        /// Agents whose runtime distinguishes a per-turn boundary from a genuine
        /// session teardown (hermes-agent emits both `on_session_end` per turn and
        /// `on_session_finalize` once at the end) route the teardown event to the
        /// separate `session-finalize` subcommand / ``AgentHookAction/sessionFinalize``
        /// action, which performs the destructive cleanup this flag suppresses.
        let sessionEndIsTurnBoundary: Bool
        /// Events that install a `bree hooks feed --source <name>` bridge.
        let feedHookEvents: [String]
        let postInstallAction: PostInstallAction?
        /// Optional CLI note printed after a successful install (or
        /// "already up to date") to guide a required activation step — e.g.
        /// Kiro applies its hooks only when run as the `bree` agent.
        let postInstallNote: String?

        enum HookFormat {
            case flat       // Cursor: {"hooks": {"event": [{"command": "..."}]}, "version": 1}
            case nested(timeoutMs: Int)  // Nested type/command/timeout hooks; timeout unit is agent-specific.
            case kiroAgentJSON(timeoutMs: Int) // ~/.kiro/agents/*.json flat command entries with timeout_ms
            case antigravityJSON(timeoutSeconds: Int) // ~/.gemini/config/hooks.json named hook groups
            case rovoDevYAML
            case hermesAgentYAML
            case tomlArrayTable // Kimi config.toml [[hooks]] array-of-tables
        }

        enum HookDispatch {
            case ambient
            case pinned(marker: String)
        }

        struct HookEvent {
            let agentEvent: String
            let breeSubcommand: String
            /// Catalog events are status/lifecycle telemetry. They must only
            /// transfer an immutable snapshot to the app queue; hooks whose
            /// output affects an agent decision live in `feedHookEvents` and
            /// continue to use the direct synchronous path.
            let delivery: HookDelivery
            let matcher: String?

            init(
                agentEvent: String,
                breeSubcommand: String,
                matcher: String? = nil,
                delivery: HookDelivery = .queued
            ) {
                self.agentEvent = agentEvent
                self.breeSubcommand = breeSubcommand
                self.matcher = matcher
                self.delivery = delivery
            }
        }

        enum HookDelivery: Equatable {
            case queued
            case direct
        }

        enum PostInstallAction {
            case codexConfigToml // write hooks = true to config.toml on install, remove on uninstall
        }

        /// Resolves the config directory, respecting env override if set.
        func resolvedConfigDir() -> String {
            if let configDirResolver {
                return configDirResolver()
            }
            let home = ProcessInfo.processInfo.environment["HOME"].flatMap { value -> String? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? NSHomeDirectory()
            if let envKey = configDirEnvOverride,
               let rawEnvValue = ProcessInfo.processInfo.environment[envKey] {
                let envValue = rawEnvValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !envValue.isEmpty else {
                    return URL(fileURLWithPath: home, isDirectory: true)
                        .appendingPathComponent(configDir, isDirectory: true)
                        .path
                }
                var url = URL(fileURLWithPath: NSString(string: envValue).expandingTildeInPath, isDirectory: true)
                if let subpath = configDirEnvOverrideSubpath,
                   !subpath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    url.appendPathComponent(subpath, isDirectory: true)
                }
                return url.path
            }
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(configDir, isDirectory: true)
                .path
        }

        init(name: String, displayName: String, statusKey: String,
             configDir: String, configFile: String, configDirEnvOverride: String? = nil,
             configDirEnvOverrideSubpath: String? = nil,
             createConfigDirIfMissing: Bool = false,
             configDirResolver: (@Sendable () -> String)? = nil,
             binaryName: String? = nil,
             sessionStoreSuffix: String, disableEnvVar: String, hookMarker: String,
             format: HookFormat, events: [HookEvent],
             aliases: Set<String> = [],
             dispatch: HookDispatch = .ambient,
             publishesStopNotification: Bool = true,
             sessionEndIsTurnBoundary: Bool = false,
             feedHookEvents: [String] = [],
             postInstallAction: PostInstallAction? = nil,
             postInstallNote: String? = nil) {
            self.name = name; self.displayName = displayName; self.statusKey = statusKey
            self.configDir = configDir; self.configFile = configFile
            self.configDirEnvOverride = configDirEnvOverride
            self.configDirEnvOverrideSubpath = configDirEnvOverrideSubpath
            self.createConfigDirIfMissing = createConfigDirIfMissing
            self.configDirResolver = configDirResolver
            self.binaryName = binaryName ?? name
            self.sessionStoreSuffix = sessionStoreSuffix; self.disableEnvVar = disableEnvVar
            self.hookMarker = hookMarker; self.format = format; self.events = events
            self.dispatch = dispatch
            self.publishesStopNotification = publishesStopNotification
            self.sessionEndIsTurnBoundary = sessionEndIsTurnBoundary
            self.aliases = Set(aliases.compactMap { alias in
                let normalized = alias.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? nil : normalized
            })
            self.feedHookEvents = feedHookEvents
            self.postInstallAction = postInstallAction
            self.postInstallNote = postInstallNote
        }
    }

    enum AgentHookAction {
        case sessionStart, promptSubmit, titleUpdate, stop, notification, approvalResponse
        case codexSubagentStart, codexSubagentStop
        case shellObserved, shellDone, shellFailed, sessionEnd, sessionFinalize, noop
    }

    static let subcommandActions: [String: AgentHookAction] = [
        "session-start": .sessionStart,
        "prompt-submit": .promptSubmit,
        "title-update": .titleUpdate,
        "stop": .stop,
        "notification": .notification,
        "notify": .notification,
        "agent-response": .stop,
        "approval-response": .approvalResponse,
        "subagent-start": .codexSubagentStart,
        "subagent-stop": .codexSubagentStop,
        "shell-exec": .promptSubmit,
        "shell-done": .shellDone,
        "shell-failed": .shellFailed,
        "session-end": .sessionEnd,
        "session-finalize": .sessionFinalize,
    ]

    static func hookCommandString(
        for def: AgentHookDef,
        event: AgentHookDef.HookEvent,
        materializeCodexScripts: Bool = true
    ) -> String {
        let command = "bree hooks \(def.name) \(event.breeSubcommand)"
        let inline: String
        if event.delivery == .queued {
            if usesPinnedHookDispatch(def) {
                inline = agentHookShellCommand(
                    "bree hooks enqueue \(def.name) \(event.breeSubcommand)",
                    for: def,
                    failOpen: true
                )
            } else {
                inline = queuedAgentHookShellCommand(
                    agent: def.name,
                    subcommand: event.breeSubcommand,
                    disableEnvironmentVariable: def.disableEnvVar,
                    identityMarker: def.name == "codex" ? "bree-codex-hook" : nil
                )
            }
        } else {
            inline = agentHookShellCommand(command, for: def, failOpen: true)
        }
        if def.name == "codex" {
            return codexPersistentHookScriptCommand(
                inline,
                eventTag: event.breeSubcommand,
                materialize: materializeCodexScripts
            )
        }
        return inline
    }

    /// Wraps a codex persistent hook command as a `#!/bin/sh` script file in the
    /// bree-owned hooks dir and returns its shell command token. Shell-safe paths
    /// stay bare for runtimes that execute the command directly; paths with
    /// separators or metacharacters are quoted for Codex's `/bin/sh -lc` runner.
    /// Falls back to the inline command on any write failure, so the persistent
    /// install can never regress.
    private static func codexPersistentHookScriptCommand(
        _ inlineCommand: String,
        eventTag: String,
        materialize: Bool = true
    ) -> String {
        guard materialize,
              let dir = codexHookScriptsDirectory(),
              let path = writeCodexHookScript(
                  subcommand: "persistent-\(eventTag)", body: inlineCommand, in: dir
              ) else {
            return inlineCommand
        }
        return CodexHookScriptName.shellCommand(forScriptPath: path)
    }

    static func feedHookCommandString(
        for def: AgentHookDef,
        agentEvent: String,
        materializeCodexScripts: Bool = true
    ) -> String {
        if def.name == "codex",
           let injectedEvent = CodexHookInjectionSchema.current.events.first(where: {
               $0.agentEvent == agentEvent
           }) {
            let inline: String
            switch injectedEvent.delivery {
            case .queued:
                inline = queuedAgentHookShellCommand(
                    agent: def.name,
                    subcommand: injectedEvent.breeSubcommand,
                    disableEnvironmentVariable: def.disableEnvVar,
                    identityMarker: "bree-codex-hook"
                )
            case .direct:
                inline = codexSynchronousAgentHookShellCommand(
                    "bree hooks feed --source codex --event \(agentEvent)",
                    for: def
                )
            }
            return codexPersistentHookScriptCommand(
                inline,
                eventTag: "feed-\(agentEvent)",
                materialize: materializeCodexScripts
            )
        }

        let inline: String
        let noOpCommand = feedHookNoOpShellCommand(for: def, agentEvent: agentEvent)
        switch def.format {
        case .kiroAgentJSON:
            inline = exitTwoPropagatingAgentHookShellCommand(
                "bree hooks feed --source \(def.name) --event \(agentEvent)",
                for: def,
                noOpCommand: noOpCommand
            )
        default:
            inline = agentHookShellCommand(
                "bree hooks feed --source \(def.name) --event \(agentEvent)",
                for: def,
                noOpCommand: noOpCommand
            )
        }
        if def.name == "codex" {
            return codexPersistentHookScriptCommand(
                inline,
                eventTag: "feed-\(agentEvent)",
                materialize: materializeCodexScripts
            )
        }
        return inline
    }

    private static func feedHookNoOpShellCommand(for def: AgentHookDef, agentEvent: String) -> String {
        let normalized = (def.name == "codex" ? "posttooluse" : agentEvent)
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        switch normalized {
        case "posttooluse", "posttoolcall":
            return "cat >/dev/null 2>/dev/null || true; echo '{}'"
        default:
            return "echo '{}'"
        }
    }

    static let stdinDrainingHookNoOpShellCommand = "cat >/dev/null 2>/dev/null || true; echo '{}'"

    private static func shellNoOpSnippet(_ noOpCommand: String) -> String {
        let command = noOpCommand == "echo '{}'"
            ? stdinDrainingHookNoOpShellCommand
            : noOpCommand
        return "{ \(command); }"
    }

    private static let grokPinnedHookMarker = "bree-grok-hook-v2"
    private static let antigravityPinnedHookMarker = "bree-antigravity-hook-v2"

    static func agentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'",
        failOpen: Bool = false
    ) -> String {
        if usesPinnedHookDispatch(def) {
            return pinnedAgentHookShellCommand(
                command,
                for: def,
                noOpCommand: noOpCommand,
                failOpen: failOpen
            )
        }
        let routedArguments = ["bree ", "bree "].first(where: { command.hasPrefix($0) }).map { String(command.dropFirst($0.count)) } ?? command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        let executableExpression = agentHookCLIExecutableExpression(agent: def.name)
        let invocation = "if [ -n \"${BREE_SOCKET_PATH:-}\" ]; then \"$bree_cli\" --socket \"$BREE_SOCKET_PATH\" \(routedArguments); else \"$bree_cli\" \(routedArguments); fi"
        let dispatch = failOpen ? "{ \(invocation); } || \(noOpSnippet)" : invocation
        return "bree_cli=\"\(executableExpression)\"; if [ -z \"$bree_cli\" ] || [ ! -x \"$bree_cli\" ]; then bree_cli=\"$(command -v bree 2>/dev/null || true)\"; fi; if [ -n \"$BREE_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$bree_cli\" ]; then \(dispatch); else \(noOpSnippet); fi"
    }

    /// Synchronous Codex lifecycle hook command. Capturing the callback's
    /// parent PID before dispatch prevents a descendant from reusing an
    /// inherited `BREE_CODEX_PID` as its own owner identity.
    static func codexSynchronousAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        failOpen: Bool = false
    ) -> String {
        let dispatch = agentHookShellCommand(command, for: def, failOpen: failOpen)
        return "BREE_CODEX_HOOK_PID=\"${PPID:-}\"; export BREE_CODEX_HOOK_PID; \(dispatch)"
    }

    private static func exitTwoPropagatingAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'"
    ) -> String {
        let routedArguments = ["bree ", "bree "].first(where: { command.hasPrefix($0) }).map { String(command.dropFirst($0.count)) } ?? command
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        return "bree_cli=\"${BREE_BUNDLED_CLI_PATH:-}\"; if [ -z \"$bree_cli\" ] || [ ! -x \"$bree_cli\" ]; then bree_cli=\"$(command -v bree 2>/dev/null || true)\"; fi; if [ -n \"$BREE_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && [ -n \"$bree_cli\" ]; then if [ -n \"${BREE_SOCKET_PATH:-}\" ]; then \"$bree_cli\" --socket \"$BREE_SOCKET_PATH\" \(routedArguments); else \"$bree_cli\" \(routedArguments); fi; status=$?; if [ \"$status\" -eq 2 ]; then exit 2; fi; if [ \"$status\" -ne 0 ]; then \(noOpSnippet); fi; else \(noOpSnippet); fi"
    }

    static func usesPinnedHookDispatch(_ def: AgentHookDef) -> Bool {
        def.name == "grok" || def.name == "antigravity"
    }

    private static func pinnedHookMarker(for def: AgentHookDef) -> String {
        def.name == "antigravity" ? antigravityPinnedHookMarker : grokPinnedHookMarker
    }

    private static func pinnedAgentHookShellCommand(
        _ command: String,
        for def: AgentHookDef,
        noOpCommand: String = "echo '{}'",
        failOpen: Bool = false
    ) -> String {
        guard case .pinned = def.dispatch else {
            return agentHookShellCommand(command, for: def, noOpCommand: noOpCommand)
        }
        let routedArguments = ["bree ", "bree "].first(where: { command.hasPrefix($0) }).map { String(command.dropFirst($0.count)) } ?? command
        let socketPath = pinnedAgentHookSocketPath()
        let noOpSnippet = shellNoOpSnippet(noOpCommand)
        let shellTraceStart = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "start",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        let shellTraceDisabled = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "disabled",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        let shellTraceExit = pinnedHookShellTraceCommand(
            agentName: def.name,
            phase: "exit",
            routedArguments: routedArguments,
            socketPath: socketPath,
            statusExpression: "$bree_hook_status"
        )
        let fallbackInvocation = pinnedHookInvocation(
            executable: "bree",
            routedArguments: routedArguments,
            socketPath: socketPath
        )
        // The terminal that launched the agent owns the surface. When the agent
        // preserved that terminal's bree environment, dispatch there first so a
        // session started from one bree build (stable, nightly, a tagged dev
        // build) is never reported to whichever build last ran `hooks setup`.
        // The pinned install remains the fallback for sanitized hook
        // environments, and for a stale socket node left by an exited app: the
        // ambient invocation must succeed, otherwise the pinned chain runs.
        // https://github.com/ecyx00/bree/issues/5473
        let ambientGuard = pinnedHookAmbientDispatchGuard
        let ambientInvocation = pinnedHookAmbientInvocation(routedArguments: routedArguments)
        let dispatch: String
        if let cliPath = pinnedAgentHookCLIPath() {
            let quotedCLIPath = shellSingleQuote(cliPath)
            let primaryInvocation = pinnedHookInvocation(
                executable: quotedCLIPath,
                routedArguments: routedArguments,
                socketPath: socketPath
            )
            dispatch = "if \(ambientGuard) && \(ambientInvocation); then :; elif [ -x \(quotedCLIPath) ]; then \(primaryInvocation); elif command -v bree >/dev/null 2>&1; then \(fallbackInvocation); else \(noOpSnippet); fi"
        } else {
            dispatch = "if \(ambientGuard) && \(ambientInvocation); then :; elif command -v bree >/dev/null 2>&1; then \(fallbackInvocation); else \(noOpSnippet); fi"
        }
        let completion = failOpen
            ? "if [ \"$bree_hook_status\" -ne 0 ]; then \(noOpSnippet); fi; exit 0"
            : "exit $bree_hook_status"
        return ": \(pinnedHookMarker(for: def)); \(shellTraceStart); printenv \(def.disableEnvVar) | grep -qx 1 && { \(shellTraceDisabled); \(noOpSnippet); } || { \(pinnedHookAmbientEnvironment); \(dispatch); bree_hook_status=$?; \(shellTraceExit); \(completion); }"
    }

    // Grok validates plain environment references before invoking the shell.
    // Read optional ambient values at execution time so a sanitized environment
    // can reach the pinned fallback instead of failing that preflight check.
    // The sentinel retains trailing newlines through command substitution;
    // trim only printenv's final newline and the sentinel. Missing values also
    // produce that pair, and their lookup remains safe under `set -e`.
    static let pinnedHookAmbientEnvironment =
        "bree_hook_ambient_socket=$(printenv BREE_SOCKET_PATH || printf '\\n'; printf '.'); bree_hook_ambient_socket=${bree_hook_ambient_socket%??}; bree_hook_ambient_cli=$(printenv BREE_BUNDLED_CLI_PATH || printf '\\n'; printf '.'); bree_hook_ambient_cli=${bree_hook_ambient_cli%??}"

    /// Shell test that is true only when the hook inherited a live bree terminal
    /// environment: a socket that exists plus an executable bundled CLI file.
    /// `-f` matters because a directory also satisfies `-x`.
    static let pinnedHookAmbientDispatchGuard =
        "[ -n \"${bree_hook_ambient_socket:-}\" ] && [ -S \"${bree_hook_ambient_socket:-}\" ] && [ -f \"${bree_hook_ambient_cli:-}\" ] && [ -x \"${bree_hook_ambient_cli:-}\" ]"

    /// Dispatches through the launching terminal's own bree build and socket.
    static func pinnedHookAmbientInvocation(routedArguments: String) -> String {
        "\(pinnedHookEnvironmentPrefix(routedArguments: routedArguments))\"${bree_hook_ambient_cli:-}\" --socket \"${bree_hook_ambient_socket:-}\" \(routedArguments)"
    }

    private static func pinnedHookEnvironmentPrefix(routedArguments: String) -> String {
        routedArguments.hasPrefix("hooks enqueue ")
            ? "BREE_CLI_RESPONSE_TIMEOUT_SEC=\(agentHookAdmissionResponseTimeoutSeconds) "
            : ""
    }

    private static func pinnedHookInvocation(
        executable: String,
        routedArguments: String,
        socketPath: String?
    ) -> String {
        let environmentPrefix = pinnedHookEnvironmentPrefix(routedArguments: routedArguments)
        if let socketPath {
            return "\(environmentPrefix)\(executable) --socket \(shellSingleQuote(socketPath)) \(routedArguments)"
        }
        return "\(environmentPrefix)\(executable) \(routedArguments)"
    }

    private static func pinnedAgentHookCLIPath(
        env: [String: String] = ProcessInfo.processInfo.environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> String? {
        if let bundledPath = normalizedHookInstallValue(env["BREE_BUNDLED_CLI_PATH"]) {
            let expanded = NSString(string: bundledPath).expandingTildeInPath
            if isExecutableFilePath(expanded) {
                return expanded
            }
        }
        if let arg0 = normalizedHookInstallValue(arguments.first) {
            let expanded = NSString(string: arg0).expandingTildeInPath
            if expanded.hasPrefix("/"), isExecutableFilePath(expanded) {
                return expanded
            }
        }
        if let executablePath = Bundle.main.executableURL?.path,
           !executablePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           isExecutableFilePath(executablePath) {
            return executablePath
        }
        return nil
    }

    private static func isExecutableFilePath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
    }

    private static func pinnedAgentHookSocketPath(
        env: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if let socketPath = normalizedHookInstallValue(env["BREE_SOCKET_PATH"]) {
            return NSString(string: socketPath).expandingTildeInPath
        }
        guard let tag = normalizedHookInstallValue(env["BREE_TAG"]) else {
            return nil
        }
        let slug = tag
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !slug.isEmpty else { return nil }
        return "/tmp/bree-debug-\(slug).sock"
    }

    static func validateHookInstallDispatch(for def: AgentHookDef) throws {
        guard case .pinned = def.dispatch,
              pinnedAgentHookSocketPath() == nil else {
            return
        }
        throw CLIError(message: String(
            localized: "cli.hooks.error.pinnedTargetMissing",
            defaultValue: "Bree could not connect this hook installation to a running app. Open a Bree workspace and run this command again."
        ))
    }

    private static func pinnedHookShellTraceCommand(
        agentName: String,
        phase: String,
        routedArguments: String,
        socketPath: String?,
        statusExpression: String? = nil
    ) -> String {
#if DEBUG
        let logPath = shellSingleQuote(pinnedHookShellTraceLogPath(socketPath: socketPath))
        let event = shellSingleQuote(routedArguments)
        let socket = shellSingleQuote(socketPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "nil")
        let statusField = statusExpression == nil ? "" : " status=%s"
        let statusArgument = statusExpression.map { " \($0)" } ?? ""
        // Any local account can create names in /tmp, so append only to an
        // existing regular file this user owns with a single link, never
        // through a symlink or into a file someone else prepared.
        let ownedLogCheck = "[ -n \"$(find \(logPath) -prune -type f -links 1 -user \"$(id -u)\" 2>/dev/null)\" ]"
        return "\(ownedLogCheck) && printf '%s \(agentName)Hook.shell phase=%s event=%s pid=%s ppid=%s socket=%s\(statusField)\\n' \"$(date +%s)\" \(shellSingleQuote(phase)) \(event) \"$$\" \"${PPID:-}\" \(socket)\(statusArgument) >> \(logPath) 2>/dev/null || true"
#else
        return ":"
#endif
    }

    private static func pinnedHookShellTraceLogPath(socketPath: String?) -> String {
        guard let socketPath else {
            return "/tmp/bree-debug.log"
        }
        let socketName = URL(fileURLWithPath: socketPath).lastPathComponent
        if socketName.hasPrefix("bree-debug-"), socketName.hasSuffix(".sock") {
            return URL(fileURLWithPath: "/tmp", isDirectory: true)
                .appendingPathComponent(String(socketName.dropLast(".sock".count)) + ".log")
                .path
        }
        return "/tmp/bree-debug.log"
    }

    private static func normalizedHookInstallValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func isBreeOwnedHookCommand(
        _ command: String,
        for def: AgentHookDef,
        includeLegacy: Bool = true,
        materializeCodexScripts: Bool = true
    ) -> Bool {
        if case .pinned(let marker) = def.dispatch, command.contains(marker) {
            return true
        }
        if def.name == "codex", isBreeOwnedCodexHookScriptCommand(command) {
            return true
        }
        if def.events.contains(where: {
            hookCommandString(
                for: def,
                event: $0,
                materializeCodexScripts: materializeCodexScripts
            ) == command
        })
            || def.feedHookEvents.contains(where: {
                feedHookCommandString(
                    for: def,
                    agentEvent: $0,
                    materializeCodexScripts: materializeCodexScripts
                ) == command
            })
        {
            return true
        }
        return includeLegacy && isLegacyBreeOwnedHookCommand(command, for: def)
    }

    private static func isBreeOwnedCodexHookScriptCommand(_ command: String) -> Bool {
        codexHookScriptPath(fromCommand: command) != nil
    }

    private static func isLegacyBreeOwnedHookCommand(_ command: String, for def: AgentHookDef) -> Bool {
        // Codex also had older top-level codex-hook/feed-hook commands.
        // Other generic agents can have stale `bree hooks ...` files from
        // earlier integration attempts, and setup should be able to prune them.
        return legacyBreeCommandTokenLists(from: command, for: def).contains { tokens in
            isLegacyBreeOwnedHookTokens(tokens, for: def)
        }
    }

    private static func isLegacyBreeOwnedHookTokens(_ tokens: [String], for def: AgentHookDef) -> Bool {
        guard !tokens.isEmpty,
              (URL(fileURLWithPath: tokens[0]).lastPathComponent == "bree"
                || isObsoleteBreeCodexSpelling(tokens, for: def))
        else {
            return false
        }

        if def.name == "codex", tokens.count >= 2, tokens[1] == "codex-hook" {
            return true
        }
        if def.name == "codex",
           tokens.count >= 4,
           tokens[1] == "feed-hook",
           tokens[2] == "--source",
           tokens[3] == def.name {
            return true
        }
        if tokens.count >= 5,
           tokens[1] == "hooks",
           tokens[2] == "enqueue",
           tokens[3] == def.name {
            return true
        }
        if tokens.count >= 3, tokens[1] == "hooks", tokens[2] == def.name {
            return true
        }
        if tokens.count >= 5,
           tokens[1] == "hooks",
           tokens[2] == "feed",
           tokens[3] == "--source",
           tokens[4] == def.name {
            return true
        }
        return false
    }

    /// Only the pre-persistent-script `bree codex-hook` / `bree feed-hook` forms are
    /// removed as obsolete. bree.app's current `bree hooks ...` entries (any agent)
    /// and its pinned grok/antigravity markers are not ours and must survive.
    private static func isObsoleteBreeCodexSpelling(_ tokens: [String], for def: AgentHookDef) -> Bool {
        def.name == "codex"
            && tokens.count >= 2
            && URL(fileURLWithPath: tokens[0]).lastPathComponent == "bree"
            && ["codex-hook", "feed-hook"].contains(tokens[1])
    }

    private static func legacyBreeCommandTokenLists(from command: String, for def: AgentHookDef) -> [[String]] {
        if let bundledTokens = bundledCLIBreeCommandTokenLists(from: command), !bundledTokens.isEmpty {
            return bundledTokens
        }

        let guardedPrefixes = ["bree", "bree"].flatMap { name in [
            "[ -n \"$BREE_SURFACE_ID\" ] && [ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v \(name) >/dev/null 2>&1 && ",
            "[ \"$\(def.disableEnvVar)\" != \"1\" ] && command -v \(name) >/dev/null 2>&1 && ",
        ] }
        let fallbackSuffix = " || echo '{}'"
        var body = command
        if def.name == "grok" {
            let grokPrefixes = ["bree", "bree"].map { "printenv \(def.disableEnvVar) | grep -qx 1 && echo '{}' || { command -v \($0) >/dev/null 2>&1 && " }
            let grokSuffix = " || echo '{}'; }"
            if let grokPrefix = grokPrefixes.first(where: { body.hasPrefix($0) }), body.hasSuffix(grokSuffix) {
                body.removeFirst(grokPrefix.count)
                body.removeLast(grokSuffix.count)
                guard !body.contains(";"), !body.contains("|"), !body.contains("&"), !body.contains("`") else {
                    return []
                }
                return [body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)]
            }
        }
        for guardedPrefix in guardedPrefixes where body.hasPrefix(guardedPrefix) {
            body.removeFirst(guardedPrefix.count)
            break
        }
        if body.hasSuffix(fallbackSuffix) {
            body.removeLast(fallbackSuffix.count)
        }
        guard !body.contains(";"), !body.contains("|"), !body.contains("&"), !body.contains("`") else {
            return []
        }
        return [body.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)]
    }

    private static func bundledCLIBreeCommandTokenLists(from command: String) -> [[String]]? {
        guard command.contains("BREE_BUNDLED_CLI_PATH"),
              command.contains("bree_cli="),
              (command.contains("command -v bree") || command.contains("command -v bree")) else {
            return nil
        }

        let cliName = command.contains("command -v bree") ? "bree" : "bree"
        let invocationPrefixes = [
            "\"$bree_cli\" --socket \"$BREE_SOCKET_PATH\" ",
            "\"$bree_cli\" ",
        ]
        var tokenLists: [[String]] = []
        for prefix in invocationPrefixes {
            var searchStart = command.startIndex
            while let prefixRange = command.range(of: prefix, range: searchStart..<command.endIndex) {
                let argsStart = prefixRange.upperBound
                let tail = command[argsStart..<command.endIndex]
                let argsEnd = [
                    tail.range(of: ";")?.lowerBound,
                    tail.range(of: " ||")?.lowerBound,
                    tail.range(of: " &&")?.lowerBound,
                    tail.range(of: " }")?.lowerBound,
                ].compactMap { $0 }.min() ?? command.endIndex
                let args = command[argsStart..<argsEnd].trimmingCharacters(in: .whitespacesAndNewlines)
                if !args.isEmpty,
                   !args.contains(";"),
                   !args.contains("|"),
                   !args.contains("&"),
                   !args.contains("`") {
                    tokenLists.append(
                        [cliName] + args.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                    )
                }
                searchStart = prefixRange.upperBound
            }
        }
        return tokenLists
    }

    static func hookMarkers(for def: AgentHookDef) -> [String] {
        // Only `bree ...` spellings are ours. `bree ...` entries in shared agent
        // config files belong to bree.app and must survive Bree install/uninstall.
        [def.hookMarker, "bree hooks enqueue \(def.name)"]
    }

    /// Marker substrings used when removing / upgrading our own Feed bridge
    /// entries on reinstall or uninstall.
    static func feedHookMarkers(for def: AgentHookDef) -> [String] {
        // `bree ...` entries belong to bree.app and are never removed here.
        ["bree hooks feed --source"]
    }
}
