import Foundation

/// `cmux bottom-panel`, `cmux attention`, `cmux quick-view` and `cmux pins`: the CLI
/// face of the `bottom_panel.*`, `attention.*`, `quick_view.*` and `pins.*` socket
/// methods (Sources/TerminalController+BreeFeatureCommands.swift).
///
/// Argument parsing is pure (`parseBreeFeatureArguments`) and runs before the CLI
/// connects to the socket, like `right-sidebar`, so a typo fails without a running app.
extension CMUXCLI {
    static let breeFeatureCommands: Set<String> = ["bottom-panel", "attention", "quick-view", "pins"]

    static let bottomPanelUsage = String(
        localized: "cli.bottomPanel.usage",
        defaultValue: """
        Usage: bree bottom-panel <open|close|toggle|status> [flags]

        Show, hide or inspect a workspace's bottom panel (default: the selected workspace of the active window).

        Subcommands:
          open      Show the panel; creates a terminal when it is empty
          close     Hide the panel; its terminals keep running
          toggle    Show the panel when hidden, hide it when shown
          status    Print whether the panel is open and its height in points

        Flags:
          --workspace <id|ref|index>   Target workspace
          --window <id|ref|index>      Window context for workspace refs and indexes
          --focus                      Move keyboard focus into the panel (open, toggle)
          --json                       Print the socket reply as JSON

        Example:
          bree bottom-panel toggle
          bree bottom-panel status --json
        """
    )

    static let attentionUsage = String(
        localized: "cli.attention.usage",
        defaultValue: """
        Usage: bree attention <list|clear> [id]

        Read or clear the Attention Center.

        Subcommands:
          list          List the rows the Attention Center shows, most urgent first
          clear [id]    Dismiss the away-change lists, all of them or only that of
                        the row with this id (the id comes from list --json). Agent rows follow the live agent state and are not cleared.

        Flags:
          --json        Print the socket reply as JSON

        Example:
          bree attention list --json
          bree attention clear
        """
    )

    static let quickViewUsage = String(
        localized: "cli.quickView.usage",
        defaultValue: """
        Usage: bree quick-view <open <path>|close|status> [flags]

        Control the Quick View window.

        Subcommands:
          open <path>   Show a file, or a folder as a grid, in Quick View
          close         Close every Quick View window
          status        Print whether Quick View is open and what it shows

        Flags:
          --workspace <id|ref|index>   Workspace the content belongs to (open)
          --window <id|ref|index>      Window context for workspace refs and indexes
          --focus                      Give the Quick View window keyboard focus (open)
          --json                       Print the socket reply as JSON

        Example:
          bree quick-view open README.md
          bree quick-view close
        """
    )

    static let pinsUsage = String(
        localized: "cli.pins.usage",
        defaultValue: """
        Usage: bree pins <list|add <path>|remove <path>> [flags]

        Manage the pinned files of a workspace's project (the nearest git root of its current directory). Relative paths resolve against the current directory.

        Subcommands:
          list          List the pinned files
          add <path>    Pin an existing file inside the project
          remove <path> Unpin a file

        Flags:
          --workspace <id|ref|index>   Target workspace (default: the selected one)
          --window <id|ref|index>      Window context for workspace refs and indexes
          --json                       Print the socket reply as JSON

        Example:
          bree pins add docs/state/plan.md
          bree pins list
        """
    )

    enum BreeFeaturePositional: Equatable {
        case none, path, optionalID
    }

    /// One parsed `cmux <command> <subcommand> ...` call. `path` is kept as typed;
    /// `runBreeFeatureCommand` resolves it against the current directory.
    struct BreeFeatureRequest: Equatable {
        var method: String
        var workspace: String?
        var window: String?
        var path: String?
        var id: String?
        var focus: Bool
        var takesTarget: Bool
    }

    private struct BreeFeatureSpec {
        let method: String
        let takesTarget: Bool
        let takesFocus: Bool
        let positional: BreeFeaturePositional
    }

    private static func breeFeatureSpec(command: String, sub: String) -> BreeFeatureSpec? {
        switch (command, sub) {
        case ("bottom-panel", "status"):
            return BreeFeatureSpec(method: "bottom_panel.status", takesTarget: true, takesFocus: false, positional: .none)
        case ("bottom-panel", "open"):
            return BreeFeatureSpec(method: "bottom_panel.open", takesTarget: true, takesFocus: true, positional: .none)
        case ("bottom-panel", "close"):
            return BreeFeatureSpec(method: "bottom_panel.close", takesTarget: true, takesFocus: false, positional: .none)
        case ("bottom-panel", "toggle"):
            return BreeFeatureSpec(method: "bottom_panel.toggle", takesTarget: true, takesFocus: true, positional: .none)
        case ("attention", "list"), ("attention", "ls"):
            return BreeFeatureSpec(method: "attention.list", takesTarget: false, takesFocus: false, positional: .none)
        case ("attention", "clear"):
            return BreeFeatureSpec(method: "attention.clear", takesTarget: false, takesFocus: false, positional: .optionalID)
        case ("quick-view", "open"):
            return BreeFeatureSpec(method: "quick_view.open", takesTarget: true, takesFocus: true, positional: .path)
        case ("quick-view", "close"):
            return BreeFeatureSpec(method: "quick_view.close", takesTarget: false, takesFocus: false, positional: .none)
        case ("quick-view", "status"):
            return BreeFeatureSpec(method: "quick_view.status", takesTarget: false, takesFocus: false, positional: .none)
        case ("pins", "list"), ("pins", "ls"):
            return BreeFeatureSpec(method: "pins.list", takesTarget: true, takesFocus: false, positional: .none)
        case ("pins", "add"):
            return BreeFeatureSpec(method: "pins.add", takesTarget: true, takesFocus: false, positional: .path)
        case ("pins", "remove"), ("pins", "rm"):
            return BreeFeatureSpec(method: "pins.remove", takesTarget: true, takesFocus: false, positional: .path)
        default:
            return nil
        }
    }

    private static func breeFeatureSubcommandList(_ command: String) -> String {
        switch command {
        case "bottom-panel": return "open, close, toggle, status"
        case "attention": return "list, clear"
        case "quick-view": return "open, close, status"
        default: return "list, add, remove"
        }
    }

    /// Parses the arguments after `cmux <command>`. Fails closed on any unknown flag,
    /// extra positional or missing value, before anything reaches the socket.
    static func parseBreeFeatureArguments(command: String, args: [String]) throws -> BreeFeatureRequest {
        let subcommands = breeFeatureSubcommandList(command)
        guard let sub = args.first(where: { $0 != "--json" })?.lowercased() else {
            throw CLIError(message: String(
                localized: "cli.bree.error.subcommandRequired",
                defaultValue: "bree \(command) requires a subcommand: \(subcommands)"
            ))
        }
        guard let spec = breeFeatureSpec(command: command, sub: sub) else {
            throw CLIError(message: String(
                localized: "cli.bree.error.unknownSubcommand",
                defaultValue: "Unknown \(command) subcommand '\(sub)'. Try: \(subcommands)"
            ))
        }
        var rest = args
        if let index = rest.firstIndex(where: { $0 != "--json" }) { rest.remove(at: index) }

        var request = BreeFeatureRequest(
            method: spec.method, workspace: nil, window: nil, path: nil, id: nil,
            focus: false, takesTarget: spec.takesTarget
        )
        var positionals: [String] = []
        var index = 0
        func unexpected(_ arg: String) -> CLIError {
            CLIError(message: String(
                localized: "cli.bree.error.unexpectedArgument",
                defaultValue: "Unexpected argument '\(arg)' for bree \(command). Run bree \(command) --help for usage."
            ))
        }
        while index < rest.count {
            let arg = rest[index]
            index += 1
            if arg == "--json" { continue }
            if arg == "--" {
                positionals.append(contentsOf: rest[index...])
                break
            }
            guard arg.hasPrefix("--") else {
                positionals.append(arg)
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = String(parts[0])
            switch name {
            case "--workspace", "--window":
                guard spec.takesTarget else { throw unexpected(arg) }
                var value = parts.count > 1 ? String(parts[1]) : nil
                if value == nil, index < rest.count, !rest[index].hasPrefix("--") {
                    value = rest[index]
                    index += 1
                }
                guard let value, !value.isEmpty else {
                    throw CLIError(message: String(
                        localized: "cli.bree.error.flagRequiresValue",
                        defaultValue: "\(name) requires a value"
                    ))
                }
                if name == "--workspace" { request.workspace = value } else { request.window = value }
            case "--focus":
                guard spec.takesFocus, parts.count == 1 else { throw unexpected(arg) }
                request.focus = true
            default:
                throw unexpected(arg)
            }
        }

        switch spec.positional {
        case .none:
            if let extra = positionals.first { throw unexpected(extra) }
        case .path:
            guard let path = positionals.first, !path.isEmpty else {
                throw CLIError(message: String(
                    localized: "cli.bree.error.pathRequired",
                    defaultValue: "bree \(command) \(sub) requires a path"
                ))
            }
            if positionals.count > 1 { throw unexpected(positionals[1]) }
            request.path = path
        case .optionalID:
            if positionals.count > 1 { throw unexpected(positionals[1]) }
            request.id = positionals.first
        }
        return request
    }

    /// `path` as an absolute, standardized path: `~` expands, relative paths resolve
    /// against `directory`.
    static func breeFeatureAbsolutePath(_ path: String, relativeTo directory: String) -> String {
        let expanded = NSString(string: path).expandingTildeInPath
        let absolute = expanded.hasPrefix("/") ? expanded : NSString(string: directory).appendingPathComponent(expanded)
        return NSString(string: absolute).standardizingPath
    }

    func runBreeFeatureCommand(
        command: String,
        commandArgs: [String],
        client: SocketClient,
        jsonOutput: Bool,
        idFormat: CLIIDFormat,
        windowOverride: String?
    ) throws {
        let request = try Self.parseBreeFeatureArguments(command: command, args: commandArgs)
        var params: [String: Any] = [:]
        if request.takesTarget {
            let windowId = try normalizeWindowHandle(request.window ?? windowOverride, client: client)
            if let windowId { params["window_id"] = windowId }
            if let workspaceId = try normalizeWorkspaceHandle(
                request.workspace,
                client: client,
                windowHandle: windowId,
                allowCurrent: false
            ) {
                params["workspace_id"] = workspaceId
            }
        }
        if let path = request.path {
            params["path"] = Self.breeFeatureAbsolutePath(path, relativeTo: FileManager.default.currentDirectoryPath)
        }
        if let id = request.id { params["id"] = id }
        if request.focus { params["focus"] = true }

        let payload = try client.sendV2(method: request.method, params: params)
        if jsonOutput {
            print(jsonString(formatIDs(payload, mode: idFormat)))
            return
        }
        printBreeFeaturePayload(method: request.method, payload: payload)
    }

    /// Plain-text rendering: data for reads (one value or one row per line), `OK` for changes.
    private func printBreeFeaturePayload(method: String, payload: [String: Any]) {
        switch method {
        case "bottom_panel.status":
            let state = (payload["open"] as? Bool) == true ? "open" : "closed"
            if let height = payload["height"] as? Double {
                print("\(state) \(Int(height.rounded()))")
            } else {
                print(state)
            }
        case "attention.list":
            for item in payload["items"] as? [[String: Any]] ?? [] {
                let state = item["state"] as? String ?? "changes"
                let title = item["workspace_title"] as? String ?? ""
                let agent = item["agent"] as? String ?? ""
                print([state, agent, title].filter { !$0.isEmpty }.joined(separator: "\t"))
            }
        case "quick_view.status":
            let windows = payload["windows"] as? [[String: Any]] ?? []
            if windows.isEmpty {
                print("closed")
            } else {
                for window in windows { print("open\t\(window["path"] as? String ?? "")") }
            }
        case "pins.list":
            for pin in payload["pins"] as? [[String: Any]] ?? [] {
                print(pin["path"] as? String ?? "")
            }
        default:
            print("OK")
        }
    }
}
