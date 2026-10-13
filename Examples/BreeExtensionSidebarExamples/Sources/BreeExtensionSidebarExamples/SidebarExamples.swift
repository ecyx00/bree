import BreeSidebarProviderKit
import Foundation

public enum SidebarExamples {
    public static let providers: [any BreeSidebarProvider] = [
        ProjectWorktreeSidebar(),
        AttentionQueueSidebar(),
        DevServerSidebar(),
        LastPromptSidebar(),
        SuperCompactSidebar(),
        BrowserStackSidebar(onAsyncStateLoaded: {
            BrowserStackSidebar.postStateDidLoadNotification()
        }),
    ]
}

struct ExampleSidebarSection {
    var id: String
    var title: BreeSidebarProviderLocalizedText
    var systemImageName: String
    var projectRootPath: String?
    var workspaces: [BreeSidebarProviderWorkspace]

    func render(
        rowTitle: (BreeSidebarProviderWorkspace) -> String = { $0.title },
        accessory: BreeSidebarProviderRowAccessory? = .inspector,
        subtitle: (BreeSidebarProviderWorkspace) -> BreeSidebarProviderText? = { _ in nil },
        trailingText: (BreeSidebarProviderWorkspace) -> BreeSidebarProviderText? = { _ in nil },
        leadingIcon: (BreeSidebarProviderWorkspace) -> BreeSidebarProviderIcon? = { _ in nil }
    ) -> BreeSidebarProviderSection {
        BreeSidebarProviderSection(
            id: id,
            treeSection: BreeSidebarProviderTreeSection(
                id: id,
                title: title.defaultValue,
                titleText: title,
                subtitle: nil,
                systemImageName: systemImageName,
                projectRootPath: projectRootPath,
                workspaceIds: workspaces.map(\.id)
            ),
            rows: workspaces.map { workspace in
                BreeSidebarProviderRow(
                    id: workspace.id,
                    title: rowTitle(workspace),
                    workspaceId: workspace.id,
                    accessory: accessory,
                    subtitle: subtitle(workspace),
                    trailingText: trailingText(workspace),
                    leadingIcon: leadingIcon(workspace)
                )
            }
        )
    }
}

func localized(_ key: String, _ defaultValue: String) -> BreeSidebarProviderLocalizedText {
    BreeSidebarProviderLocalizedText(key: key, defaultValue: defaultValue)
}

func renderModel(
    providerId: String,
    snapshot: BreeSidebarProviderSnapshot,
    sections: [BreeSidebarProviderSection],
    presentation: BreeSidebarProviderPresentation = .tree
) -> BreeSidebarProviderRenderModel {
    BreeSidebarProviderRenderModel(
        providerId: providerId,
        snapshotSequence: snapshot.sequence,
        sections: presentation == .browserStack ? sections : sections.filter { !$0.rows.isEmpty },
        presentation: presentation
    )
}

func trimmed(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
          !trimmed.isEmpty else {
        return nil
    }
    return trimmed
}

func projectRoot(for workspace: BreeSidebarProviderWorkspace) -> String? {
    trimmed(workspace.projectRootPath)
}

func displayName(for path: String) -> String {
    let url = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    let name = url.lastPathComponent
    return name.isEmpty ? path : name
}
