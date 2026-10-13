import BREEAgentLaunch
import Foundation

extension BREECLI {
    // MARK: Agent definitions

    static let agentDefs: [AgentHookDef] = [
        AgentHookDef(
            name: "codex", displayName: "Codex", statusKey: "codex",
            configDir: ".codex", configFile: "hooks.json", configDirEnvOverride: "CODEX_HOME",
            sessionStoreSuffix: "codex", disableEnvVar: "BREE_CODEX_HOOKS_DISABLED",
            hookMarker: "bree hooks codex", format: .nested(timeoutMs: agentHookDeclaredTimeoutMilliseconds),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
            ],
            feedHookEvents: [
                "PreToolUse",
                "PermissionRequest",
                "PostToolUse",
                "PreCompact",
                "PostCompact",
                "SubagentStart",
                "SubagentStop",
            ],
            postInstallAction: .codexConfigToml
        ),
        AgentHookDef(
            name: "grok", displayName: "Grok", statusKey: "grok",
            configDir: ".grok/hooks", configFile: "bree-session.json",
            configDirEnvOverride: "GROK_HOME", configDirEnvOverrideSubpath: "hooks",
            createConfigDirIfMissing: true,
            sessionStoreSuffix: "grok", disableEnvVar: "BREE_GROK_HOOKS_DISABLED",
            hookMarker: "bree hooks grok", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "Notification", breeSubcommand: "notification"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            dispatch: .pinned(marker: "bree-grok-hook-v2"),
            publishesStopNotification: false,
            sessionEndIsTurnBoundary: true,
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "opencode", displayName: "OpenCode", statusKey: "opencode",
            configDir: ".config/opencode", configFile: "plugins/bree-session.js", configDirEnvOverride: "OPENCODE_CONFIG_DIR",
            sessionStoreSuffix: "opencode", disableEnvVar: "BREE_OPENCODE_HOOKS_DISABLED",
            hookMarker: "bree hooks opencode", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "pi", displayName: "Pi", statusKey: "pi",
            configDir: ".pi/agent", configFile: "extensions/bree-session.ts", configDirEnvOverride: "PI_CODING_AGENT_DIR",
            sessionStoreSuffix: "pi", disableEnvVar: "BREE_PI_HOOKS_DISABLED",
            hookMarker: "bree hooks pi", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "omp", displayName: "OMP", statusKey: "omp",
            configDir: ".omp/agent", configFile: "extensions/bree-omp-session.ts",
            createConfigDirIfMissing: true,
            configDirResolver: { BREECLI.resolvedOmpAgentDirectory().path },
            sessionStoreSuffix: "omp", disableEnvVar: "BREE_OMP_HOOKS_DISABLED",
            hookMarker: "bree hooks omp", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "campfire", displayName: "Campfire", statusKey: "campfire",
            configDir: ".campfire/agent", configFile: "extensions/bree-campfire-session.ts",
            createConfigDirIfMissing: true,
            configDirResolver: { BREECLI.resolvedCampfireAgentDirectory().path },
            sessionStoreSuffix: "campfire", disableEnvVar: "BREE_CAMPFIRE_HOOKS_DISABLED",
            hookMarker: "bree hooks campfire", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "amp", displayName: "Amp", statusKey: "amp",
            configDir: ".config/amp", configFile: "plugins/bree-session.ts",
            sessionStoreSuffix: "amp", disableEnvVar: "BREE_AMP_HOOKS_DISABLED",
            hookMarker: "bree hooks amp", format: .flat,
            events: []
        ),
        AgentHookDef(
            name: "cursor", displayName: "Cursor", statusKey: "cursor",
            configDir: ".cursor", configFile: "hooks.json", binaryName: "cursor-agent",
            sessionStoreSuffix: "cursor", disableEnvVar: "BREE_CURSOR_HOOKS_DISABLED",
            hookMarker: "bree hooks cursor", format: .flat,
            events: [
                .init(agentEvent: "beforeSubmitPrompt", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "stop", breeSubcommand: "stop"),
                .init(agentEvent: "afterAgentResponse", breeSubcommand: "agent-response"),
                .init(
                    agentEvent: "beforeShellExecution",
                    breeSubcommand: "shell-exec",
                    delivery: .direct
                ),
                .init(agentEvent: "afterShellExecution", breeSubcommand: "shell-done"),
                .init(
                    agentEvent: "postToolUseFailure",
                    breeSubcommand: "shell-failed",
                    matcher: "Shell"
                ),
            ]
        ),
        AgentHookDef(
            name: "gemini", displayName: "Gemini", statusKey: "gemini",
            configDir: ".gemini", configFile: "settings.json",
            sessionStoreSuffix: "gemini", disableEnvVar: "BREE_GEMINI_HOOKS_DISABLED",
            hookMarker: "bree hooks gemini", format: .nested(timeoutMs: 10000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "BeforeAgent", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "AfterAgent", breeSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "kiro", displayName: "Kiro", statusKey: "kiro",
            configDir: ".kiro/agents", configFile: "bree.json",
            configDirEnvOverride: "KIRO_HOME", configDirEnvOverrideSubpath: "agents",
            createConfigDirIfMissing: true, binaryName: "kiro-cli",
            sessionStoreSuffix: "kiro", disableEnvVar: "BREE_KIRO_HOOKS_DISABLED",
            hookMarker: "bree hooks kiro", format: .kiroAgentJSON(timeoutMs: 5000),
            events: [
                .init(agentEvent: "agentSpawn", breeSubcommand: "session-start"),
                .init(agentEvent: "userPromptSubmit", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "stop", breeSubcommand: "stop"),
            ],
            feedHookEvents: ["preToolUse", "postToolUse"],
            postInstallNote: String(
                localized: "cli.hooks.kiro.postInstallNote",
                defaultValue: "Kiro applies these hooks only when run as the bree agent. Start Kiro with `kiro-cli chat --agent bree`, or make it the default with `kiro-cli settings chat.defaultAgent bree`."
            )
        ),
        AgentHookDef(
            name: "antigravity", displayName: "Antigravity", statusKey: "antigravity",
            configDir: ".gemini/config", configFile: "hooks.json",
            createConfigDirIfMissing: true, binaryName: "agy",
            sessionStoreSuffix: "antigravity", disableEnvVar: "BREE_ANTIGRAVITY_HOOKS_DISABLED",
            hookMarker: "bree hooks antigravity", format: .antigravityJSON(timeoutSeconds: 10),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "PreInvocation", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "turn-completion", breeSubcommand: "stop"),
                .init(agentEvent: "Notification", breeSubcommand: "notification"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            aliases: ["agy"],
            dispatch: .pinned(marker: "bree-antigravity-hook-v2"),
            sessionEndIsTurnBoundary: true
        ),
        AgentHookDef(
            name: "rovodev", displayName: "Rovo Dev", statusKey: "rovodev",
            configDir: ".rovodev", configFile: "config.yml", binaryName: "acli",
            sessionStoreSuffix: "rovodev", disableEnvVar: "BREE_ROVODEV_HOOKS_DISABLED",
            hookMarker: "bree hooks rovodev", format: .rovoDevYAML,
            events: [
                .init(agentEvent: "on_complete", breeSubcommand: "stop"),
                .init(agentEvent: "on_error", breeSubcommand: "stop"),
                .init(agentEvent: "on_tool_permission", breeSubcommand: "prompt-submit"),
            ],
            aliases: ["rovo"]
        ),
        AgentHookDef(
            name: "hermes-agent", displayName: "Hermes Agent", statusKey: "hermes-agent",
            configDir: ".hermes", configFile: "config.yaml", configDirEnvOverride: "HERMES_HOME",
            createConfigDirIfMissing: true,
            binaryName: "hermes",
            sessionStoreSuffix: "hermes-agent", disableEnvVar: "BREE_HERMES_AGENT_HOOKS_DISABLED",
            hookMarker: "bree hooks hermes-agent", format: .hermesAgentYAML,
            events: [
                .init(agentEvent: "on_session_start", breeSubcommand: "session-start"),
                .init(agentEvent: "pre_llm_call", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "post_llm_call", breeSubcommand: "agent-response"),
                .init(agentEvent: "pre_approval_request", breeSubcommand: "notification"),
                .init(agentEvent: "post_approval_response", breeSubcommand: "approval-response"),
                .init(agentEvent: "on_session_end", breeSubcommand: "session-end"),
                .init(agentEvent: "on_session_finalize", breeSubcommand: "session-finalize"),
                .init(agentEvent: "on_session_reset", breeSubcommand: "session-start"),
            ],
            sessionEndIsTurnBoundary: true,
            feedHookEvents: ["pre_tool_call", "post_tool_call", "pre_approval_request", "post_approval_response"]
        ),
        AgentHookDef(
            name: "copilot", displayName: "Copilot", statusKey: "copilot",
            configDir: ".copilot", configFile: "config.json", configDirEnvOverride: "COPILOT_HOME",
            sessionStoreSuffix: "copilot", disableEnvVar: "BREE_COPILOT_HOOKS_DISABLED",
            hookMarker: "bree hooks copilot", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "Notification", breeSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "codebuddy", displayName: "CodeBuddy", statusKey: "codebuddy",
            configDir: ".codebuddy", configFile: "settings.json", configDirEnvOverride: "CODEBUDDY_CONFIG_DIR",
            sessionStoreSuffix: "codebuddy", disableEnvVar: "BREE_CODEBUDDY_HOOKS_DISABLED",
            hookMarker: "bree hooks codebuddy", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "Notification", breeSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "factory", displayName: "Factory", statusKey: "factory",
            configDir: ".factory", configFile: "settings.json", binaryName: "droid",
            sessionStoreSuffix: "factory", disableEnvVar: "BREE_FACTORY_HOOKS_DISABLED",
            hookMarker: "bree hooks factory", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "Notification", breeSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "qoder", displayName: "Qoder", statusKey: "qoder",
            configDir: ".qoder", configFile: "settings.json", configDirEnvOverride: "QODER_CONFIG_DIR", binaryName: "qodercli",
            sessionStoreSuffix: "qoder", disableEnvVar: "BREE_QODER_HOOKS_DISABLED",
            hookMarker: "bree hooks qoder", format: .nested(timeoutMs: 5000),
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse"]
        ),
        AgentHookDef(
            name: "kimi", displayName: "Kimi Code", statusKey: "kimi",
            configDir: KimiConfigLocationResolver.kimiCodeConfigDirectory,
            configFile: KimiConfigLocationResolver.configFileName,
            createConfigDirIfMissing: true,
            configDirResolver: { BREECLI.resolvedKimiConfigDirectory().path },
            binaryName: "kimi",
            sessionStoreSuffix: "kimi", disableEnvVar: "BREE_KIMI_HOOKS_DISABLED",
            hookMarker: "bree hooks kimi", format: .tomlArrayTable,
            events: [
                .init(agentEvent: "SessionStart", breeSubcommand: "session-start"),
                .init(agentEvent: "UserPromptSubmit", breeSubcommand: "prompt-submit"),
                .init(agentEvent: "Notification", breeSubcommand: "notification"),
                .init(agentEvent: "Stop", breeSubcommand: "stop"),
                .init(agentEvent: "StopFailure", breeSubcommand: "notification"),
                .init(agentEvent: "SessionEnd", breeSubcommand: "session-end"),
            ],
            feedHookEvents: ["PreToolUse", "PostToolUse"]
        ),
    ]

    static func agentDef(named name: String) -> AgentHookDef? {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return agentDefs.first { $0.name == normalized || $0.aliases.contains(normalized) }
    }
}
