import Bonsplit
import Foundation

enum BreeSurfaceTabBarBuiltInAction: String, Codable, Sendable, CaseIterable, Hashable {
    case newWorkspace = "bree.newWorkspace"
    case newTerminal = "bree.newTerminal"
    case newBrowser = "bree.newBrowser"
    case splitRight = "bree.splitRight"
    case splitDown = "bree.splitDown"
    case copyWorkingDirectory = "bree.copyWorkingDirectory"
    case copyProjectRoot = "bree.copyProjectRoot"
    case copyScreen = "bree.copyScreen"
    case toggleFiles = "bree.toggleFiles"
    case newWindow = "bree.newWindow"
    case toggleArchitecture = "bree.toggleArchitecture"
    case toggleWiki = "bree.toggleWiki"
    case showBoard = "bree.showBoard"

    init?(configID: String) {
        switch configID {
        case "bree.newWorkspace", "newWorkspace":
            self = .newWorkspace
        case "bree.newTerminal", "newTerminal":
            self = .newTerminal
        case "bree.newBrowser", "newBrowser":
            self = .newBrowser
        case "bree.splitRight", "splitRight":
            self = .splitRight
        case "bree.splitDown", "splitDown":
            self = .splitDown
        case "bree.copyWorkingDirectory", "copyWorkingDirectory":
            self = .copyWorkingDirectory
        case "bree.copyProjectRoot", "copyProjectRoot":
            self = .copyProjectRoot
        case "bree.copyScreen", "copyScreen":
            self = .copyScreen
        case "bree.toggleFiles", "toggleFiles":
            self = .toggleFiles
        case "bree.newWindow", "newWindow":
            self = .newWindow
        case "bree.toggleArchitecture", "toggleArchitecture":
            self = .toggleArchitecture
        case "bree.toggleWiki", "toggleWiki":
            self = .toggleWiki
        case "bree.showBoard", "showBoard":
            self = .showBoard
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
        case .showBoard:
            return (String(localized: "menu.window.board", defaultValue: "Board"), ["board", "status", "kanban", "tasks"])
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
        case .showBoard:
            return "rectangle.split.3x1"
        }
    }

    var bonsplitAction: BonsplitConfiguration.SplitActionButton.Action? {
        switch self {
        case .newWorkspace,
             .copyWorkingDirectory, .copyProjectRoot, .copyScreen, .toggleFiles, .newWindow, .toggleArchitecture, .toggleWiki, .showBoard:
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

extension BreeSurfaceTabBarBuiltInAction {
    /// The user-editable shortcut that triggers the same behavior as this
    /// built-in action. Menus that list built-in actions read the live
    /// `KeyboardShortcutSettings` value through this mapping, so a rebind or
    /// an unbind in Settings or `bree.json` shows up the next time the menu
    /// opens. Actions with no bree-owned shortcut return nil.
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
        case .showBoard: return .showBoard
        case .copyWorkingDirectory, .copyProjectRoot, .copyScreen: return nil
        }
    }

}
