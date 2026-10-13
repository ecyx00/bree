import AppKit
import BreeSettings
import Foundation

/// Review station actions for one finished agent turn: open its start->end diff
/// in the existing diff viewer, and hand pooled review comments back to the agent.
@MainActor
enum AgentTurnReview {
    /// Spawns `bree diff --range <start>..<end>` (the same CLI path as the Open Diff
    /// Viewer shortcut) and marks the record reviewed. Git runs in that child process.
    @discardableResult
    static func openDiff(_ record: AgentTurnRecord, workspaceId: UUID, store: WorkspaceActivityStore) -> Bool {
        guard let cliURL = Bundle.main.resourceURL?.appendingPathComponent("bin/bree"),
              FileManager.default.isExecutableFile(atPath: cliURL.path) else {
            NSSound.beep()
            return false
        }
        let socketPath = TerminalController.shared.activeSocketPath(
            preferredPath: SocketControlSettings.socketPath()
        )
        let process = Process()
        process.executableURL = cliURL
        var arguments = [
            "--socket", socketPath,
            "diff",
            "--range", "\(record.start)..\(record.end)",
            "--cwd", record.repoRoot,
            "--workspace", workspaceId.uuidString,
            "--focus", "true",
        ]
        if let surfaceId = UUID(uuidString: record.surfaceId) {
            arguments.append(contentsOf: ["--surface", surfaceId.uuidString])
        }
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["BREE_SOCKET_PATH"] = socketPath
        environment["BREE_BUNDLED_CLI_PATH"] = cliURL.path
        environment["BREE_WORKSPACE_ID"] = workspaceId.uuidString
        environment.removeValue(forKey: "BREE_SOCKET")
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            // Also releases the handler's self-reference to the Process.
            let failed = finished.terminationStatus != 0
            finished.terminationHandler = nil
            if failed { Task { @MainActor in NSSound.beep() } }
        }
        do {
            try process.run()
        } catch {
            NSSound.beep()
            return false
        }
        store.markReviewed(record)
        return true
    }

    /// Delivers the workspace's pooled diff comments to `surfaceId` as a bracketed paste
    /// (no Enter) through the same surface input path the socket uses, then focuses that pane.
    @discardableResult
    static func sendPendingComments(workspaceId: UUID, surfaceId: UUID, tabManager: TabManager) -> Bool {
        guard let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let target = workspace.controlSocketTerminalInputTarget(for: surfaceId) else {
            NSSound.beep()
            return false
        }
        let pool = DiffCommentSubmissionPool.shared
        let entries = pool.consumeAll(workspaceId: workspaceId)
        guard !entries.isEmpty else { return false }
        let text = entries.map(\.submissionText).joined(separator: "\n")
        guard target.sendTextResult(text).accepted else {
            pool.restorePending(entries, workspaceId: workspaceId)
            NSSound.beep()
            return false
        }
        for (repoRoot, group) in Dictionary(grouping: entries, by: \.repoRoot) {
            DiffCommentStore.shared.markConsumed(ids: group.map(\.commentId), repoRoot: repoRoot)
        }
        tabManager.focusSurface(tabId: workspaceId, surfaceId: surfaceId)
        return true
    }
}
