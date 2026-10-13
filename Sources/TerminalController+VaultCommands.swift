import Foundation
import BreeAgentSessionStore

/// Socket v2 surface for the Vault session index, so terminal agents can
/// browse and search sessions exactly like the UI
/// (`skills/bree-shared-behavior`: same engines, no duplicated logic).
/// All commands run on the socket worker, and nothing here activates the app
/// or steals macOS focus.
extension TerminalController {
    nonisolated static let vaultSessionsDefaultLimit = 30
    nonisolated static let vaultSessionsMaxLimit = 200

    // MARK: vault.sessions

    nonisolated func v2VaultSessions(params: [String: Any]) async -> V2CallResult {
        let agentFilter = Self.trimmedParam(params["agent"])
        let folderFilter = Self.trimmedParam(params["folder"])
        let requestedLimit = v2Int(params, "limit") ?? Self.vaultSessionsDefaultLimit
        let limit = max(1, min(requestedLimit, Self.vaultSessionsMaxLimit))

        let ampSessionRepository = AmpHookSessionRepository()
        var entries = await SessionIndexStore.loadInitialEntries(
            ampSessionRepository: ampSessionRepository
        )
        if let agentFilter {
            entries = entries.filter { $0.agent.rawValue == agentFilter }
        }
        if let folderFilter {
            entries = entries.filter { ($0.cwd ?? "") == folderFilter }
        }
        let liveKeys = await Self.vaultLiveSessionKeys()
        let now = Date()
        return .ok([
            "sessions": entries.prefix(limit).map {
                Self.vaultSessionPayload($0, liveKeys: liveKeys, now: now)
            },
        ])
    }

    // MARK: vault.search

    nonisolated func v2VaultSearch(params: [String: Any]) async -> V2CallResult {
        guard let query = Self.trimmedParam(params["query"]) else {
            return .err(
                code: "invalid_params",
                message: String(localized: "socket.vault.missingQuery",
                                defaultValue: "query is required."),
                data: nil
            )
        }
        let requestedLimit = v2Int(params, "limit") ?? Self.vaultSessionsDefaultLimit
        let limit = max(1, min(requestedLimit, Self.vaultSessionsMaxLimit))
        let ampSessionRepository = AmpHookSessionRepository()
        let entries = await SessionIndexStore.loadInitialEntries(
            ampSessionRepository: ampSessionRepository
        )
        let outcome = await SessionIndexStore.searchAllSessions(
            rawQuery: query,
            entries: entries,
            scopedDirectory: nil,
            ampSessionRepository: ampSessionRepository
        )
        let liveKeys = await Self.vaultLiveSessionKeys()
        let now = Date()
        return .ok([
            "query": query,
            "errors": outcome.errors,
            "sessions": outcome.entries.prefix(limit).map {
                Self.vaultSessionPayload($0, liveKeys: liveKeys, now: now)
            },
        ])
    }

    nonisolated static func vaultLiveSessionKeys() async -> Set<String> {
        let index = await MainActor.run {
            SharedLiveAgentIndex.shared.currentIndexSchedulingRefresh()
        }
        return VaultLiveSessionKeys.runningKeys(in: index)
    }

    nonisolated static func vaultSessionPayload(
        _ entry: SessionEntry,
        liveKeys: Set<String>,
        now: Date
    ) -> [String: Any] {
        let status = VaultSessionLiveStatus.derive(
            isProcessRunning: liveKeys.contains(VaultLiveSessionKeys.key(for: entry)),
            lastActivity: entry.modified,
            now: now
        )
        var payload: [String: Any] = [
            "agent": entry.agent.rawValue,
            "session_id": entry.sessionId,
            "title": entry.displayTitle,
            "modified": entry.modified.formatted(.iso8601),
            "status": String(describing: status),
        ]
        if let cwd = entry.cwd, !cwd.isEmpty { payload["cwd"] = cwd }
        if let branch = entry.gitBranch, !branch.isEmpty { payload["git_branch"] = branch }
        if let created = entry.created { payload["created"] = created.formatted(.iso8601) }
        if let count = entry.messageCount { payload["message_count"] = count }
        if let file = entry.fileURL?.path { payload["file"] = file }
        if let resume = entry.copyResumeCommand { payload["resume_command"] = resume }
        return payload
    }

    private nonisolated static func trimmedParam(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }
        return string
    }
}
