import BreeFoundation
import SwiftUI

enum SettingsNavigationTarget: String, CaseIterable, Identifiable {
    case app
    case notifications
    case editorViewers
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
    case wiki
    case settingsJSON
    case reset
    case advanced

    var id: Self { self }

    var title: String {
        switch self {
        case .app:
            return String(localized: "settings.section.app", defaultValue: "App")
        case .notifications:
            return String(localized: "settings.section.notifications", defaultValue: "Notifications")
        case .editorViewers:
            return String(localized: "settings.section.editorViewers", defaultValue: "Editor & Viewers")
        case .themes:
            return String(localized: "settings.section.themes", defaultValue: "Themes")
        case .terminal:
            return String(localized: "settings.section.terminal", defaultValue: "Terminal")
        case .textBox:
            return String(localized: "settings.section.textBox", defaultValue: "TextBox")
        case .workspaceColors:
            return String(localized: "settings.section.workspaceColors", defaultValue: "Workspace Colors")
        case .wiki:
            return String(localized: "settings.section.wiki", defaultValue: "Wiki")
        case .sidebarAppearance:
            return String(localized: "settings.section.sidebarAppearance", defaultValue: "Sidebar")
        case .automation:
            return String(localized: "settings.section.automation", defaultValue: "Automation")
        case .browser:
            return String(localized: "settings.section.browser", defaultValue: "Browser")
        case .browserImport:
            return String(localized: "settings.browser.import", defaultValue: "Import Browser Data")
        case .globalHotkey:
            return String(localized: "settings.section.globalHotkey", defaultValue: "Global Hotkey")
        case .keyboardShortcuts:
            return String(localized: "settings.section.keyboardShortcuts", defaultValue: "Keyboard Shortcuts")
        case .settingsJSON:
            return String(localized: "settings.section.settingsJSON", defaultValue: "bree.json")
        case .reset:
            return String(localized: "settings.section.reset", defaultValue: "Reset")
        case .advanced:
            return String(localized: "settings.section.advanced", defaultValue: "Advanced")
        }
    }

    var symbolName: String {
        switch self {
        case .app:
            return "gearshape"
        case .notifications:
            return "bell"
        case .editorViewers:
            return "doc.richtext"
        case .themes:
            return "paintbrush"
        case .terminal:
            return "terminal"
        case .textBox:
            return "textformat"
        case .workspaceColors:
            return "paintpalette"
        case .wiki:
            return "books.vertical"
        case .sidebarAppearance:
            return "sidebar.left"
        case .automation:
            return "wand.and.sparkles"
        case .browser:
            return "globe"
        case .browserImport:
            return "square.and.arrow.down"
        case .globalHotkey:
            return "keyboard.badge.ellipsis"
        case .keyboardShortcuts:
            return "keyboard"
        case .settingsJSON:
            return "doc.text"
        case .reset:
            return "arrow.counterclockwise"
        case .advanced:
            return "slider.horizontal.3"
        }
    }

    var searchText: String {
        switch self {
        case .app:
            return "\(title) language workspace menu bar telemetry default terminal"
        case .notifications:
            return "\(title) dock badge unread ring flash sound agent alert desktop imessage menu bar"
        case .editorViewers:
            return "\(title) markdown viewer file editor word wrap syntax line numbers drops open files preview"
        case .themes:
            return "\(title) theme themes color scheme palette ghostty terminal colors appearance light dark accent browser"
        case .terminal:
            return "\(title) scrollbar auto resume restore reopen relaunch quit sessions agents claude codex opencode rovodev hibernation idle suspend commands approvals prefixes toggle"
        case .textBox:
            return "\(title) textbox text box rich input prompt new terminal workspace split tab focus height"
        case .workspaceColors:
            return "\(title) palette tabs"
        case .wiki:
            return "\(title) wiki folder notes pages agent guide"
        case .sidebarAppearance:
            return "\(title) sidebar details branches badges material terminal background"
        case .automation:
            return "\(title) socket integrations hooks ports claude cursor gemini kiro naming auto naming workspace tabs"
        case .browser:
            return "\(title) search engine links history"
        case .browserImport:
            return "\(title) browser import data bookmarks history cookies"
        case .globalHotkey:
            return "\(title) system wide shortcut"
        case .keyboardShortcuts:
            return "\(title) keybindings commands chords"
        case .settingsJSON:
            return "\(title) config file preferences editor documentation schema jsonc reload"
        case .reset:
            return "\(title) defaults"
        case .advanced:
            return "\(title) config json reset remote tmux hibernation"
        }
    }
}

enum SettingsNavigationRequest {
    static let notificationName = Notification.Name("bree.settings.navigate")
    private static let targetKey = "target"
    private static let anchorKey = "anchor"
    private static let highlightKey = "highlight"

    static func post(_ target: SettingsNavigationTarget, anchorID: String? = nil, highlight: Bool = false) {
        NotificationCenter.default.post(
            name: notificationName,
            object: nil,
            userInfo: [
                targetKey: target.rawValue,
                anchorKey: anchorID ?? SettingsSearchIndex.sectionID(for: target),
                highlightKey: highlight
            ]
        )
    }

    static func target(from notification: Notification) -> SettingsNavigationTarget? {
        destination(from: notification)?.target
    }

    static func destination(from notification: Notification) -> SettingsNavigationDestination? {
        guard
            let rawValue = notification.userInfo?[targetKey] as? String,
            let target = SettingsNavigationTarget(rawValue: rawValue)
        else {
            return nil
        }
        let anchorID = notification.userInfo?[anchorKey] as? String
        let shouldHighlight = notification.userInfo?[highlightKey] as? Bool ?? false
        return SettingsNavigationDestination(
            target: target,
            anchorID: anchorID ?? SettingsSearchIndex.sectionID(for: target),
            shouldHighlight: shouldHighlight
        )
    }
}

struct SettingsNavigationDestination {
    let target: SettingsNavigationTarget
    let anchorID: String
    let shouldHighlight: Bool
}

struct SettingsSearchHighlightState: Equatable {
    let anchorID: String?
    let token: Int
    let startedAt: Date?
}

private struct SettingsSearchHighlightStateKey: EnvironmentKey {
    static let defaultValue = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)
}

extension EnvironmentValues {
    var settingsSearchHighlightState: SettingsSearchHighlightState {
        get { self[SettingsSearchHighlightStateKey.self] }
        set { self[SettingsSearchHighlightStateKey.self] = newValue }
    }
}

extension View {
    @ViewBuilder
    func settingsSearchAnchor(_ anchorID: String?) -> some View {
        if let anchorID {
            settingsSearchAnchors([anchorID])
        } else {
            self
        }
    }

    @ViewBuilder
    func settingsSearchAnchors(_ anchorIDs: [String]) -> some View {
        let filteredAnchorIDs = anchorIDs.filter { !$0.isEmpty }
        if let primaryAnchorID = filteredAnchorIDs.first {
            self
                .id(primaryAnchorID)
                .modifier(SettingsSearchHighlightModifier(anchorIDs: filteredAnchorIDs))
        } else {
            self
        }
    }
}

private struct SettingsSearchHighlightModifier: ViewModifier {
    @Environment(\.breePalette) private var palette
    @Environment(\.settingsSearchHighlightState) private var highlightState
    let anchorIDs: [String]

    private func matches(_ state: SettingsSearchHighlightState) -> Bool {
        guard let anchorID = state.anchorID else { return false }
        return anchorIDs.contains(anchorID)
    }

    func body(content: Content) -> some View {
        content
            .background {
                if matches(highlightState) {
                    TimelineView(.animation) { context in
                        let opacity = highlightOpacity(at: context.date, for: highlightState)
                        RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                            .fill(palette.focusRing.opacity(opacity * 0.24))
                            .overlay(
                                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                                    .stroke(palette.focusRing.opacity(opacity), lineWidth: 2.5)
                            )
                            .shadow(color: palette.focusRing.opacity(opacity * 0.24), radius: 8, x: 0, y: 0)
                    }
                }
            }
    }

    private func highlightOpacity(at date: Date, for state: SettingsSearchHighlightState) -> Double {
        guard matches(state), let startedAt = state.startedAt else { return 0 }
        let elapsed = date.timeIntervalSince(startedAt)
        if elapsed < 0.14 {
            return max(0, min(1, elapsed / 0.14))
        }
        if elapsed < 5 {
            return 1
        }
        if elapsed < 5.9 {
            return max(0, 1 - ((elapsed - 5) / 0.9))
        }
        return 0
    }
}

enum SettingsSearchEntryKind {
    case section
    case setting
}

struct SettingsSearchEntry: Identifiable {
    let id: String
    let kind: SettingsSearchEntryKind
    let target: SettingsNavigationTarget
    let title: String
    let subtitle: String?
    let symbolName: String
    let normalizedSearchText: String
    let normalizedSearchWords: [String]
    let normalizedSearchWordSet: Set<String>

    init(
        id: String,
        kind: SettingsSearchEntryKind,
        target: SettingsNavigationTarget,
        title: String,
        subtitle: String?,
        symbolName: String,
        searchText: String
    ) {
        self.id = id
        self.kind = kind
        self.target = target
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        let normalizedSearchText = SettingsSearchIndex.normalized("\(title) \(subtitle ?? "") \(searchText)")
        self.normalizedSearchText = normalizedSearchText
        self.normalizedSearchWords = SettingsSearchIndex.normalizedTokens(for: normalizedSearchText)
        self.normalizedSearchWordSet = Set(normalizedSearchWords)
    }
}
