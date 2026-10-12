import Foundation

extension ClosedItemHistoryStore {
    static func title(for snapshot: SessionPanelSnapshot) -> String {
        let candidates = [
            snapshot.customTitle,
            snapshot.title,
            // String-only path math avoids filesystem work for remote paths.
            snapshot.directory.map { ($0 as NSString).lastPathComponent },
        ]
        if let title = candidates
            .compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty }) {
            return title
        }
        switch snapshot.type {
        case .terminal:
            return String(localized: "menu.history.recentlyClosed.panel.terminal", defaultValue: "Terminal")
        case .browser:
            return String(localized: "menu.history.recentlyClosed.panel.browser", defaultValue: "Browser")
        case .markdown:
            return String(localized: "menu.history.recentlyClosed.panel.markdown", defaultValue: "Markdown")
        case .filePreview:
            return String(localized: "menu.history.recentlyClosed.panel.filePreview", defaultValue: "File Preview")
        case .rightSidebarTool:
            return snapshot.rightSidebarTool.flatMap { $0.mode?.label }
                ?? String(localized: "menu.history.recentlyClosed.panel.tool", defaultValue: "Tool")
        case .customSidebar:
            return String(localized: "menu.history.recentlyClosed.panel.customSidebar", defaultValue: "Custom Sidebar")
        case .project:
            return String(localized: "menu.history.recentlyClosed.panel.project", defaultValue: "Project")
        case .extensionBrowser:
            return String(localized: "sidebar.extensions.browser.title", defaultValue: "Sidebar Extensions")
        case .workspaceTodo:
            return String(localized: "workspaceTodoPane.title", defaultValue: "Todos")
        case .notifications:
            return String(localized: "notifications.title", defaultValue: "Notifications")
        case .accountSignIn:
            return String(localized: "account.signIn.workspace.title", defaultValue: "Sign In")
        }
    }
}
