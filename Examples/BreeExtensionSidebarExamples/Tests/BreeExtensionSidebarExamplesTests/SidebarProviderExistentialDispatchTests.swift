import BreeSidebarProviderKit
@testable import BreeExtensionSidebarExamples
import XCTest

/// Regression coverage for https://github.com/ecyx00/bree/issues/5173.
///
/// The host renders sidebar views through an `any BreeSidebarProvider`
/// existential (`BreeExtensionSidebarSelection.provider(for:)?.render(snapshot:)`).
/// `render(snapshot:)` must therefore be a protocol *requirement* so the call
/// dynamic-dispatches to the concrete view. When #4994 demoted it to a
/// protocol-extension default (returning no sections), every built-in view
/// rendered an empty sidebar even though the provider and snapshot were correct.
final class SidebarProviderExistentialDispatchTests: XCTestCase {
    /// Super Compact lists every workspace in a single section, so calling it
    /// through the existential must yield exactly the same rows as the concrete
    /// call — not the empty protocol-extension default.
    func testSuperCompactRendersIdenticallyThroughExistential() {
        let snapshot = Self.snapshot(workspaceCount: 3)
        let concrete = SuperCompactSidebar()
        let existential: any BreeSidebarProvider = concrete

        let concreteModel = concrete.render(snapshot: snapshot)
        let existentialModel = existential.render(snapshot: snapshot)

        XCTAssertFalse(concreteModel.sections.isEmpty, "concrete render should produce a section")
        XCTAssertEqual(concreteModel.sections.flatMap(\.rows).count, 3)
        XCTAssertEqual(
            existentialModel.sections,
            concreteModel.sections,
            "render(snapshot:) must dynamic-dispatch through the existential, not the empty default"
        )
    }

    /// Every built-in view that distributes all workspaces across sections must
    /// produce rows when invoked through the existential. (Browser Stack is
    /// excluded: it renders only browser-tagged workspaces.)
    func testWorkspaceListingProvidersRenderRowsThroughExistential() {
        let snapshot = Self.snapshot(workspaceCount: 4)
        let listingProviderIDs: Set<String> = [
            "com.example.bree.sidebar.project-worktrees",
            "com.example.bree.sidebar.attention-queue",
            "com.example.bree.sidebar.dev-servers",
            "com.example.bree.sidebar.last-prompt",
            "com.example.bree.sidebar.super-compact",
        ]
        for provider in SidebarExamples.providers where listingProviderIDs.contains(provider.descriptor.id) {
            let model = provider.render(snapshot: snapshot)
            XCTAssertFalse(
                model.sections.flatMap(\.rows).isEmpty,
                "Provider \(provider.descriptor.id) rendered no rows through the existential"
            )
        }
    }

    private static func snapshot(workspaceCount: Int) -> BreeSidebarProviderSnapshot {
        let workspaces = (0..<workspaceCount).map { index in
            BreeSidebarProviderWorkspace(
                id: UUID(),
                title: "Workspace \(index)",
                customDescription: nil,
                isPinned: false,
                rootPath: "/tmp/ws\(index)",
                projectRootPath: "/tmp/ws\(index)",
                branchSummary: "main",
                remoteDisplayTarget: nil,
                remoteConnectionState: "disconnected",
                unreadCount: 0,
                latestNotificationText: nil,
                latestSubmittedMessage: "hello",
                latestSubmittedAt: Date(timeIntervalSince1970: 1_000_000),
                listeningPorts: []
            )
        }
        return BreeSidebarProviderSnapshot(
            sequence: 1,
            selectedWorkspaceId: nil,
            workspaces: workspaces
        )
    }
}
