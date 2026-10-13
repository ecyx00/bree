import BreeFoundation
import Darwin
import Foundation

/// One finished agent turn: the start/end snapshot pair plus a change summary.
///
/// Written by the `bree` hook process on the agent's Stop event and read by the
/// app's Activity timeline. Shared by the app and CLI targets, so it only
/// depends on Foundation.
struct AgentTurnRecord: Codable, Equatable, Identifiable {
    /// Lowercased UUID; also the suffix of the pinned `refs/bree/turn-{start,end}/<id>` refs.
    var id: String
    /// Lowercased UUID strings so the CLI (which gets them from env/socket) and the app agree.
    var workspaceId: String
    var surfaceId: String
    var sessionId: String
    var turnId: String?
    var agent: String
    var repoRoot: String
    /// Commit (stash-create snapshot, HEAD or empty tree) captured when the prompt was submitted.
    var start: String
    /// Commit captured when the agent stopped.
    var end: String
    var files: Int
    var added: Int
    var removed: Int
    /// Seconds since 1970.
    var finishedAt: TimeInterval
    var reviewed: Bool

    /// "5 files +120 −30" style summary pieces live in the view; this is the raw count.
    var hasChanges: Bool { files > 0 }
}

/// Persisted list. Chronological (oldest first); the cap applies per workspace.
struct AgentTurnRecordFile: Codable, Equatable {
    static let perWorkspaceCap = 20

    var version = 1
    var records: [AgentTurnRecord] = []

    /// Appends `record`, replacing an earlier record of the same session and turn
    /// (repeated Stop callbacks), then trims the workspace to `cap`, dropping the oldest.
    /// Returns every removed record so the caller can delete their pinned refs.
    @discardableResult
    mutating func append(_ record: AgentTurnRecord, cap: Int = AgentTurnRecordFile.perWorkspaceCap) -> [AgentTurnRecord] {
        var removed: [AgentTurnRecord] = []
        if let turnId = record.turnId, !turnId.isEmpty {
            let isDuplicate: (AgentTurnRecord) -> Bool = {
                $0.workspaceId == record.workspaceId && $0.sessionId == record.sessionId && $0.turnId == turnId
            }
            removed += records.filter(isDuplicate)
            records.removeAll(where: isDuplicate)
        }
        records.append(record)
        let mine = records.indices.filter { records[$0].workspaceId == record.workspaceId }
        if mine.count > cap {
            let ordered = mine.sorted { records[$0].finishedAt < records[$1].finishedAt }
            let drop = Set(ordered.prefix(mine.count - cap))
            removed += drop.map { records[$0] }
            records = records.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
        return removed
    }

    /// Newest first.
    func records(forWorkspace workspaceId: String) -> [AgentTurnRecord] {
        records.filter { $0.workspaceId == workspaceId }.sorted { $0.finishedAt > $1.finishedAt }
    }

    /// Returns true when the record exists and was not already reviewed.
    @discardableResult
    mutating func markReviewed(id: String) -> Bool {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].reviewed else { return false }
        records[index].reviewed = true
        return true
    }
}

enum AgentTurnRecordStorage {
    static func path(env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let home = env["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
        let directory: String
        if let override = env["BREE_AGENT_HOOK_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            directory = override == "~" ? home : (override.hasPrefix("~/") ? home + "/" + override.dropFirst(2) : override)
        } else {
            directory = home + "/" + BreeIdentity.current.dotDirectoryName
        }
        return directory + "/agent-turn-records.json"
    }

    static func read(path: String) -> AgentTurnRecordFile {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let file = try? JSONDecoder().decode(AgentTurnRecordFile.self, from: data) else {
            return AgentTurnRecordFile()
        }
        return file
    }

    /// Locked read-modify-write; the hook process and the app both write this file.
    static func update(path: String, _ change: (inout AgentTurnRecordFile) -> Void) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let fd = open(path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { _ = flock(fd, LOCK_UN) }
        var file = read(path: path)
        change(&file)
        try JSONEncoder().encode(file).write(to: url, options: .atomic)
    }
}
