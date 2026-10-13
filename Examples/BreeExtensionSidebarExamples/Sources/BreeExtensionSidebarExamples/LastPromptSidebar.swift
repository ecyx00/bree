import BreeSidebarProviderKit

public struct LastPromptSidebar: BreeSidebarProvider {
    public let descriptor = BreeSidebarProviderDescriptor(
        id: "com.example.bree.sidebar.last-prompt",
        title: localized("example.sidebar.lastPrompt.title", "Last Prompt"),
        subtitle: localized("example.sidebar.lastPrompt.subtitle", "User extension"),
        systemImageName: "clock",
        isHostProvided: false
    )

    public init() {}

    public func render(snapshot: BreeSidebarProviderSnapshot) -> BreeSidebarProviderRenderModel {
        let recent = snapshot.workspaces
            .filter { $0.latestSubmittedAt != nil }
            .sorted { lhs, rhs in
                guard let lhsDate = lhs.latestSubmittedAt else { return false }
                guard let rhsDate = rhs.latestSubmittedAt else { return true }
                return lhsDate > rhsDate
            }

        let sections = [
            ExampleSidebarSection(
                id: "recent",
                title: localized("example.sidebar.group.recentPrompts", "Recent Prompts"),
                systemImageName: "clock",
                projectRootPath: nil,
                workspaces: recent
            )
            .render(subtitle: promptSubtitle, trailingText: promptTrailingText),
            ExampleSidebarSection(
                id: "none",
                title: localized("example.sidebar.group.noPrompts", "No Prompts"),
                systemImageName: "tray",
                projectRootPath: nil,
                workspaces: snapshot.workspaces.filter { $0.latestSubmittedAt == nil }
            )
            .render(subtitle: promptSubtitle, trailingText: promptTrailingText),
        ]

        return renderModel(providerId: descriptor.id, snapshot: snapshot, sections: sections)
    }

    private func promptSubtitle(_ workspace: BreeSidebarProviderWorkspace) -> BreeSidebarProviderText? {
        if let message = trimmed(workspace.latestSubmittedMessage) {
            return .plain(message)
        }
        return .localized(localized("example.sidebar.noPromptsYet", "No prompts yet"))
    }

    private func promptTrailingText(_ workspace: BreeSidebarProviderWorkspace) -> BreeSidebarProviderText? {
        workspace.latestSubmittedAt.map { .relativeDate($0, style: .compact) }
    }
}
