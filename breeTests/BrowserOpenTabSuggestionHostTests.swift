import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite struct BrowserOpenTabSuggestionHostTests {
    @Test("Open-tab suggestions preserve their Dock host")
    func preservesWorkspaceDockHost() throws {
        let workspaceId = UUID()
        let panelId = UUID()
        let snapshot = try #require(BrowserOpenTabSuggestionSnapshot(
            host: .workspaceDock(workspaceId),
            panelId: panelId,
            url: "https://dock.example/dashboard",
            title: "Dock Dashboard"
        ))
        let index = BrowserOpenTabSuggestionIndex()

        let matches = index.matching(
            for: "dashboard",
            currentWorkspaceId: workspaceId,
            currentHost: .workspace(workspaceId),
            currentPanelId: UUID(),
            currentPanelSnapshot: nil,
            includeCurrentPanelForSingleCharacterQuery: false,
            limit: 5,
            seedSnapshots: { [snapshot] }
        )

        #expect(matches.count == 1)
        #expect(matches.first?.host == .workspaceDock(workspaceId))
        #expect(matches.first?.panelId == panelId)
    }
}
