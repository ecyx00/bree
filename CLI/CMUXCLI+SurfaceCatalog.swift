import CmuxCore
import CmuxFoundation
import Foundation

/// `cmux surface ls|open|new-terminal`: the surface catalog for This Mac and paired
/// devices, served by the app's `surface.catalog`, `surface.project` and
/// `surface.new_terminal` handlers.
extension CMUXCLI {
    static var surfaceUsage: String {
        """
        Usage: bree surface ls [<machine>|local] [--refresh] [--json]
               bree surface open <resource> [--workspace <id|ref|index>] [--pane <id|ref>]
                                 [--left|--right|--up|--down|--tab] [--new] [--focus|--no-focus] [--json]
               bree surface new-terminal --machine <id|local> [--cwd <dir>] [--name <name>]
                                 [--remote-workspace <ws_…>] [--workspace <id|ref|index>] [--no-open]
                                 [--focus|--no-focus] [--json] [-- <command...>]
               bree surface resume …   (restart metadata; see `bree surface resume --help`)
               bree surface size [--surface <id|ref>] [--json]
               bree surface size-policy <latest|smallest|largest|priority|fixed> [--cols N --rows N] [--surface <id|ref>]
               bree surface size-to-me [--surface <id|ref>]
               bree surface size-counts <true|false|auto> [--participant <id>] [--surface <id|ref>]
               bree surface participants [--surface <id|ref>] [--json]
               bree surface disconnect-participant <participant-id> [--surface <id|ref>]
               bree surface disconnect-others [--surface <id|ref>]

        Surfaces are terminals and browsers on This Mac or on a paired device; panes
        project them. `surface ls` is the catalog, including This Mac. A resource id reads
        <machine>/<kind>/<key>, e.g. local/terminal/<uuid>.

        open:  puts the surface in a pane. Reuses a pane already showing it unless --new.
               --pane + a side splits that pane on that side; --tab adds a tab to it; else
               the workspace's focused pane. A local terminal moves to the destination
               (it can only be shown once).
        size*, participants, disconnect-*:  shared terminal sizing. A terminal viewed from
               several devices has one grid; the policy picks who sets it, and any client
               but this one can be disconnected (it can reattach from its device).
        new-terminal:  creates a terminal on the machine (a remote cmux-tui machine lands in its
               session, --remote-workspace picks which) and opens it unless --no-open.
        --focus / --no-focus:  focus the opened pane, or open it in the background.
               \(openFocusDefaultHelp)
        """
    }

    func runSurfaceCatalogCommand(subcommand: String, rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.surfaceUsage)
            return
        }
        switch subcommand {
        case "ls", "list", "tree", "catalog":
            try runSurfaceTreeCommand(rest: rest, client: client, jsonOutput: jsonOutput)

        case "open", "project":
            let (workspaceOpt, rest1) = parseOption(rest, name: "--workspace")
            let (paneOpt, rest2) = parseOption(rest1, name: "--pane")
            let (focus, rest3) = try parseOpenFocusFlags(rest2, command: "surface open")
            let sides: [String: String] = ["--left": "left", "--right": "right", "--up": "up", "--down": "down"]
            let directions = rest3.compactMap { sides[$0] }
            guard directions.count <= 1 else { throw CLIError(message: Self.surfaceUsage) }
            let direction = directions.first
            let tab = hasFlag(rest3, name: "--tab")
            if tab && direction != nil {
                throw CLIError(message: String(
                    localized: "cli.surface.open.tabAndSide",
                    defaultValue: "surface open: --tab and a pane side (--left/--right/--up/--down) are two different placements; pass one"
                ))
            }
            let new = hasFlag(rest3, name: "--new")
            let known = Set(sides.keys).union(["--tab", "--new", "--json"])
            if let unknown = rest3.first(where: { $0.hasPrefix("-") && !known.contains($0) }) {
                throw CLIError(message: "surface open: unknown flag '\(unknown)'\n\n\(Self.surfaceUsage)")
            }
            let positional = rest3.filter { !$0.hasPrefix("-") }
            guard positional.count == 1, let resource = positional.first, resource.split(separator: "/", maxSplits: 2).count == 3 else {
                throw CLIError(message: Self.surfaceUsage)
            }
            if (direction != nil || tab) && paneOpt == nil {
                throw CLIError(message: "surface open: --left/--right/--up/--down/--tab need --pane <id|ref>\n\n\(Self.surfaceUsage)")
            }
            var params: [String: Any] = ["resource": resource, "focus": focus ?? Self.defaultFocusForUserOpen()]
            if let workspaceOpt { params["workspace_id"] = workspaceOpt }
            if let paneOpt { params["pane_id"] = paneOpt }
            if let direction { params["direction"] = direction }
            if tab { params["placement"] = "tab" }
            if new { params["reuse"] = false }
            let response: [String: Any]
            do {
                response = try client.sendV2(method: "surface.project", params: params, responseTimeout: 180)
            } catch let error as CLIError where error.message.contains("Unknown surface") {
                throw CLIError(message: String(
                    format: String(localized: "cli.surface.open.unknownResource", defaultValue: "Unknown surface '%@'. See: bree surface ls --json"),
                    resource
                ))
            }
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let surfaceId = (response["surface_id"] as? String) ?? "?"
            let workspaceId = (response["workspace_id"] as? String) ?? "?"
            let reused = (response["reused"] as? Bool) == true
            print("OK surface=\(surfaceId) workspace=\(workspaceId) resource=\(resource)\(reused ? " reused=true" : "")")

        case "new-terminal", "new":
            let (machineOpt, rest1) = parseOption(rest, name: "--machine")
            let (cwdOpt, rest2) = parseOption(rest1, name: "--cwd")
            let (nameOpt, rest3) = parseOption(rest2, name: "--name")
            let (remoteWorkspaceOpt, rest4) = parseOption(rest3, name: "--remote-workspace")
            let (workspaceOpt, rest4a) = parseOption(rest4, name: "--workspace")
            let (focus, rest5) = try parseOpenFocusFlags(rest4a, command: "surface new-terminal")
            let noOpen = hasFlag(rest5, name: "--no-open")
            var command: [String] = []
            var flags = rest5
            if let separator = rest5.firstIndex(of: "--") {
                command = Array(rest5[(separator + 1)...])
                flags = Array(rest5[..<separator])
            }
            if let unknown = flags.first(where: { $0.hasPrefix("-") && !["--no-open", "--json"].contains($0) }) {
                throw CLIError(message: "surface new-terminal: unknown flag '\(unknown)'\n\n\(Self.surfaceUsage)")
            }
            guard let machine = machineOpt, !machine.isEmpty else {
                throw CLIError(message: "surface new-terminal: --machine <id|local> is required\n\n\(Self.surfaceUsage)")
            }
            var params: [String: Any] = ["machine": machine, "open": !noOpen, "focus": focus ?? Self.defaultFocusForUserOpen()]
            if !command.isEmpty { params["command"] = command }
            if let cwdOpt { params["cwd"] = cwdOpt }
            if let nameOpt { params["name"] = nameOpt }
            if let remoteWorkspaceOpt { params["remote_workspace_id"] = remoteWorkspaceOpt }
            if let workspaceOpt { params["workspace_id"] = workspaceOpt }
            let response = try client.sendV2(method: "surface.new_terminal", params: params, responseTimeout: 240)
            if jsonOutput {
                print(jsonString(response))
                return
            }
            let resource = (response["resource"] as? String) ?? "?"
            let terminalId = (response["terminal_id"] as? String) ?? "?"
            var line = "OK resource=\(resource) terminal=\(terminalId)"
            if let surfaceId = response["surface_id"] as? String, !surfaceId.isEmpty { line += " surface=\(surfaceId)" }
            if let workspaceId = response["workspace_id"] as? String, !workspaceId.isEmpty { line += " workspace=\(workspaceId)" }
            print(line)

        default:
            throw CLIError(message: "Unsupported surface subcommand: \(subcommand)\n\n\(Self.surfaceUsage)")
        }
    }

    func runSurfaceTreeCommand(rest: [String], client: SocketClient, jsonOutput: Bool) throws {
        if rest.contains("--help") || rest.contains("-h") {
            print(Self.surfaceUsage)
            return
        }
        let refresh = hasFlag(rest, name: "--refresh")
        if let unknown = rest.first(where: { $0.hasPrefix("-") && !["--refresh", "--json"].contains($0) }) {
            throw CLIError(message: "surface ls: unknown flag '\(unknown)'\n\n\(Self.surfaceUsage)")
        }
        let positional = rest.filter { !$0.hasPrefix("-") }
        guard positional.count <= 1 else {
            throw CLIError(message: Self.surfaceUsage)
        }
        var params: [String: Any] = [:]
        if let machine = positional.first { params["machine"] = machine }
        if refresh { params["refresh"] = true }
        let response = try client.sendV2(method: "surface.catalog", params: params, responseTimeout: 180)
        if jsonOutput {
            print(jsonString(response))
            return
        }
        let machines = (response["machines"] as? [[String: Any]]) ?? []
        let resources = (response["resources"] as? [[String: Any]]) ?? []
        guard !machines.isEmpty else {
            print("No machines.")
            return
        }
        // Local terminals group by the workspace that shows them; titles come from the
        // workspace list (best effort — an id stands in when the list is unavailable).
        var workspaceTitles: [String: String] = [:]
        if machines.contains(where: { ($0["local"] as? Bool) == true }),
           let list = try? client.sendV2(method: "workspace.list"),
           let workspaces = list["workspaces"] as? [[String: Any]] {
            for workspace in workspaces {
                guard let id = workspace["id"] as? String else { continue }
                let title = (workspace["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let ref = (workspace["ref"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                workspaceTitles[id.uppercased()] = [title, ref].compactMap { $0 }.joined(separator: "  ")
            }
        }
        for (index, machine) in machines.enumerated() {
            if index > 0 { print("") }
            let machineId = (machine["id"] as? String) ?? ""
            let own = resources.filter { ($0["machine"] as? String) == machineId }
            for line in CmuxTuiRemoteRouting.vmTreeLines(machine: machine, resources: own, workspaceTitles: workspaceTitles) {
                print(line)
            }
        }
    }
}
