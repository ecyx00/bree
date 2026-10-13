import BreeTerminal
import BreeTerminalCore
import Foundation

extension WorkspaceTerminalFontSizeCoordinator {
    /// Shared result for the workspace phases of one coalesced event batch.
    final class EventBatchLineage {
        let configuration:
            WorkspaceTerminalFontConfigurationSnapshot
        var remainingRequestTokens: Set<UUID> = []
        let deferredProjectionToken: UUID?
        let workspaceTransferToken = UUID()

        init(
            configuration:
                WorkspaceTerminalFontConfigurationSnapshot,
            deferredProjectionToken: UUID? = nil
        ) {
            self.configuration = configuration
            self.deferredProjectionToken =
                deferredProjectionToken
        }
    }
}
