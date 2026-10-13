import Foundation
import Testing
import BreeControlSocket

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite("Workspace group move-to menu state")
@MainActor
struct WorkspaceGroupMoveToMenuStateTests {
    @Test func isDisabledWhenThereAreNoGroups() {
        let state = WorkspaceGroupMoveToMenuState(groups: [])

        #expect(state.isDisabled)
        #expect(!state.rendersSubmenu)
    }

    @Test func usesSubmenuWhenGroupsExist() {
        let group = WorkspaceGroupMenuSnapshot.Item(
            id: UUID(),
            name: "Group"
        )
        let state = WorkspaceGroupMoveToMenuState(groups: [group])

        #expect(!state.isDisabled)
        #expect(state.rendersSubmenu)
    }

    @Test func controlWorkspaceGroupCreateWithStableIdentityReturnsExistingGroup() throws {
        let manager = TabManager()
        manager.addWorkspace(autoWelcomeIfNeeded: false)
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }

        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        let params: [String: JSONValue] = [
            "name": .string("Ops"),
            "idempotency_key": .string("repo:control"),
        ]
        let first = coordinator.handle(ControlRequest(
            id: .int(1),
            method: "workspace.group.create",
            params: params
        ))
        let second = coordinator.handle(ControlRequest(
            id: .int(2),
            method: "workspace.group.create",
            params: params
        ))

        guard case .ok = first,
              case .ok(.object(let secondPayload)) = second else {
            return #expect(Bool(false), "control group creates should succeed")
        }
        #expect(manager.workspaceGroups.count == 1)
        #expect(secondPayload["created"] == .bool(false))
    }
}
