import Darwin
import Foundation

extension BREECLI {
    /// `architecture check|render [root]` runs the bundled Python scripts (Resources/architecture). It is handled
    /// before socket discovery: no running app, socket, or sign-in is needed. The command names are stable; the Python
    /// internals may later move to Swift.
    func runArchitectureCommand(command: String, commandArgs: [String]) throws -> Bool {
        guard command == "architecture" else { return false }
        let args = commandArgs
        if args.isEmpty || args == ["--help"] || args == ["-h"] || args.first == "help" {
            print(Self.architectureUsage)
            return true
        }
        guard let action = args.first, ["check", "render"].contains(action), args.count <= 2 else {
            let format = BREEDiffViewerLocalization.string("cli.architecture.error.unknown", defaultValue: "Unknown architecture command: %@")
            throw CLIError(message: String(format: format, args.joined(separator: " ")) + "\n\n" + Self.architectureUsage, exitCode: 2)
        }
        let root = try Self.architectureRoot(explicit: args.count == 2 ? args[1] : nil)
        let python = try Self.architecturePython()
        let scripts = try Self.architectureScriptsDirectory()
        let manifest = root.appendingPathComponent(".architecture/agent/manifest.json").path
        guard FileManager.default.fileExists(atPath: manifest) else {
            let format = BREEDiffViewerLocalization.string("cli.architecture.error.manifest", defaultValue: "No diagrams found: %@ is missing. Run `bree guide architecture`.")
            throw CLIError(message: String(format: format, manifest), exitCode: 1)
        }
        let script = action == "check" ? "validate_agent.py" : "render_agent.py"
        let arguments = ["-I", scripts.appendingPathComponent(script).path, root.path] + (action == "check" ? ["--check"] : [])
        let process = Process()
        process.executableURL = python
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { Darwin.exit(process.terminationStatus) }
        return true
    }

    static var architectureUsage: String {
        let usageLabel = BREEDiffViewerLocalization.string("cli.guide.usage", defaultValue: "Usage:")
        let description = BREEDiffViewerLocalization.string(
            "cli.architecture.description",
            defaultValue: "Check or build the Architecture page from the diagrams your agent wrote in .architecture/agent/. Needs python3; check also needs a Chromium-family browser (set BREE_ARCHITECTURE_BROWSER to pick one). No running app is needed."
        )
        let check = BREEDiffViewerLocalization.string("cli.architecture.check.summary", defaultValue: "Validate the diagrams (code anchors, SVG safety, layout in a browser). Exit 1 on any FAIL.")
        let render = BREEDiffViewerLocalization.string("cli.architecture.render.summary", defaultValue: "Build .architecture/current.html from .architecture/agent/.")
        let rootHelp = BREEDiffViewerLocalization.string("cli.architecture.root.summary", defaultValue: "root defaults to the nearest folder above the current directory that holds .architecture or .git.")
        return """
        \(usageLabel) bree architecture <check|render> [root]

        \(description)

          check   \(check)
          render  \(render)

        \(rootHelp)
        See `bree guide architecture`.
        """
    }

    static func architectureRoot(explicit: String?) throws -> URL {
        let fileManager = FileManager.default
        if let explicit {
            let url = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
            return url
        }
        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true).standardizedFileURL
        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".architecture").path)
                || fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        throw CLIError(
            message: BREEDiffViewerLocalization.string("cli.architecture.error.root", defaultValue: "No project root found: run inside a folder with .architecture or .git, or pass [root]."),
            exitCode: 1
        )
    }

    /// First python3 on PATH, then the usual install folders. /usr/bin/python3 is a stub that opens an
    /// install dialog without the developer tools, so it only counts when they exist.
    static func architecturePython() throws -> URL {
        let fileManager = FileManager.default
        var directories = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin"]
        for directory in directories where !directory.isEmpty {
            let path = (directory as NSString).appendingPathComponent("python3")
            if directory == "/usr/bin" { continue }
            if fileManager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        let stubBacking = ["/Library/Developer/CommandLineTools/usr/bin/python3", "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"]
        if stubBacking.contains(where: { fileManager.isExecutableFile(atPath: $0) }), fileManager.isExecutableFile(atPath: "/usr/bin/python3") {
            return URL(fileURLWithPath: "/usr/bin/python3")
        }
        throw CLIError(
            message: BREEDiffViewerLocalization.string("cli.architecture.error.python", defaultValue: "python3 not found. Install Python 3 (for example `brew install python`) and run again."),
            exitCode: 1
        )
    }

    /// `<bundle>/Contents/Resources/architecture/`; the CLI ships at `Contents/Resources/bin/`.
    static func architectureScriptsDirectory() throws -> URL {
        var candidates: [URL] = []
        if let executable = CLIExecutableLocator.currentExecutableURL() {
            candidates.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("architecture", isDirectory: true))
        }
        if let resources = CLIExecutableLocator.enclosingAppBundle()?.resourceURL {
            candidates.append(resources.appendingPathComponent("architecture", isDirectory: true))
        }
        for url in candidates where FileManager.default.fileExists(atPath: url.appendingPathComponent("render_agent.py").path) {
            return url
        }
        let format = BREEDiffViewerLocalization.string("cli.architecture.error.scripts", defaultValue: "Architecture scripts not found next to the CLI: %@")
        throw CLIError(message: String(format: format, candidates.first?.path ?? "architecture"), exitCode: 1)
    }
}
