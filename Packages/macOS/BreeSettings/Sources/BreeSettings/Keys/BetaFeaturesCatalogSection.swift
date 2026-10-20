import Foundation

/// Beta-feature toggles. Each key here gates an experimental code path
/// in the running app. New beta keys should follow the pattern
/// `<feature-domain>.beta.<flag-name>` so the bree.json view groups them
/// sensibly.
public struct BetaFeaturesCatalogSection: SettingCatalogSection {
    /// Extensions: the experimental ExtensionKit sidebar-extension surface
    /// (puzzle button, sidebar-toggle provider menu, installed-extension
    /// host, and the extensions browser). Defaults off; while off, every
    /// extension-related entry point is hidden so the feature stays opt-in
    /// while it is in beta.
    public let extensions = DefaultsKey<Bool>(
        id: "extensions.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "extensions.beta.enabled"
    )

    /// Custom sidebars: user/agent-authored sidebars (interpreted Swift or
    /// JSON) discovered from `~/.config/bree/sidebars/` and selectable in the
    /// sidebar button's provider picker. Defaults off (no Settings toggle; set it in bree.json); while off, no custom
    /// sidebar appears in the picker and a persisted custom selection falls
    /// back to the default workspaces sidebar.
    public let customSidebars = DefaultsKey<Bool>(
        id: "customSidebars.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "customSidebars.beta.enabled"
    )

    /// How a workspace row's checklist opens from its summary line while the
    /// workspace-todos feature is on: an anchored popover (default) or the
    /// round-1 inline expansion.
    public let workspaceTodosChecklistStyle = DefaultsKey<WorkspaceTodoChecklistStyle>(
        id: "sidebar.beta.workspaceTodos.checklistStyle",
        defaultValue: .popover,
        userDefaultsKey: "sidebarWorkspaceTodosChecklistStyle"
    )

    /// Remote tmux: mirror a remote host's tmux sessions in the bree sidebar
    /// over `ssh … tmux -CC` (iTerm2-style control mode). Sessions appear as
    /// sidebar workspaces, tmux windows as tabs, and tmux panes as splits;
    /// create/close propagate to the remote, while quitting bree leaves the
    /// remote tmux server running for resume. Defaults off; while off, every
    /// remote-tmux entry point and socket command is gated out so the local
    /// terminal path is unaffected.
    public let remoteTmux = DefaultsKey<Bool>(
        id: "remoteTmux.beta.enabled",
        defaultValue: false,
        userDefaultsKey: "remoteTmux.beta.enabled"
    )

    public init() {}
}
