import GhosttyKit

extension GhosttyApp {
    /// Removes host-action defaults before loading user files. Otherwise clearing
    /// a bree shortcut would revive Ghostty's fallback through the runtime callback.
    func loadGhosttyHostKeybindDefaults(_ config: ghostty_config_t) {
        let triggers = [
            "super+n", "super+t", "super+q", "super+,", "super+enter",
            "super+shift+p", "super+shift+[", "super+shift+]",
            "ctrl+tab", "ctrl+shift+tab", "super+alt+w", "super+shift+w",
            "super+alt+shift+w"
        ]
        loadInlineGhosttyConfig(
            triggers.map { "keybind = \($0)=unbind" }.joined(separator: "\n")
                + "\n" + Self.numberedWorkspaceGhosttyUnbinds,
            into: config,
            prefix: "bree-host-keybind-defaults",
            logLabel: "host keybind defaults"
        )
    }

    func loadBreeOwnedGhosttyKeybindOverrides(_ config: ghostty_config_t) {
        // bree owns these split, close, and workspace font-size shortcuts through
        // KeyboardShortcutSettings.
        // Remove Ghostty's default fallbacks so remapped or cleared shortcuts
        // can reach the focused terminal instead of running actions outside the
        // remappable shortcut layer.
        loadInlineGhosttyConfig(
            """
            keybind = super+d=unbind
            keybind = super+shift+d=unbind
            keybind = super+w=unbind
            keybind = super+alt+w=unbind
            keybind = super+shift+w=unbind
            keybind = super+ctrl+==unbind
            \(Self.numberedWorkspaceGhosttyUnbinds)
            """,
            into: config,
            prefix: "bree-owned-keybind-overrides",
            logLabel: "bree-owned keybind overrides"
        )
    }

    /// Unbinds Ghostty's built-in `super+1…8 = goto_tab` / `super+9 = last_tab`
    /// fallbacks so the numbered "Select Workspace 1…9" shortcut is owned solely
    /// by `KeyboardShortcutSettings`.
    ///
    /// Without this, a `⌘1–9` remapped away in Settings still falls through to the
    /// focused terminal and Ghostty performs `goto_tab`, so the rebind looks
    /// hardcoded (https://github.com/ecyx00/bree/issues/5189). Ghostty registers
    /// each digit under both its Unicode form (`super+1`) and its physical-key form
    /// (`super+digit_1`), so both are unbound here.
    private static let numberedWorkspaceGhosttyUnbinds: String = {
        (1...9).flatMap { digit in
            ["keybind = super+\(digit)=unbind", "keybind = super+digit_\(digit)=unbind"]
        }.joined(separator: "\n")
    }()

}
