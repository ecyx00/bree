import BreeControlSocket
import Foundation

extension TerminalController {
    @MainActor
    @discardableResult
    func presentAgentRestoreRecovery(
        workspaceID: UUID,
        surfaceID: UUID,
        state: AgentRestoreRecoveryPresentation.State?
    ) -> Bool {
        let routing = ControlRoutingSelectors(
            hasWindowIDParam: false, windowID: nil, groupID: nil,
            workspaceID: workspaceID, surfaceID: surfaceID, paneID: nil
        )
        guard let manager = resolveTabManager(routing: routing) else { return false }
        let workspace = resolveSurfaceWorkspace(routing: routing, tabManager: manager)
        let panel = workspace?.terminalInputTarget(forPanelID: surfaceID)?.panel
        guard let panel, panel.restoreRecovery.state != state else { return false }
        panel.restoreRecovery.state = state
        return true
    }
}
