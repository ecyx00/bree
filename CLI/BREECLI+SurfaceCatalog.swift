import BreeCore
import BreeFoundation
import Foundation

/// `bree surface ls|open`: the surface catalog for This Mac, served by the app's `surface.catalog` and
/// `surface.project` handlers.
extension BREECLI {
    static var surfaceUsage: String {
        """
        Usage: bree surface ls [<machine>|local] [--refresh] [--json]
               bree surface open <resource> [--workspace <id|ref|index>] [--pane <id|ref>]
                                 [--left|--right|--up|--down|--tab] [--new] [--focus|--no-focus] [--json]
               bree surface resume …   (restart metadata; see `bree surface resume --help`)

        Surfaces are terminals and browsers on This Mac; panes
        project them. `surface ls` is the catalog, including This Mac. A resource id reads
        <machine>/<kind>/<key>, e.g. local/terminal/<uuid>.

        open:  puts the surface in a pane. Reuses a pane already showing it unless --new.
               --pane + a side splits that pane on that side; --tab adds a tab to it; else
               the workspace's focused pane. A local terminal moves to the destination
               (it can only be shown once).
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
        for (index, machine) in machines.enumerated() {
            if index > 0 { print("") }
            let machineId = (machine["id"] as? String) ?? ""
            let own = resources.filter { ($0["machine"] as? String) == machineId }
            print((machine["label"] as? String) ?? machineId)
            for resource in own {
                let title = (resource["title"] as? String) ?? (resource["id"] as? String) ?? ""
                print("  \(title)")
            }
        }
    }
}
