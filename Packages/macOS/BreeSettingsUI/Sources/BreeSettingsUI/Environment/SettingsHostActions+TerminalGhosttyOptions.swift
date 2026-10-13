import BreeFoundation

/// Defaults for previews, tests, and hosts without a Ghostty config.
public extension SettingsHostActions {
    /// Ghostty's defaults.
    func terminalGhosttyOptions() async -> GhosttyTerminalOptionsSnapshot { .defaults }

    /// Accepts the change without persisting it.
    func applyTerminalGhosttyOption(_ change: GhosttyTerminalOptionChange) async -> Bool { true }

    /// Ghostty's defaults: no colors known, no overrides.
    func terminalColorSnapshot() async -> GhosttyTerminalColorSnapshot { .defaults }

    /// Accepts the overrides without persisting them.
    func setTerminalColorOverrides(_ overrides: GhosttyTerminalColors) async -> Bool { true }
}
