/// Agent commands that bree can intercept with a per-surface launch shim.
public enum TerminalSurfaceAgentCommand: String, CaseIterable, Hashable, Sendable {
    case claude
    case codex
    case pi
    case amp
    case hermes
}

/// Describes one agent command intercepted by the shared per-surface shim path.
struct TerminalSurfaceAgentCommandShimDefinition: Sendable {
    let command: TerminalSurfaceAgentCommand
    let wrapperName: String
    let environmentVariablePrefix: String

    var commandName: String { command.rawValue }

    /// The single capability table for bree-managed agent launch wrappers.
    static let bundled: [Self] = [
        Self(
            command: .claude,
            wrapperName: "bree-claude-wrapper",
            environmentVariablePrefix: "BREE_CLAUDE"
        ),
        Self(
            command: .codex,
            wrapperName: "bree-codex-wrapper",
            environmentVariablePrefix: "BREE_CODEX"
        ),
        Self(
            command: .pi,
            wrapperName: "bree-pi-wrapper",
            environmentVariablePrefix: "BREE_PI"
        ),
        Self(
            command: .amp,
            wrapperName: "bree-amp-wrapper",
            environmentVariablePrefix: "BREE_AMP"
        ),
        Self(
            command: .hermes,
            wrapperName: "bree-hermes-agent-wrapper",
            environmentVariablePrefix: "BREE_HERMES_AGENT"
        ),
    ]
}
