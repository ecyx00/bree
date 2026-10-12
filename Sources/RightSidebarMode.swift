import AppKit

/// Mode shown in the right sidebar (the panel toggled by ⌘⌥B).
enum RightSidebarMode: String, CaseIterable, Codable, Sendable {
    case files
    case sessions
    case activity
    case architecture
    case customSidebar = "custom-sidebar"

    var label: String {
        switch self {
        case .files: return String(localized: "rightSidebar.mode.files", defaultValue: "Files")
        case .sessions: return String(localized: "rightSidebar.mode.sessions", defaultValue: "Sessions")
        case .activity: return String(localized: "rightSidebar.mode.activity", defaultValue: "Activity")
        case .architecture: return String(localized: "command.toggleArchitecture.title", defaultValue: "Architecture")
        case .customSidebar: return String(localized: "rightSidebar.mode.customSidebar", defaultValue: "Custom")
        }
    }


    var symbolName: String {
        switch self {
        case .files: return "folder"
        case .sessions: return "books.vertical"
        case .activity: return "clock.arrow.circlepath"
        case .architecture: return "point.3.connected.trianglepath.dotted"
        case .customSidebar: return "wand.and.stars"
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .files: return .switchRightSidebarToFiles
        case .sessions: return .switchRightSidebarToSessions
        case .activity: return .switchRightSidebarToActivity
        case .architecture: return .switchRightSidebarToArchitecture
        case .customSidebar: return nil
        }
    }
}

extension RightSidebarMode {
    static let paneModes: [RightSidebarMode] = [.files, .sessions]

    var canOpenAsPane: Bool {
        Self.paneModes.contains(self)
    }
}
