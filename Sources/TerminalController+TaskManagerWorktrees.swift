import Darwin
import Foundation
import BreeTerminal

/// Cached `git rev-parse` results so the on-demand Task Manager / `bree top`
/// sampling does not spawn git for every workspace on every refresh.
private final class WorktreeIdentityCache: @unchecked Sendable {
    typealias Identity = (root: String, repo: String, linked: Bool)
    static let shared = WorktreeIdentityCache()

    private let lock = NSLock()
    private var entries: [String: (at: Date, identity: Identity?)] = [:]
    private let ttl: TimeInterval = 60

    func identity(for directory: String) -> Identity? {
        let now = Date()
        lock.lock()
        let cached = entries[directory]
        lock.unlock()
        if let cached, now.timeIntervalSince(cached.at) < ttl { return cached.identity }
        let identity = GitStatusProvider().worktreeIdentity(for: directory)
        lock.lock()
        entries[directory] = (now, identity)
        if entries.count > 256 { entries = entries.filter { now.timeIntervalSince($0.value.at) < ttl } }
        lock.unlock()
        return identity
    }
}

extension TerminalController {
    /// Long-lived helpers the user (or Bree) starts on purpose; never reported as leaked.
    private nonisolated static func isIntentionalDaemon(_ process: BreeTopProcessInfo) -> Bool {
        let name = process.name.lowercased()
        if name == "tmux" || name.hasPrefix("tmux:") || name == "screen" || name.hasPrefix("bree") { return true }
        if let path = process.path, path.hasPrefix(Bundle.main.bundlePath + "/") { return true }
        return false
    }

    /// Adds `workspace.worktree` ({root, repo, linked}) to every workspace node and
    /// returns processes that outlived their surface (orphaned, hint only, never killed).
    nonisolated func v2AnnotateTopWorktrees(
        _ windows: inout [[String: Any]],
        processSnapshot: BreeTopProcessSnapshot,
        totalPIDs: Set<Int>,
        includeProcesses: Bool
    ) -> [[String: Any]] {
        var liveSurfaceIDs = Set<String>()
        for windowIndex in windows.indices {
            var workspaces = windows[windowIndex]["workspaces"] as? [[String: Any]] ?? []
            for index in workspaces.indices {
                for pane in workspaces[index]["panes"] as? [[String: Any]] ?? [] {
                    for surface in pane["surfaces"] as? [[String: Any]] ?? [] {
                        if let id = surface["id"] as? String { liveSurfaceIDs.insert(id.uppercased()) }
                    }
                }
                guard let cwd = workspaces[index]["cwd"] as? String, !cwd.isEmpty,
                      let identity = WorktreeIdentityCache.shared.identity(for: cwd) else { continue }
                workspaces[index]["worktree"] = [
                    "root": identity.root, "repo": identity.repo, "linked": identity.linked,
                ] as [String: Any]
            }
            windows[windowIndex]["workspaces"] = workspaces
        }
        // Leak detection needs process details (surface attribution), so it only runs
        // while the Processes toggle / `bree top --processes` is on.
        guard includeProcesses else { return [] }

        let selfPID = Int(getpid())
        var leaked: [[String: Any]] = []
        for (pid, process) in processSnapshot.processesByPID.sorted(by: { $0.key < $1.key }) {
            guard pid > 1, pid != selfPID, process.parentPID == 1, !totalPIDs.contains(pid),
                  !Self.isIntentionalDaemon(process) else { continue }
            // Env first; SIP-protected binaries hide their env, so fall back to the closed shell's session id.
            let owner = process.breeSurfaceID ?? TerminalClosedSessionLedger.closedSurfaceID(forProcess: pid)
            let surfaceGone = owner.map { !liveSurfaceIDs.contains($0.uuidString.uppercased()) } ?? false
            let cwd = TerminalWorkingDirectoryResolver.processCurrentWorkingDirectory(pid: pid_t(pid))
            // Leaked only when the env names a Bree surface that no longer exists.
            guard surfaceGone else { continue }
            let root = cwd.flatMap { WorktreeIdentityCache.shared.identity(for: $0)?.root }
            leaked.append([
                "pid": pid,
                "ppid": process.parentPID,
                "name": process.name,
                "cwd": cwd ?? NSNull(),
                "worktree": root ?? NSNull(),
                "reason": "surface_gone",
                "resources": processSnapshot.summaryPayload(for: [pid]),
            ] as [String: Any])
        }
        return leaked
    }
}
