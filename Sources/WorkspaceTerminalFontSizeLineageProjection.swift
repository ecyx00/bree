import BreeTerminal
import BreeTerminalCore
import Foundation

extension WorkspaceTerminalFontSizeSnapshotProjection {
    struct LineageProjection {
        let lineage: TerminalFontSizeLineage?
        let representedRequestTokens: Set<UUID>
    }
}
