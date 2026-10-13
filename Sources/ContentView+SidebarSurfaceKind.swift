import BreeExtensionKit

extension VerticalTabsSidebar {
    func breeSidebarSurfaceKind(for panelType: PanelType) -> BreeSidebarSurfaceKind {
        switch panelType {
        case .terminal:
            return .terminal
        case .browser:
            return .browser
        case .markdown:
            return .markdown
        case .filePreview:
            return .filePreview
        case .rightSidebarTool:
            return .rightSidebarTool
        case .customSidebar, .extensionBrowser, .workspaceTodo, .notifications,
             .accountSignIn:
            return .unknown
        case .project:
            return .project
        }
    }
}
