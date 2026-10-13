import Foundation

/// The single source of truth for every bree setting.
///
/// ``SettingCatalog`` is the root value-typed registry. It is composed of
/// ``SettingCatalogSection`` sub-structs grouped by dotted-id prefix
/// (`app.*`, `terminal.*`, `automation.*`, …). Construct one at app
/// startup and inject it into the stores and UI layers.
///
/// ``all`` is derived by reflection over the catalog's stored properties
/// (the default ``SettingCatalogSection/all`` implementation), recursing
/// into nested sections. Adding a key is exactly one line in the
/// appropriate `*CatalogSection` file and it shows up in every derived
/// view — schema, migration, search — automatically.
///
/// ```swift
/// let catalog = SettingCatalog()
/// let store = UserDefaultsSettingsStore(
///     defaults: .standard,
///     migrating: catalog.all
/// )
/// await store.set(.dark, for: catalog.app.appearance)
/// ```
public struct SettingCatalog: SettingCatalogSection {
    public let app = AppCatalogSection()
    public let terminal = TerminalCatalogSection()
    public let notifications = NotificationsCatalogSection()
    public let sidebar = SidebarCatalogSection()
    public let sidebarAppearance = SidebarAppearanceCatalogSection()
    /// Settings for bree pane divider and focused-pane chrome.
    public let paneChrome = PaneChromeCatalogSection()
    public let workspaceColors = WorkspaceColorsCatalogSection()
    /// Settings for sidebar workspace groups (the `workspaceGroups.*` keys).
    public let workspaceGroups = WorkspaceGroupsCatalogSection()
    public let automation = AutomationCatalogSection()
    /// The app-wide switch for agent messages (the `agentMessages.*` keys).
    public let agentMessages = AgentMessagesCatalogSection()
    public let browser = BrowserCatalogSection()
    /// Settings for the built-in markdown viewer (the `markdown.*` keys).
    public let markdown = MarkdownCatalogSection()
    /// Settings for the built-in plain-text file editor (the `fileEditor.*` keys).
    public let fileEditor = FileEditorCatalogSection()
    public let betaFeatures = BetaFeaturesCatalogSection()
    /// Settings for custom (user/agent-authored) sidebars (the `customSidebars.*` keys).
    public let customSidebars = CustomSidebarsCatalogSection()
    public let shortcuts = KeyboardShortcutsCatalogSection()
    public let integrations = IntegrationsCatalogSection()
    public let account = AccountCatalogSection()

    public init() {}
}
