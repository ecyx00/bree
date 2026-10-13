import BreeExtensionKit
import SwiftUI

@main
final class SampleSidebarExtension: @MainActor BreeSidebarExtension {
    static let manifest = BreeExtensionManifest(
        id: "co.manaflow.BREEExtKitSampleSidebarApp.Extension",
        displayName: String(localized: "sampleSidebar.manifest.displayName", defaultValue: "Bree Sample Sidebar Extension"),
        readScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
            .notifications,
            .networkPorts,
        ],
        actionScopes: [
            .createSurface,
            .selectWorkspace,
            .selectSurface,
            .navigateWorkspace,
            .navigateSurface,
        ]
    )

    private let model = SidebarConnectionModel()

    required init() {}

    var body: some View {
        SampleSidebarView(model: model)
    }

    func update(context: BreeSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: BreeSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
