import BreeTerminal
import Foundation

extension WorkspaceTerminalFontSizePanelDiscovery {
    struct Candidate {
        let panelId: UUID
        let origin: Origin

        @MainActor
        func mountedTerminalPanel(
            in workspace: Workspace?
        ) -> TerminalPanel? {
            switch origin {
            case .workspace:
                return workspace?.panels[panelId] as? TerminalPanel
            case .workspaceDock:
                return workspace?._dockSplit?.panels[panelId]
                    as? TerminalPanel
            case .remoteMirror(let mirrorId, let paneId):
                guard let panel = workspace?
                    .remoteTmuxWindowMirror(forPanelId: mirrorId)?
                    .panelsByPaneId[paneId],
                      panel.id == panelId else {
                    return nil
                }
                return panel
            }
        }
    }
}
