import BreeCommandPalette
import BreeSurfaceCatalogModel
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite
@MainActor
struct CurrentWorkCommandPaletteTests {
    @Test
    func testFindWorkKeepsPaletteOpenForTheSharedSnapshot() {
        let contribution = ContentView.commandPaletteFindWorkContribution()
        #expect(contribution.commandId == "palette.findWork")
        #expect(!(contribution.dismissOnRun))
        #expect(contribution.keywords.contains("attention"))
    }

    @Test
    func testObservedResourceCannotNavigateAReboundPanel() {
        let item = fixture()
        let observed = item.projections[0]
        let rebound = SurfaceProjection(
            resource: SurfaceResourceID(machine: .remote("other-machine"), kind: .terminal, key: "term_other"),
            workspaceID: observed.workspaceID, panelID: observed.panelID
        )
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: rebound)))
    }

    @Test
    func testResourceAndPanelStayExactAcrossAWorkspaceMove() {
        let item = fixture()
        let observed = item.projections[0]
        let current = SurfaceProjection(
            resource: SurfaceResourceID(machine: .remote("test-machine"), kind: .terminal, key: "term_test"),
            workspaceID: UUID(), panelID: observed.panelID
        )
        #expect(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: current))
        var unrelatedPanel = current
        unrelatedPanel.panelID = UUID()
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: observed, current: unrelatedPanel)))
        var inconsistentProjection = observed
        inconsistentProjection.resourceRef = "test-machine/terminal/term_other"
        #expect(!(CurrentWorkPalettePresentation(item: item).matches(projection: inconsistentProjection, current: current)))
    }

    @Test
    func testUnprojectedAndStaleRemoteWorkIsHonestInTheReadOnlyRow() {
        var item = fixture()
        item.projections = []
        item.freshness.state = "stale"
        let subtitle = CurrentWorkPalettePresentation(item: item).subtitle(canFocus: false)
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only")))
        #expect(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date")))
        #expect(subtitle.contains(item.placement.machine))
    }

    @Test
    func testPlacementSubtitlePreservesEveryRemoteMachineIdentity() {
        let placements = [
            (kind: "local", machine: "local", showsMachine: false),
            (kind: "Remote", machine: "Remote-host", showsMachine: true),
            (kind: "ssh", machine: "ssh:build-host", showsMachine: true),
            (kind: "device", machine: "device:other-mac@test", showsMachine: true),
        ]
        for placement in placements {
            var item = fixture()
            item.placement = .init(kind: placement.kind, machine: placement.machine)
            let subtitle = CurrentWorkPalettePresentation(item: item).subtitle(canFocus: true)
            #expect(subtitle.contains(placement.machine) == placement.showsMachine)
        }
    }

    @Test
    func testCurrentProjectedWorkDoesNotClaimUnavailableOrStale() {
        let subtitle = CurrentWorkPalettePresentation(item: fixture()).subtitle(canFocus: true)
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notOpen", defaultValue: "No open local view · read only"))))
        #expect(!(subtitle.contains(String(localized: "commandPalette.currentWork.notCurrent", defaultValue: "May be out of date"))))
    }

    private func fixture() -> CurrentWorkSnapshot.Item {
        let resource = SurfaceResourceID(machine: .remote("test-machine"), kind: .terminal, key: "term_test").rawValue
        return .init(
            resourceRef: resource, durableSurfaceID: nil, label: "Review", kind: "terminal", lifecycle: "running",
            placement: .init(kind: "Remote", machine: "test-machine"),
            projections: [.init(resourceRef: resource, workspaceID: UUID(), panelID: UUID(), stableSurfaceID: nil,
                                stableWorkspaceID: nil, remoteWorkspaceID: "ws_test", remoteTabID: "tab_test")],
            cwd: "/project", projectHints: [], repositoryHints: [], agents: [], attention: [],
            freshness: .init(state: "current", reason: nil, observedAt: "2026-09-20T00:00:00Z"),
            possibleHumanObligations: [], evidence: [], omitted: [:]
        )
    }

}
