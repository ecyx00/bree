import BreeSettings
import BreeFoundation
import Foundation

/// Top-level navigation targets for the settings window.
///
/// The bree app exposes a fixed set of section panes. Each section gets
/// its own SwiftUI view in `Sections/`; the taxonomy groups them for the
/// sidebar and the search index filters across them. Raw values are
/// persisted and accepted by `bree settings open`, so never rename one.
///
/// Adding a section means: add a case here, add its title and icon in
/// the `SettingsSectionID` extension below, and add a view file in
/// `Sections/`.
public enum SettingsSectionID: String, CaseIterable, Identifiable, Sendable, Hashable {
    case app
    /// Unread indicators, dock badge, agent alerts and notification sounds.
    case notifications
    /// Markdown viewer, file editor and file-opening behavior.
    case editorViewers
    /// App appearance, accent color, terminal themes, and browser theme.
    case themes
    case terminal
    case textBox
    case sidebarAppearance
    case automation
    case browser
    case browserImport
    case globalHotkey
    case keyboardShortcuts
    case workspaceColors
    /// Global wiki folder.
    case wiki
    case settingsJSON
    case reset
    /// Host pane for bree.json and reset.
    case advanced

    public var id: Self { self }

    /// Maps the catalog-owned destination into this package's navigation id.
    ///
    /// Keep this switch exhaustive as UserFacingSettingSection grows so
    /// catalog metadata can never refer to an unknown Settings destination.
    public init(userFacingSection section: UserFacingSettingSection) {
        switch section {
        case .app:
            self = .app
        }
    }

    /// User-facing section title shown in the sidebar.
    public var title: String {
        switch self {
        case .app: return String(localized: "settings.section.app", defaultValue: "App")
        case .notifications: return String(localized: "settings.section.notifications", defaultValue: "Notifications")
        case .editorViewers: return String(localized: "settings.section.editorViewers", defaultValue: "Editor & Viewers")
        case .themes: return String(localized: "settings.section.themes", defaultValue: "Themes")
        case .terminal: return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox: return String(localized: "settings.section.textBox", defaultValue: "TextBox")
        case .sidebarAppearance: return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .automation: return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .browser: return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport: return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey: return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts: return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .workspaceColors: return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .wiki: return String(localized: "settings.section.wiki", defaultValue: "Wiki")
        case .settingsJSON: return BreeIdentity.current.configFileName
        case .reset: return String(localized: "settings.section.reset", defaultValue: "Reset")
        case .advanced: return String(localized: "settings.section.advanced", defaultValue: "Advanced")
        }
    }

    /// SF Symbol shown alongside the title in the sidebar.
    public var symbolName: String {
        switch self {
        case .app: return "gearshape"
        case .notifications: return "bell"
        case .editorViewers: return "doc.richtext"
        case .themes: return "paintbrush"
        case .terminal: return "terminal"
        case .textBox: return "textformat"
        case .sidebarAppearance: return "sidebar.left"
        case .automation: return "wand.and.sparkles"
        case .browser: return "globe"
        case .browserImport: return "square.and.arrow.down"
        case .globalHotkey: return "keyboard.badge.ellipsis"
        case .keyboardShortcuts: return "keyboard"
        case .workspaceColors: return "paintpalette"
        case .wiki: return "books.vertical"
        case .settingsJSON: return "doc.text"
        case .reset: return "arrow.counterclockwise"
        case .advanced: return "slider.horizontal.3"
        }
    }

    /// Space-separated keywords used by the settings search index. Each
    /// section can advertise additional terms here so users find sections
    /// by capability rather than only by title.
    public var searchKeywords: String {
        switch self {
        case .app: return "language workspace menu bar"
        case .notifications: return "notifications dock badge unread ring flash sound agent alert desktop imessage menu bar"
        case .editorViewers: return "markdown viewer file editor word wrap syntax line numbers drops open files preview"
        case .themes: return "theme themes color scheme palette ghostty terminal colors appearance light dark accent browser"
        case .terminal: return "scrollbar copy on select agent resume hibernation"
        case .textBox: return "textbox text box rich input prompt default new terminal workspace split tab focus show"
        case .sidebarAppearance: return "sidebar details branches material terminal background"
        case .automation: return "socket integrations hooks ports claude cursor gemini naming auto naming workspace tabs"
        case .browser: return "search engine links history theme"
        case .browserImport: return "browser import bookmarks history cookies"
        case .globalHotkey: return "system wide shortcut"
        case .keyboardShortcuts: return "keybindings commands chords"
        case .workspaceColors: return "palette tabs indicator"
        case .wiki: return "wiki folder notes pages agent guide"
        case .settingsJSON: return "config file preferences editor schema jsonc reload"
        case .reset: return "defaults reset"
        case .advanced: return "advanced config json reset remote tmux hibernation"
        }
    }
}
