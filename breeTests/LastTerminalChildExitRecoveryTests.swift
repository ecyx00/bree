import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite
struct LastTerminalChildExitRecoveryTests {
    @Test
    func cancellingLastWindowCloseRespawnsAHistoryFreeTerminal() throws {
        let manager = TabManager()
        let workspace = try #require(manager.selectedWorkspace)
        let panelId = try #require(workspace.focusedPanelId)
        let oldPanel = try #require(workspace.terminalPanel(for: panelId))
        let oldSurface = oldPanel.surface
        let replayFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-cancelled-close-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: replayFile) }
        try Data("old scrollback".utf8).write(to: replayFile)
        oldPanel.ownedSessionScrollbackReplayFileURL = replayFile

        let recovery = try #require(manager.lastTerminalChildExitRecoveryAction(
            tabId: workspace.id,
            surfaceId: panelId,
            runtimeSurface: oldSurface
        ))
        recovery()

        let replacement = try #require(workspace.terminalPanel(for: panelId))
        #expect(replacement.surface !== oldSurface)
        #expect(replacement.surface.initialCommand == nil)
        #expect(replacement.ownedSessionScrollbackReplayFileURL == nil)
        #expect(!FileManager.default.fileExists(atPath: replayFile.path))
        #expect(workspace.panels.count == 1)
        #expect(manager.tabs.count == 1)
    }
}
