import BreeTerminalCore

/// App-target alias for ``BreeTerminalCore/GhosttyConfig``, lifted into
/// BreeTerminalCore in stack D tranche A. Keeps every `GhosttyConfig` call site
/// (and `GhosttyConfig.ColorSchemePreference` / `GhosttyConfig.UserAppearanceConfigSummary`
/// member lookups) byte-identical across the app target.
typealias GhosttyConfig = BreeTerminalCore.GhosttyConfig
