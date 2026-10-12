import Bonsplit
import Foundation

enum CmuxSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "cmux.newWorkspace"
    case newTerminal = "cmux.newTerminal"
    case newBrowser = "cmux.newBrowser"
    case splitRight = "cmux.splitRight"
    case splitDown = "cmux.splitDown"
    case copyWorkingDirectory = "cmux.copyWorkingDirectory"
    case copyProjectRoot = "cmux.copyProjectRoot"
    case copyScreen = "cmux.copyScreen"
    case toggleFiles = "cmux.toggleFiles"
    case newWindow = "cmux.newWindow"
    case toggleArchitecture = "cmux.toggleArchitecture"
    case toggleWiki = "cmux.toggleWiki"

    init?(configID: String) {
        switch configID {
        case "cmux.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "cmux.newTerminal", "newTerminal":
            self = .newTerminal
        case "cmux.newBrowser", "newBrowser":
            self = .newBrowser
        case "cmux.splitRight", "splitRight":
            self = .splitRight
        case "cmux.splitDown", "splitDown":
            self = .splitDown
        case "cmux.copyWorkingDirectory", "copyWorkingDirectory":
            self = .copyWorkingDirectory
        case "cmux.copyProjectRoot", "copyProjectRoot":
            self = .copyProjectRoot
        case "cmux.copyScreen", "copyScreen":
            self = .copyScreen
        case "cmux.toggleFiles", "toggleFiles":
            self = .toggleFiles
        case "cmux.newWindow", "newWindow":
            self = .newWindow
        case "cmux.toggleArchitecture", "toggleArchitecture":
            self = .toggleArchitecture
        case "cmux.toggleWiki", "toggleWiki":
            self = .toggleWiki
        default:
            return nil
        }
    }

    var configID: String {
        rawValue
    }

    var resolvedConfigMetadata: (title: String, keywords: [String]) {
        switch self {
        case .newWorkspace:
            return (String(localized: "command.newWorkspace.title", defaultValue: "New Workspace"), ["create", "new", "workspace"])
        case .newTerminal:
            return (String(localized: "command.newTerminalTab.title", defaultValue: "New Terminal Tab"), ["new", "terminal", "tab", "surface"])
        case .newBrowser:
            return (String(localized: "command.newBrowserTab.title", defaultValue: "New Browser Tab"), ["new", "browser", "tab", "surface"])
        case .splitRight:
            return (String(localized: "command.terminalSplitRight.title", defaultValue: "Split Right"), ["terminal", "split", "right"])
        case .splitDown:
            return (String(localized: "command.terminalSplitDown.title", defaultValue: "Split Down"), ["terminal", "split", "down"])
        case .copyWorkingDirectory:
            return (String(localized: "command.copyWorkingDirectory.title", defaultValue: "Copy Working Directory"), ["copy", "clipboard", "path", "directory", "cwd", "pwd"])
        case .copyProjectRoot:
            return (String(localized: "command.copyProjectRoot.title", defaultValue: "Copy Project Root"), ["copy", "clipboard", "project", "git", "root", "repository", "path"])
        case .copyScreen:
            return (String(localized: "command.copyScreen.title", defaultValue: "Copy Visible Screen"), ["copy", "clipboard", "screen", "output", "terminal", "visible"])
        case .toggleFiles:
            return (String(localized: "rightSidebar.mode.files", defaultValue: "Files"), ["files", "explorer", "sidebar", "tree"])
        case .newWindow:
            return (String(localized: "menu.file.newWindow", defaultValue: "New Window"), ["new", "window"])
        case .toggleArchitecture:
            return (String(localized: "command.toggleArchitecture.title", defaultValue: "Architecture"), ["architecture", "diagram", "archify", "design"])
        case .toggleWiki:
            return (String(localized: "command.toggleWiki.title", defaultValue: "Wiki"), ["wiki", "notes", "concepts", "memory"])
        }
    }

    var defaultIcon: String {
        switch self {
        case .newWorkspace:
            return "plus.square"
        case .newTerminal:
            return "terminal"
        case .newBrowser:
            return "globe"
        case .splitRight:
            return "square.split.2x1"
        case .splitDown:
            return "square.split.1x2"
        case .copyWorkingDirectory:
            return "doc.on.doc"
        case .copyProjectRoot:
            return "arrow.triangle.branch"
        case .copyScreen:
            return "text.viewfinder"
        case .toggleFiles:
            return "folder"
        case .newWindow:
            return "macwindow.badge.plus"
        case .toggleArchitecture:
            return "point.3.connected.trianglepath.dotted"
        case .toggleWiki:
            return "book.closed"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace,
             .copyWorkingDirectory, .copyProjectRoot, .copyScreen, .toggleFiles, .newWindow, .toggleArchitecture, .toggleWiki:
            return nil
        case .newTerminal:
            return .newTerminal
        case .newBrowser:
            return .newBrowser
        case .splitRight:
            return .splitRight
        case .splitDown:
            return .splitDown
        }
    }
}

extension CmuxSurfaceTabBarBuiltInAction {
    /// The user-editable shortcut that triggers the same behavior as this
    /// built-in action. Menus that list built-in actions read the live
    /// `KeyboardShortcutSettings` value through this mapping, so a rebind or
    /// an unbind in Settings or `cmux.json` shows up the next time the menu
    /// opens. Actions with no cmux-owned shortcut return nil.
    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch self {
        case .newWorkspace: return .newTab
        case .newTerminal: return .newSurface
        case .newBrowser: return .openBrowser
        case .splitRight: return .splitRight
        case .splitDown: return .splitDown
        case .toggleFiles: return .toggleRightSidebar
        case .newWindow: return .newWindow
        case .toggleArchitecture: return .toggleArchitecture
        case .toggleWiki: return .toggleWiki
        case .copyWorkingDirectory, .copyProjectRoot, .copyScreen: return nil
        }
    }

}
