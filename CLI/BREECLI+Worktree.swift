import Foundation

/// `bree worktree create|open|remove`: git worktrees of the caller's repo, each
/// opened as a workspace. Built from existing socket methods (`workspace.create`,
/// `.list`, `.select`, `.close`); the Task Manager and `bree top` derive the
/// worktree root and repo from the workspace cwd, so no extra provenance is stored.
extension BREECLI {
    func worktreeCommandUsage() -> String {
        """
        Usage: bree worktree create <branch> [--from <ref>] [--path <dir>]
               bree worktree open <path|branch>
               bree worktree remove <path|branch> [--force]

        Manage git worktrees of the repository you run the command in, as workspaces.

          create   Add a worktree for <branch> (created from --from, default HEAD, when
                   the branch does not exist yet) and open a workspace on it. The default
                   path is a sibling folder named <repo>-<branch>.
          open     Focus the workspace on an existing worktree, or open one.
          remove   Close the worktree's workspaces and run `git worktree remove`.
                   Refuses a worktree with uncommitted changes unless --force is given.
                   The branch is never deleted.
        """
    }

    func runWorktreeCommand(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        guard let sub = commandArgs.first, ["create", "open", "remove"].contains(sub) else {
            print(worktreeCommandUsage())
            return
        }
        let (fromOpt, rem0) = parseOption(Array(commandArgs.dropFirst()), name: "--from")
        let (pathOpt, rem1) = parseOption(rem0, name: "--path")
        let force = rem1.contains("--force")
        let positional = rem1.filter { !$0.hasPrefix("--") }
        guard positional.count == 1 else {
            throw CLIError(message: "worktree \(sub): expected exactly one \(sub == "create" ? "<branch>" : "<path|branch>")\n\n" + worktreeCommandUsage())
        }
        let target = positional[0]
        let cwd = FileManager.default.currentDirectoryPath
        guard let repoRoot = try? gitStdout(["rev-parse", "--show-toplevel"], in: cwd).trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            throw CLIError(message: "worktree \(sub): not inside a git repository")
        }

        let client = try connectClient(socketPath: socketPath, explicitPassword: explicitPassword, launchIfNeeded: false)
        defer { client.close() }

        var path: String
        var branch: String?
        switch sub {
        case "create":
            branch = target
            path = resolvePath(pathOpt ?? Self.defaultWorktreePath(repoRoot: repoRoot, branch: target))
            try Self.refuseForeignWorktreePath(path)
            if FileManager.default.fileExists(atPath: path) {
                throw CLIError(message: "worktree create: \(path) already exists")
            }
            let exists = (try? gitStdout(["rev-parse", "--verify", "--quiet", "refs/heads/\(target)"], in: repoRoot)) != nil
            var args = ["worktree", "add"]
            if exists {
                if fromOpt != nil { throw CLIError(message: "worktree create: branch \(target) already exists; drop --from") }
                args += [path, target]
            } else {
                args += ["-b", target, path] + (fromOpt.map { [$0] } ?? [])
            }
            _ = try gitStdout(args, in: repoRoot)
        default:
            let entries = worktreeEntries(repoRoot: repoRoot)
            let resolved = NSString(string: target).expandingTildeInPath
            let match = entries.first(where: { $0.branch == target })
                ?? entries.first(where: { Self.samePath($0.path, resolvePath(resolved)) })
            guard let match else { throw CLIError(message: "worktree \(sub): no worktree for \(target)") }
            path = match.path
            branch = match.branch
            if sub == "remove" {
                if Self.samePath(path, repoRoot) || Self.samePath(path, entries.first?.path ?? "") {
                    throw CLIError(message: "worktree remove: refusing to remove the main worktree")
                }
                let dirty = try gitStdout(["status", "--porcelain"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
                if !dirty.isEmpty && !force {
                    throw CLIError(message: "worktree remove: \(path) has uncommitted changes; use --force to remove it anyway")
                }
            }
        }

        let workspaces = try worktreeWorkspaces(client: client, path: path)
        var result: [String: Any] = ["path": path, "branch": branch ?? NSNull(), "repo": repoRoot]
        switch sub {
        case "create":
            result["workspace_id"] = try createWorktreeWorkspace(client: client, path: path)
        case "open":
            if let first = workspaces.first {
                _ = try client.sendV2(method: "workspace.select", params: ["workspace_id": first])
                result["workspace_id"] = first
            } else {
                result["workspace_id"] = try createWorktreeWorkspace(client: client, path: path)
            }
        default:
            for id in workspaces {
                _ = try client.sendV2(method: "workspace.close", params: ["workspace_id": id, "force": force])
            }
            _ = try gitStdout(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repoRoot)
            result["closed_workspaces"] = workspaces
        }
        if jsonOutput {
            print(jsonString(result))
        } else {
            print("OK \(path)")
        }
    }

    private func createWorktreeWorkspace(client: SocketClient, path: String) throws -> String {
        let response = try client.sendV2(method: "workspace.create", params: ["cwd": path, "focus": true])
        return (response["workspace_id"] as? String) ?? ""
    }

    /// Workspace ids whose current directory is the worktree or inside it.
    private func worktreeWorkspaces(client: SocketClient, path: String) throws -> [String] {
        // current_directory is shell-reported and lags a brand-new workspace, so a create
        // followed at once by open/remove can miss it; poll briefly before concluding none.
        // ponytail: ~1.5 s wait when no workspace exists; a creation-time cwd field on
        // workspace.list would remove the wait.
        var found = try matchWorktreeWorkspaces(client: client, path: path)
        for _ in 0..<6 where found.isEmpty {
            Thread.sleep(forTimeInterval: 0.25)
            found = try matchWorktreeWorkspaces(client: client, path: path)
        }
        return found
    }

    private func matchWorktreeWorkspaces(client: SocketClient, path: String) throws -> [String] {
        let windows = try client.sendV2(method: "window.list")["windows"] as? [[String: Any]] ?? []
        let items = try windows.compactMap { $0["id"] as? String }.flatMap { windowID -> [[String: Any]] in
            let listed = try client.sendV2(method: "workspace.list", params: ["window_id": windowID])
            return listed["workspaces"] as? [[String: Any]] ?? []
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let dir = item["current_directory"] as? String else { return nil }
            let real = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
            let root = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            return real == root || real.hasPrefix(root + "/") ? id : nil
        }
    }

    private func worktreeEntries(repoRoot: String) -> [(path: String, branch: String?)] {
        guard let out = try? gitStdout(["worktree", "list", "--porcelain"], in: repoRoot) else { return [] }
        var entries: [(path: String, branch: String?)] = []
        for line in out.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("worktree ") {
                entries.append((String(line.dropFirst("worktree ".count)), nil))
            } else if line.hasPrefix("branch refs/heads/"), !entries.isEmpty {
                entries[entries.count - 1].branch = String(line.dropFirst("branch refs/heads/".count))
            }
        }
        return entries
    }

    private static func samePath(_ a: String, _ b: String) -> Bool {
        URL(fileURLWithPath: a).resolvingSymlinksInPath().path == URL(fileURLWithPath: b).resolvingSymlinksInPath().path
    }

    private static func defaultWorktreePath(repoRoot: String, branch: String) -> String {
        let url = URL(fileURLWithPath: repoRoot)
        let safe = branch.replacingOccurrences(of: "/", with: "-")
        return url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(safe)").path
    }

    /// Worktrees never go inside Bree's own roots or another app's folder.
    private static func refuseForeignWorktreePath(_ path: String) throws {
        let home = NSHomeDirectory()
        let resolved = URL(fileURLWithPath: path).standardizedFileURL.path
        let blocked = [".bree", ".bree-dev", ".config", "Library"].map { "\(home)/\($0)" }
        if blocked.contains(where: { resolved == $0 || resolved.hasPrefix($0 + "/") }) {
            throw CLIError(message: "worktree create: refusing to create a worktree inside \(resolved)")
        }
    }
}
