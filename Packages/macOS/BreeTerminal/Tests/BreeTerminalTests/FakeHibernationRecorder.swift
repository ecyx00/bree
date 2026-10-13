import Foundation
@testable import BreeTerminal

final class FakeHibernationRecorder: AgentHibernationRecording {
    @MainActor
    func recordTerminalInput(workspaceId: UUID, panelId: UUID) {}
}
