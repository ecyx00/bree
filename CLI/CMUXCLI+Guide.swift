import Foundation

extension CMUXCLI {
    /// Guides are handled before socket discovery, authentication, and window focus.
    /// Only these command positions belong to cmux; an agent or exec payload can
    /// contain `--skill` without being intercepted.
    func runGuideCommand(command: String, commandArgs: [String], jsonOutput: Bool) throws -> Bool {
        guard command == "guide" || command == "--skill" else { return false }
        let remaining = commandArgs

        let invocation = "bree guide | bree --skill"
        let usageLabel = CMUXDiffViewerLocalization.string("cli.guide.usage", defaultValue: "Usage:")
        let usage = "\(usageLabel) \(invocation) [--json]\n"
            + "       bree guide <\(Self.guideTopics.map(\.name).joined(separator: "|"))> [--json]\n\n"
            + Self.guideDescription + "\n\n" + Self.guideListText
        if remaining == ["--help"] || remaining == ["-h"] {
            print(usage)
            return true
        }
        if command == "guide", remaining.count == 1, let topic = remaining.first {
            guard Self.guideTopics.contains(where: { $0.name == topic }) else {
                let format = CMUXDiffViewerLocalization.string("cli.guide.unknown", defaultValue: "Unknown guide: %@")
                throw CLIError(message: String(format: format, topic) + "\n\n" + Self.guideListText, exitCode: 1)
            }
            let content = topic == "overview" ? Self.overviewGuide : try Self.guideFileText(named: topic)
            if jsonOutput {
                print(jsonString(["topic": topic, "format": "markdown", "content": content]))
            } else {
                print(content)
            }
            return true
        }
        guard remaining.isEmpty else {
            throw CLIError(message: usage, exitCode: 2)
        }

        let content = Self.overviewGuide + "\n\n" + Self.guideListText
        if jsonOutput {
            print(jsonString(["topic": "cmux", "format": "markdown", "content": content]))
        } else {
            print(content)
        }
        return true
    }

    /// Guide topics in listing order. `overview` is the built-in text; the others are markdown files
    /// in the app's `Resources/guides/` folder, found relative to the CLI executable (no app or socket needed).
    static var guideTopics: [(name: String, summary: String)] {
        [
            ("overview", CMUXDiffViewerLocalization.string("cli.guide.topic.overview", defaultValue: "Methods for terminals, browsers, notifications and settings")),
            ("wiki", CMUXDiffViewerLocalization.string("cli.guide.topic.wiki", defaultValue: "How to write the project wiki that Bree shows (index.json, pages, links)")),
            ("architecture", CMUXDiffViewerLocalization.string("cli.guide.topic.architecture", defaultValue: "How to draw the architecture diagrams that Bree shows (manifest, SVG contract, check, render)")),
        ]
    }

    static var guideListText: String {
        let heading = CMUXDiffViewerLocalization.string("cli.guide.list.heading", defaultValue: "Guides:")
        let width = guideTopics.map { $0.name.count }.max() ?? 0
        let rows = guideTopics.map { "  bree guide \($0.name.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.summary)" }
        return ([heading] + rows).joined(separator: "\n")
    }

    /// `<bundle>/Contents/Resources/guides/<name>.md`; the CLI ships at `Contents/Resources/bin/`.
    static func guideFileText(named name: String) throws -> String {
        var directories: [URL] = []
        if let executable = CLIExecutableLocator.currentExecutableURL() {
            directories.append(executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("guides", isDirectory: true))
        }
        if let resources = CLIExecutableLocator.enclosingAppBundle()?.resourceURL {
            directories.append(resources.appendingPathComponent("guides", isDirectory: true))
        }
        for directory in directories {
            let url = directory.appendingPathComponent("\(name).md")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.hasSuffix("\n") ? String(text.dropLast()) : text
            }
        }
        let format = CMUXDiffViewerLocalization.string("cli.guide.missing", defaultValue: "Guide files not found next to the CLI: %@")
        throw CLIError(message: String(format: format, directories.first?.path ?? name), exitCode: 1)
    }

    static var guideDescription: String {
        CMUXDiffViewerLocalization.string(
            "cli.guide.description",
            defaultValue: "Read a short guide and find specific methods. No running app, network access, or sign-in is needed to read it."
        )
    }

    static var overviewGuide: String {
        """
        # bree guide

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.intro", defaultValue: "Bree puts terminals, browsers, and agents in one workspace. Use this guide to choose a method, then read its help before acting. `bree --skill` prints this same guide."))

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.targets", defaultValue: "## Find your target\n\nA window contains workspaces. A workspace contains split panes. Each pane contains surfaces, such as a terminal or browser tab. Inspect the caller and use the returned IDs. Keep the caller's workspace and surface context; use explicit targets and `--focus false` where supported."))

        ```sh
        bree identify --json
        bree tree --all --json
        bree capabilities --json
        ```

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.terminals", defaultValue: "## Work with terminals\n\nCreate a workspace for a task, add panes for parallel work, and read terminal output before sending input. `send` enters text; `send-key` sends keys. Read the screen again to check the result."))

        `bree new-workspace --help` · `bree new-pane --help`
        `bree read-screen --help` · `bree send --help` · `bree send-key --help`

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.browser", defaultValue: "## Use a browser\n\nUse `bree browser` for a browser surface inside Bree. Use `agent-browser` for a separate browser session. Prefer an existing headful Chrome session when it exposes DevTools through remote debugging: `agent-browser --auto-connect snapshot`, or `agent-browser --cdp 9222 snapshot` for an explicit port. A normal Chrome window without remote debugging cannot be attached; `agent-browser --headed` starts a new visible browser. Read a snapshot, act on an observed element, then take a fresh snapshot. Check appearance with a screenshot. Keep each tool's target IDs within that tool."))

        ```sh
        bree browser open https://example.com --focus false
        bree browser --surface <surface> snapshot --interactive
        bree browser --help
        agent-browser --auto-connect snapshot
        agent-browser --cdp 9222 snapshot
        agent-browser --headed open https://example.com
        agent-browser --help
        ```

        [Bree browser](https://cmux.com/docs/browser-automation) · [agent-browser docs](https://agent-browser.dev/) · [agent-browser commands](https://agent-browser.dev/commands)

        \(CMUXDiffViewerLocalization.string("cli.guide.overview.share", defaultValue: "## Show work and find more methods\n\nUse Markdown and diff views to show results. Use notifications and progress to report task state. Settings and integration docs list their own methods."))

        `bree markdown --help` · `bree diff --help` · `bree notify --help` · `bree set-progress --help`
        `bree docs settings` · `bree docs agents` · `bree docs api`
        """
    }
}
