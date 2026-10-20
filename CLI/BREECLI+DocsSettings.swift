import BreeFoundation
import Foundation

extension BREECLI {
    static let settingsDocsURL = "https://github.com/ecyx00/bree/blob/main/docs/configuration.md"
    static let settingsSchemaURL = "https://raw.githubusercontent.com/ecyx00/bree/main/web/data/bree.schema.json"
    static let primarySettingsDisplayPath = BreeIdentity.current.configFileDisplayPath
    static let legacySettingsDisplayPath = "~/.config/\(BreeIdentity.current.configDirectoryName)/settings.json"
    static let fallbackSettingsDisplayPath = "~/Library/Application Support/com.bree.app/settings.json"
    static let ghosttyConfigDisplayPath = "~/.config/ghostty/config"

    private struct DocsResource {
        let label: String
        let url: String
    }

    private struct DocsReference {
        let topic: String
        let aliases: [String]
        let summary: String
        let webURL: String?
        let rawResources: [DocsResource]
        let commands: [String]
    }

    private struct WorkflowExample {
        let id: String
        let title: String
        let summary: String
        let fit: [String]
        let creates: [String]
        let configFiles: [String]
        let primitives: [String]
        let requires: [String]
        let instantiate: [String]
        let adapt: [String]
        let source: String
    }

    private static let workflowExamplesURL = "https://github.com/ecyx00/bree/blob/main/skills/bree-customization/references/examples.md"

    /// Uses the existing CLI bundle and language lookup for workflow prose.
    static func workflowText(_ key: String, _ defaultValue: String) -> String {
        BREEDiffViewerLocalization.string(key, defaultValue: defaultValue)
    }

    private static let workflowSavedLayoutSteps: [(label: String, command: String)] = [
        (workflowText("cli.workflow.layouts.list", "List saved layouts"), "bree layout list --json"),
        (workflowText("cli.workflow.layouts.inspect", "Inspect a layout"), "bree layout get <name>"),
        (workflowText("cli.workflow.layouts.open", "Open a layout for this project"), "bree layout open <name> --cwd <project>"),
        (workflowText("cli.workflow.layouts.save", "Save the adapted workspace"), "bree layout save <name> --description \"<what this creates>\""),
        (workflowText("cli.workflow.layouts.delete", "Delete an old layout"), "bree layout delete <name>"),
    ]

    private static var workflowCommands: [String] {
        ["bree docs workflows --json"]
            + workflowSavedLayoutSteps.map { $0.command }
            + ["bree reload-config"]
    }

    private static let workflowAdaptAndSave = [
        workflowText("cli.workflow.guidance.choose", "Pick an example that fits the task and lists requirements you have."),
        workflowText("cli.workflow.guidance.recipe", "Open the recipe and copy only the needed top-level keys into .bree/bree.json or ~/.config/bree/bree.json. Add .bree/dock.json when the example uses Dock."),
        workflowText("cli.workflow.guidance.adapt", "Replace sample paths, commands, URLs, tool names, and placements with values for this repository."),
        workflowText("cli.workflow.guidance.validate", "Validate the JSON or JSONC, run bree reload-config, and check the resulting entry point."),
        workflowText("cli.workflow.guidance.save", "When the workspace looks right, save it with bree layout save <name> --description \"<what this creates>\"."),
    ]

    private static let workflowExamples: [WorkflowExample] = [
        WorkflowExample(
            id: "worktree-agents",
            title: workflowText("cli.workflow.worktree-agents.title", "Worktree Agents"),
            summary: workflowText("cli.workflow.worktree-agents.summary", "Start a worktree with two coding-agent terminals and optional context-menu actions."),
            fit: [
                workflowText("cli.workflow.worktree-agents.fit.0", "parallel agent work"),
                workflowText("cli.workflow.worktree-agents.fit.1", "feature worktrees"),
                workflowText("cli.workflow.worktree-agents.fit.2", "repositories where Codex and Claude should open together")
            ],
            creates: [
                workflowText("cli.workflow.worktree-agents.creates.0", "a Worktree Agents new-workspace action"),
                workflowText("cli.workflow.worktree-agents.creates.1", "a workspace rooted at the chosen worktree"),
                workflowText("cli.workflow.worktree-agents.creates.2", "side-by-side Codex and Claude terminal panes"),
                workflowText("cli.workflow.worktree-agents.creates.3", "plus-button context-menu alternatives")
            ],
            configFiles: [".bree/bree.json", "~/.config/bree/bree.json"],
            primitives: [
                "actions.workspaceCommand",
                "ui.newWorkspace.action",
                "ui.newWorkspace.contextMenu",
                "commands[].workspace.layout"
            ],
            requires: [
                workflowText("cli.workflow.worktree-agents.requires.0", "a worktree path"),
                "codex",
                "claude"
            ],
            instantiate: [
                workflowText("cli.workflow.worktree-agents.instantiate.0", "Open the Worktree Agents recipe, merge its actions/ui/commands entries into bree.json, adapt the worktree cwd and agent commands, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.worktree-agents.adapt.0", "change the worktree path"),
                workflowText("cli.workflow.worktree-agents.adapt.1", "swap or add agent commands"),
                workflowText("cli.workflow.worktree-agents.adapt.2", "change split direction"),
                workflowText("cli.workflow.worktree-agents.adapt.3", "keep only the plus-menu entries the project needs")
            ],
            source: workflowExamplesURL + "#worktree-agents"
        ),
        WorkflowExample(
            id: "full-stack-dev",
            title: workflowText("cli.workflow.full-stack-dev.title", "Full-Stack Dev"),
            summary: workflowText("cli.workflow.full-stack-dev.summary", "Open a dev server, test watcher, and browser preview, with optional Git and Feed Dock controls."),
            fit: [
                workflowText("cli.workflow.full-stack-dev.fit.0", "web apps"),
                workflowText("cli.workflow.full-stack-dev.fit.1", "full-stack repositories"),
                workflowText("cli.workflow.full-stack-dev.fit.2", "projects with a local dev server and watch tests")
            ],
            creates: [
                workflowText("cli.workflow.full-stack-dev.creates.0", "a Web terminal"),
                workflowText("cli.workflow.full-stack-dev.creates.1", "a Tests terminal"),
                workflowText("cli.workflow.full-stack-dev.creates.2", "a browser preview"),
                workflowText("cli.workflow.full-stack-dev.creates.3", "optional lazygit and Feed TUI Dock controls")
            ],
            configFiles: [".bree/bree.json", ".bree/dock.json"],
            primitives: [
                "commands[].workspace.layout",
                workflowText("cli.workflow.full-stack-dev.primitives.1", "terminal surfaces"),
                workflowText("cli.workflow.full-stack-dev.primitives.2", "browser surfaces"),
                workflowText("cli.workflow.full-stack-dev.primitives.3", "Dock controls")
            ],
            requires: [
                workflowText("cli.workflow.full-stack-dev.requires.0", "the project's dev command"),
                workflowText("cli.workflow.full-stack-dev.requires.1", "the project's watch-test command"),
                workflowText("cli.workflow.full-stack-dev.requires.2", "optional lazygit")
            ],
            instantiate: [
                workflowText("cli.workflow.full-stack-dev.instantiate.0", "Open the Full-Stack Dev recipe, merge the workspace command and optional Dock controls, replace the sample bun commands and preview URL, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.full-stack-dev.adapt.0", "use the repository's package manager and scripts"),
                workflowText("cli.workflow.full-stack-dev.adapt.1", "change the preview URL/port"),
                workflowText("cli.workflow.full-stack-dev.adapt.2", "replace lazygit or Feed with project-specific Dock monitors")
            ],
            source: workflowExamplesURL + "#full-stack-dev"
        ),
        WorkflowExample(
            id: "ssh-devbox",
            title: workflowText("cli.workflow.ssh-devbox.title", "SSH Devbox"),
            summary: workflowText("cli.workflow.ssh-devbox.summary", "Pair a remote shell with a browser preview in one workspace."),
            fit: [
                workflowText("cli.workflow.ssh-devbox.fit.0", "remote development"),
                workflowText("cli.workflow.ssh-devbox.fit.1", "SSH-backed devboxes"),
                workflowText("cli.workflow.ssh-devbox.fit.2", "projects developed on another machine")
            ],
            creates: [
                workflowText("cli.workflow.ssh-devbox.creates.0", "an SSH terminal pane"),
                workflowText("cli.workflow.ssh-devbox.creates.1", "a browser preview pane")
            ],
            configFiles: [".bree/bree.json", "~/.config/bree/bree.json"],
            primitives: [
                "commands[].workspace.layout",
                workflowText("cli.workflow.ssh-devbox.primitives.1", "terminal surfaces"),
                workflowText("cli.workflow.ssh-devbox.primitives.2", "browser surfaces")
            ],
            requires: [
                workflowText("cli.workflow.ssh-devbox.requires.0", "a working ssh target or alias")
            ],
            instantiate: [
                workflowText("cli.workflow.ssh-devbox.instantiate.0", "Open the SSH Devbox recipe, replace ssh devbox and the preview URL for the project, merge the command into bree.json, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.ssh-devbox.adapt.0", "change the SSH host/command"),
                workflowText("cli.workflow.ssh-devbox.adapt.1", "change the preview URL"),
                workflowText("cli.workflow.ssh-devbox.adapt.2", "add local notes, logs, or another remote pane")
            ],
            source: workflowExamplesURL + "#ssh-devbox"
        ),
        WorkflowExample(
            id: "review-pr",
            title: workflowText("cli.workflow.review-pr.title", "Review PR"),
            summary: workflowText("cli.workflow.review-pr.summary", "Keep pull-request commands beside the browser review page."),
            fit: [
                workflowText("cli.workflow.review-pr.fit.0", "pull-request review"),
                workflowText("cli.workflow.review-pr.fit.1", "GitHub-hosted repositories"),
                workflowText("cli.workflow.review-pr.fit.2", "tasks that combine gh output with browser review")
            ],
            creates: [
                workflowText("cli.workflow.review-pr.creates.0", "a terminal running gh pr status"),
                workflowText("cli.workflow.review-pr.creates.1", "a browser pane on the repository pull-request page")
            ],
            configFiles: [".bree/bree.json", "~/.config/bree/bree.json"],
            primitives: [
                "commands[].workspace.layout",
                workflowText("cli.workflow.review-pr.primitives.1", "terminal surfaces"),
                workflowText("cli.workflow.review-pr.primitives.2", "browser surfaces")
            ],
            requires: [
                workflowText("cli.workflow.review-pr.requires.0", "gh for the sample terminal command")
            ],
            instantiate: [
                workflowText("cli.workflow.review-pr.instantiate.0", "Open the Review PR recipe, point its command and URL at the repository's review flow, merge it into bree.json, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.review-pr.adapt.0", "replace gh pr status with the team's review command"),
                workflowText("cli.workflow.review-pr.adapt.1", "use a specific PR URL"),
                workflowText("cli.workflow.review-pr.adapt.2", "add a notes or diff pane when useful")
            ],
            source: workflowExamplesURL + "#review-pr"
        ),
        WorkflowExample(
            id: "docs-workspace",
            title: workflowText("cli.workflow.docs-workspace.title", "Docs Workspace"),
            summary: workflowText("cli.workflow.docs-workspace.summary", "Run documentation tools beside a Markdown view and browser preview."),
            fit: [
                workflowText("cli.workflow.docs-workspace.fit.0", "documentation work"),
                workflowText("cli.workflow.docs-workspace.fit.1", "docs sites"),
                workflowText("cli.workflow.docs-workspace.fit.2", "projects with a local docs preview")
            ],
            creates: [
                workflowText("cli.workflow.docs-workspace.creates.0", "a docs-server terminal"),
                workflowText("cli.workflow.docs-workspace.creates.1", "a Bree Markdown viewer terminal"),
                workflowText("cli.workflow.docs-workspace.creates.2", "a browser docs preview")
            ],
            configFiles: [".bree/bree.json", "~/.config/bree/bree.json"],
            primitives: [
                "commands[].workspace.layout",
                workflowText("cli.workflow.docs-workspace.primitives.1", "terminal surfaces"),
                "bree markdown",
                workflowText("cli.workflow.docs-workspace.primitives.3", "browser surfaces")
            ],
            requires: [
                workflowText("cli.workflow.docs-workspace.requires.0", "the project's docs-dev command")
            ],
            instantiate: [
                workflowText("cli.workflow.docs-workspace.instantiate.0", "Open the Docs Workspace recipe, replace the docs command, Markdown path, and preview URL, merge it into bree.json, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.docs-workspace.adapt.0", "use the repository's docs command"),
                workflowText("cli.workflow.docs-workspace.adapt.1", "point at the primary Markdown file"),
                workflowText("cli.workflow.docs-workspace.adapt.2", "change the preview path/port"),
                workflowText("cli.workflow.docs-workspace.adapt.3", "drop panes the docs workflow does not need")
            ],
            source: workflowExamplesURL + "#docs-workspace"
        ),
        WorkflowExample(
            id: "quick-agent-buttons",
            title: workflowText("cli.workflow.quick-agent-buttons.title", "Quick Agent Buttons"),
            summary: workflowText("cli.workflow.quick-agent-buttons.summary", "Put Codex and Claude launch actions on the tab bar and in Command Palette."),
            fit: [
                workflowText("cli.workflow.quick-agent-buttons.fit.0", "frequent agent launches"),
                workflowText("cli.workflow.quick-agent-buttons.fit.1", "projects that use multiple coding agents"),
                workflowText("cli.workflow.quick-agent-buttons.fit.2", "personal agent shortcuts")
            ],
            creates: [
                workflowText("cli.workflow.quick-agent-buttons.creates.0", "Codex and Claude agent actions"),
                workflowText("cli.workflow.quick-agent-buttons.creates.1", "surface-tab-bar buttons"),
                workflowText("cli.workflow.quick-agent-buttons.creates.2", "Command Palette entries")
            ],
            configFiles: [".bree/bree.json", "~/.config/bree/bree.json"],
            primitives: [
                "actions.agent",
                "ui.surfaceTabBar.buttons",
                workflowText("cli.workflow.quick-agent-buttons.primitives.2", "Command Palette action exposure")
            ],
            requires: [
                workflowText("cli.workflow.quick-agent-buttons.requires.0", "the agent binaries you keep in the recipe")
            ],
            instantiate: [
                workflowText("cli.workflow.quick-agent-buttons.instantiate.0", "Open the Quick Agent Buttons recipe, keep the agent actions you use, merge actions/ui into bree.json, then run bree reload-config.")
            ],
            adapt: [
                workflowText("cli.workflow.quick-agent-buttons.adapt.0", "remove unused agents"),
                workflowText("cli.workflow.quick-agent-buttons.adapt.1", "change action targets"),
                workflowText("cli.workflow.quick-agent-buttons.adapt.2", "add or remove built-in tab-bar buttons"),
                workflowText("cli.workflow.quick-agent-buttons.adapt.3", "rename button labels")
            ],
            source: workflowExamplesURL + "#quick-agent-buttons"
        ),
        WorkflowExample(
            id: "ci-watch",
            title: workflowText("cli.workflow.ci-watch.title", "CI Watch"),
            summary: workflowText("cli.workflow.ci-watch.summary", "Keep long-running CI and Feed monitors in Dock instead of workspace panes."),
            fit: [
                workflowText("cli.workflow.ci-watch.fit.0", "CI-heavy repositories"),
                workflowText("cli.workflow.ci-watch.fit.1", "GitHub Actions monitoring"),
                workflowText("cli.workflow.ci-watch.fit.2", "long-running status views that should stay beside the workspace")
            ],
            creates: [
                workflowText("cli.workflow.ci-watch.creates.0", "a GitHub Runs Dock control"),
                workflowText("cli.workflow.ci-watch.creates.1", "a Feed TUI Dock control")
            ],
            configFiles: [".bree/dock.json"],
            primitives: [
                workflowText("cli.workflow.ci-watch.primitives.0", "Dock controls"),
                "bree feed tui --opentui"
            ],
            requires: [
                workflowText("cli.workflow.ci-watch.requires.0", "gh for the sample GitHub Runs control")
            ],
            instantiate: [
                workflowText("cli.workflow.ci-watch.instantiate.0", "Open the CI Watch recipe, merge the controls into .bree/dock.json, adapt commands for the repository, validate the JSON, then reload the Dock/config.")
            ],
            adapt: [
                workflowText("cli.workflow.ci-watch.adapt.0", "change the CI command"),
                workflowText("cli.workflow.ci-watch.adapt.1", "replace or add monitor controls"),
                workflowText("cli.workflow.ci-watch.adapt.2", "adjust control heights"),
                workflowText("cli.workflow.ci-watch.adapt.3", "use the global Dock file only for personal cross-project controls")
            ],
            source: workflowExamplesURL + "#ci-watch"
        ),
    ]

    private static let docsReferences: [DocsReference] = [
        DocsReference(
            topic: "settings",
            aliases: ["configuration", "config", "bree-json", "settings-json", "settingsjson", "schema"],
            summary: "Bree-owned settings, bree.json locations, schema, and reload flow.",
            webURL: settingsDocsURL,
            rawResources: [
                DocsResource(label: "settings schema", url: settingsSchemaURL),
                DocsResource(label: "Bree skill", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree/SKILL.md"),
            ],
            commands: [
                "bree settings path",
                "bree settings bree-json",
                "bree config doctor",
                "bree reload-config",
            ]
        ),
        DocsReference(
            topic: "managed-policies",
            aliases: ["mdm", "managed", "policy", "policies", "enterprise", "managed-device-policies"],
            summary: "MDM-enforceable managed policies: disable the embedded browser, iOS remote control, and remote on managed Macs.",
            webURL: "https://github.com/ecyx00/bree/blob/main/docs/managed-device-policies.md",
            rawResources: [
                DocsResource(label: "managed device policies", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/managed-device-policies.md"),
            ],
            commands: [
                "bree browser status --json",
            ]
        ),
        DocsReference(
            topic: "shortcuts",
            aliases: ["keyboard", "keybindings", "keys"],
            summary: "Bree-owned keyboard shortcuts and two-step chord syntax.",
            webURL: nil,
            rawResources: [
                DocsResource(label: "shortcut data", url: "https://raw.githubusercontent.com/ecyx00/bree/main/web/data/bree-shortcuts.ts"),
                DocsResource(label: "settings schema", url: settingsSchemaURL),
            ],
            commands: [
                "bree shortcuts",
                "bree settings shortcuts",
                "bree docs settings",
            ]
        ),
        DocsReference(
            topic: "api",
            aliases: ["cli", "socket", "automation", "handles"],
            summary: "CLI/socket API, handle model, windows, workspaces, panes, and surfaces.",
            webURL: nil,
            rawResources: [
                DocsResource(label: "CLI contract", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/cli-contract.md"),
                DocsResource(label: "Bree skill", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree/SKILL.md"),
            ],
            commands: [
                "bree identify --json",
                "bree tree --all",
            ]
        ),
        DocsReference(
            topic: "browser",
            aliases: ["browser-automation", "webview"],
            summary: "Browser panel automation commands and snapshot-driven web interaction.",
            webURL: nil,
            rawResources: [
                DocsResource(label: "browser skill", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-browser/SKILL.md"),
                DocsResource(label: "browser commands", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-browser/references/commands.md"),
            ],
            commands: [
                "bree browser --help",
                "bree browser snapshot",
            ]
        ),
        DocsReference(
            topic: "capture",
            aliases: ["screenshot", "screenshots", "shot", "record", "recording", "clip", "gif"],
            summary: "Screenshot or record a Bree window from the CLI: png, jpeg, mp4 or gif, with no Screen Recording permission.",
            webURL: nil,
            rawResources: [
                DocsResource(label: "capture skill", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-capture/SKILL.md"),
                DocsResource(label: "capture commands", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-capture/references/commands.md"),
            ],
            commands: [
                "bree shot --label before",
                "bree record start --gif --max-seconds 8 --label sidebar-drag",
                "bree record note \"dragging the workspace\"",
                "bree record stop",
                "bree record list",
            ]
        ),
        DocsReference(
            topic: "agents",
            aliases: ["integrations", "agent-integrations"],
            summary: workflowText("cli.docs.agents.summary", "Agent hook integrations, agent-to-agent messages, Feed approvals, notifications, and session restore. To reach another agent, use `bree agent message`; never type into its terminal."),
            webURL: nil,
            rawResources: [
                DocsResource(label: workflowText("cli.docs.agents.hooks", "agent hook docs"), url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/agent-hooks.md"),
                DocsResource(label: workflowText("cli.docs.agents.messages", "agent messages"), url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/agent-messages.md"),
                DocsResource(label: "feed docs", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/feed.md"),
                DocsResource(label: "notifications docs", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/notifications.md"),
                DocsResource(label: "capture skill", url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-capture/SKILL.md"),
            ],
            commands: [
                "bree agent message <workspace|surface> <text>",
                "bree agent inbox",
                "bree hooks setup",
                "bree hooks setup <agent>",
                "bree hooks hermes-agent install",
                "bree hooks hermes-agent uninstall",
                "bree hooks <agent> uninstall",
            ]
        ),
        DocsReference(
            topic: "workflows",
            aliases: ["workflow", "templates", "template", "presets", "preset", "examples", "layouts", "reusable-layouts"],
            summary: workflowText("cli.workflow.topic.summary", "Saved layouts plus shipped customization examples for common project workflows."),
            webURL: nil,
            rawResources: [
                DocsResource(label: workflowText("cli.workflow.resources.examples", "workflow examples"), url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-customization/references/examples.md"),
                DocsResource(label: workflowText("cli.workflow.resources.skill", "customization skill"), url: "https://raw.githubusercontent.com/ecyx00/bree/main/skills/bree-customization/SKILL.md"),
            ],
            commands: workflowCommands
        ),
        DocsReference(
            topic: "dock",
            aliases: ["doc", "controls", "right-sidebar", "dock-json"],
            summary: "Custom right-sidebar terminal controls from .bree/dock.json or ~/.config/bree/dock.json.",
            webURL: "https://github.com/ecyx00/bree/blob/main/docs/dock.md",
            rawResources: [
                DocsResource(label: "dock docs", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/dock.md"),
                DocsResource(label: "dock web copy", url: "https://raw.githubusercontent.com/ecyx00/bree/main/web/messages/en.json"),
            ],
            commands: [
                "bree docs dock",
                "bree docs dock --json",
                "python3 -m json.tool .bree/dock.json",
            ]
        ),
        DocsReference(
            topic: "sidebars",
            aliases: ["sidebar", "custom-sidebar", "custom-sidebars", "vibe-sidebar"],
            summary: "Vibe-code a custom sidebar: a runtime-interpreted SwiftUI-style file in ~/.config/bree/sidebars/ (beta).",
            webURL: "https://github.com/ecyx00/bree/blob/main/docs/custom-sidebars.md",
            rawResources: [
                DocsResource(label: "custom sidebar authoring guide", url: "https://raw.githubusercontent.com/ecyx00/bree/main/docs/custom-sidebars.md"),
            ],
            commands: [
                "mkdir -p ~/.config/bree/sidebars",
                "cat > ~/.config/bree/sidebars/mine.swift   # write a SwiftUI-style view, then right-click the sidebar button to pick it",
                "bree docs api   # discover bree() action methods/params",
            ]
        ),
    ]

    func runDocsCommand(commandArgs: [String], jsonOutput: Bool) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(docsUsage())
            return
        }

        guard let topic = args.first?.lowercased() else {
            if wantsJSON {
                print(jsonString(["topics": Self.docsReferences.map { docsPayload($0) }]))
            } else {
                printDocsIndex()
            }
            return
        }

        guard args.count == 1 else {
            throw CLIError(message: "Usage: bree docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]")
        }

        if topic == "list" || topic == "all" {
            if wantsJSON {
                print(jsonString(["topics": Self.docsReferences.map { docsPayload($0) }]))
            } else {
                printDocsIndex()
            }
            return
        }

        guard let reference = docsReference(for: topic) else {
            throw CLIError(message: "Unknown docs topic '\(topic)'. Run 'bree docs' for topics.")
        }

        if wantsJSON {
            print(jsonString(docsPayload(reference)))
        } else {
            printDocsReference(reference)
        }
    }

    func docsUsage() -> String {
        return """
        Usage: bree docs [settings|shortcuts|api|browser|capture|agents|workflows|dock|managed-policies]

        Print the canonical docs URL, raw GitHub resources, and useful commands for a Bree topic.
        This command does not require a running Bree app or socket.

        Agents:
          Use `bree docs settings` before editing ~/.config/bree/bree.json.
          \(Self.workflowText("cli.workflow.guidance.discover", "Use `bree docs workflows --json` to choose a shipped workflow example or discover the saved-layout lifecycle."))
          Use `bree docs dock` before creating or editing .bree/dock.json.
          Use `bree docs capture` to screenshot or record a window for a pull request or a bug report.
          Back up any existing bree.json file to a timestamped .bak copy before editing so the user can revert.
          Fetch raw resources with the printed curl commands when you need the latest schema.
        """
    }

    private func docsReference(for topic: String) -> DocsReference? {
        let normalized = topic.replacingOccurrences(of: "_", with: "-")
        return Self.docsReferences.first { reference in
            reference.topic == normalized || reference.aliases.contains(normalized)
        }
    }

    private func docsPayload(_ reference: DocsReference) -> [String: Any] {
        var payload: [String: Any] = [
            "topic": reference.topic,
            "aliases": reference.aliases,
            "summary": reference.summary,
            "web_url": reference.webURL.map { $0 as Any } ?? NSNull(),
            "raw_resources": reference.rawResources.map { resource in
                [
                    "label": resource.label,
                    "url": resource.url,
                    "fetch": "curl -fsSL \(resource.url)",
                ]
            },
            "commands": reference.commands,
        ]
        if reference.topic == "workflows" {
            payload["catalog_version"] = 1
            payload["saved_layouts"] = [
                "description": Self.workflowText("cli.workflow.layouts.description", "Saved layouts capture a live workspace arrangement. Use the shipped examples as starters, adapt the live workspace, then save the result for reuse."),
                "steps": Self.workflowSavedLayoutSteps.map { step in
                    ["label": step.label, "command": step.command]
                },
                "native_surfaces": [
                    Self.workflowText("cli.workflow.native.saveTemplate", "Command Palette: Save Layout as Template…"),
                    Self.workflowText("cli.workflow.native.openLayout", "Command Palette: New Workspace from Layout: <name>"),
                    Self.workflowText("cli.workflow.native.newFromTemplate", "New Workspace menu: New Workspace from Template"),
                ],
            ] as [String: Any]
            payload["examples"] = Self.workflowExamples.map { workflowPayload($0) }
            payload["adapt_and_save"] = Self.workflowAdaptAndSave
        }
        if reference.topic == "settings" {
            payload["settings_files"] = [
                "primary": Self.primarySettingsDisplayPath,
                "legacy": Self.legacySettingsDisplayPath,
                "fallback": Self.fallbackSettingsDisplayPath,
            ]
            payload["ghostty_config"] = [
                "path": Self.ghosttyConfigDisplayPath,
                "note": "Not Bree-owned, but Bree reads it. Use for terminal transparency (background-opacity), blur, font, theme, etc.",
            ]
            payload["backup"] = "Back up any existing bree.json file to a timestamped .bak copy before editing so the user can revert."
            payload["reload_command"] = "bree reload-config"
            payload["reload_scope"] = "Reloads Ghostty config + bree.json and refreshes terminals in place. No app restart needed."
        }
        return payload
    }

    private func printDocsIndex() {
        print("bree docs")
        print()
        print("Topics:")
        for reference in Self.docsReferences {
            print("  \(reference.topic.padding(toLength: 10, withPad: " ", startingAt: 0)) \(reference.summary)")
        }
        print()
        print("Run `bree docs <topic>` for URLs, raw resources, and next commands.")
    }

    private func printDocsReference(_ reference: DocsReference) {
        print("\(reference.topic): \(reference.summary)")
        print()
        if let webURL = reference.webURL {
            print("Web:")
            print("  \(webURL)")
        }
        if !reference.rawResources.isEmpty {
            print()
            print("Raw resources:")
            for resource in reference.rawResources {
                print("  \(resource.label): \(resource.url)")
            }
            print()
            print("Fetch:")
            for resource in reference.rawResources {
                print("  curl -fsSL \(resource.url)")
            }
        }
        if !reference.commands.isEmpty {
            print()
            print("Useful commands:")
            for command in reference.commands {
                print("  \(command)")
            }
        }
        if reference.topic == "workflows" {
            printWorkflowCatalog()
        }
        if reference.topic == "settings" {
            print()
            print("Config files:")
            print("  primary: \(Self.primarySettingsDisplayPath)")
            print("  legacy config: \(Self.legacySettingsDisplayPath)")
            print("  legacy app support: \(Self.fallbackSettingsDisplayPath)")
            print()
            print("Related (not Bree-owned, but Bree reads it for terminal behavior):")
            print("  \(Self.ghosttyConfigDisplayPath)")
            print("  Use this for terminal transparency (background-opacity), blur, font, theme, etc.")
            print()
            print("Before editing bree.json:")
            print("  Back up any existing bree.json file to a timestamped .bak copy so the user can revert.")
            print()
            print("Reload after editing bree.json or Ghostty config:")
            print("  bree reload-config   (reloads BOTH and refreshes terminals; no app restart needed)")
        }
    }

    private func workflowPayload(_ example: WorkflowExample) -> [String: Any] {
        [
            "id": example.id,
            "title": example.title,
            "summary": example.summary,
            "fit": example.fit,
            "creates": example.creates,
            "config_files": example.configFiles,
            "primitives": example.primitives,
            "requires": example.requires,
            "instantiate": example.instantiate,
            "adapt": example.adapt,
            "source": example.source,
        ]
    }

    private func printWorkflowCatalog() {
        print()
        print(Self.workflowText("cli.workflow.headings.savedLayouts", "Saved layouts:"))
        for step in Self.workflowSavedLayoutSteps {
            print("  \(step.label): \(step.command)")
        }
        print()
        print(Self.workflowText("cli.workflow.headings.nativeEntryPoints", "Native saved-layout entry points:"))
        print("  \(Self.workflowText("cli.workflow.native.saveTemplate", "Command Palette: Save Layout as Template…"))")
        print("  \(Self.workflowText("cli.workflow.native.openLayout", "Command Palette: New Workspace from Layout: <name>"))")
        print("  \(Self.workflowText("cli.workflow.native.newFromTemplate", "New Workspace menu: New Workspace from Template"))")
        print()
        print(Self.workflowText("cli.workflow.headings.examples", "Shipped workflow examples:"))
        for example in Self.workflowExamples {
            print("  \(example.id) — \(example.title)")
            print("    \(example.summary)")
            print("    \(Self.workflowText("cli.workflow.labels.fits", "Fits")): \(example.fit.joined(separator: "; "))")
            print("    \(Self.workflowText("cli.workflow.labels.creates", "Creates")): \(example.creates.joined(separator: "; "))")
            print("    \(Self.workflowText("cli.workflow.labels.config", "Config")): \(example.configFiles.joined(separator: "; "))")
            if !example.requires.isEmpty {
                print("    \(Self.workflowText("cli.workflow.labels.requires", "Requires")): \(example.requires.joined(separator: "; "))")
            }
            print("    \(Self.workflowText("cli.workflow.labels.start", "Start")): \(example.instantiate.joined(separator: " "))")
            print("    \(Self.workflowText("cli.workflow.labels.adapt", "Adapt")): \(example.adapt.joined(separator: "; "))")
            print("    \(Self.workflowText("cli.workflow.labels.source", "Source")): \(example.source)")
        }
        print()
        print(Self.workflowText("cli.workflow.headings.adaptAndSave", "Adapt and save:"))
        for step in Self.workflowAdaptAndSave {
            print("  - \(step)")
        }
    }

    func runSettings(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let wantsJSON = jsonOutput || parsedArgs.head.contains("--json")
        let args = parsedArgs.arguments
        let subcommand = args.first?.lowercased() ?? "open"

        if hasHelpRequest(beforeSeparator: parsedArgs.head) {
            print(settingsUsage())
            return
        }

        switch subcommand {
        case "path", "paths":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: bree settings path")
            }
            printSettingsPaths(jsonOutput: wantsJSON)
            return
        case "docs", "documentation":
            guard args.count == 1 else {
                throw CLIError(message: "Usage: bree settings docs")
            }
            if wantsJSON, let reference = docsReference(for: "settings") {
                print(jsonString(docsPayload(reference)))
            } else if let reference = docsReference(for: "settings") {
                printDocsReference(reference)
            }
            return
        case "open":
            let targetRaw: String?
            if args.count > 2 {
                throw CLIError(message: "Usage: bree settings open [target]")
            } else if let rawTarget = args.dropFirst().first {
                guard let target = settingsTargetRawValue(for: rawTarget) else {
                    throw CLIError(message: "Unknown settings target '\(rawTarget)'. Run 'bree settings --help'.")
                }
                targetRaw = target
            } else {
                targetRaw = nil
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
            return
        default:
            guard let targetRaw = settingsTargetRawValue(for: subcommand) else {
                throw CLIError(message: "Unknown settings subcommand '\(subcommand)'. Run 'bree settings --help'.")
            }
            guard args.count == 1 else {
                throw CLIError(message: "Usage: bree settings [open [target]|path|docs|<target>]")
            }
            try openSettingsTarget(
                targetRaw,
                socketPath: socketPath,
                explicitPassword: explicitPassword,
                jsonOutput: wantsJSON
            )
        }
    }

    func settingsCommandDoesNotNeedSocket(_ commandArgs: [String]) -> Bool {
        let parsedArgs = docsSettingsArguments(commandArgs)
        let subcommand = parsedArgs.arguments.first?.lowercased() ?? "open"
        return hasHelpRequest(beforeSeparator: parsedArgs.head) ||
            ["path", "paths", "docs", "documentation"].contains(subcommand)
    }

    func settingsUsage() -> String {
        return """
        Usage: bree settings [open [target]|path|docs|<target>]

        Open Bree Settings, print bree.json paths, or show settings documentation.

        Subcommands:
          open [target]       Open Settings, optionally to a target section.
          path                Print bree.json paths, docs URL, and schema URL.
          docs                Print the same output as `bree docs settings`.

        Targets:
          app, themes, terminal, networking, sidebar-appearance,
          automation, browser, browser-import,
          global-hotkey, keyboard-shortcuts, shortcuts, workspace-colors,
          bree-json, json, reset, advanced

        Config file:
          \(Self.primarySettingsDisplayPath)
          legacy config: \(Self.legacySettingsDisplayPath)
          legacy app support: \(Self.fallbackSettingsDisplayPath)

        Related (not Bree-owned, but Bree reads it for terminal behavior):
          \(Self.ghosttyConfigDisplayPath)

        Before editing bree.json:
          Back up any existing bree.json file to a timestamped .bak copy so the user can revert.

        Reload after editing bree.json or Ghostty config:
          bree reload-config   (reloads BOTH and refreshes terminals; no app restart needed)
        """
    }

    private func settingsTargetRawValue(for rawValue: String) -> String? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")

        switch normalized {
        case "app", "general":
            return "app"
        case "themes", "theme", "appearance":
            return "themes"
        case "terminal":
            return "terminal"
        case "sidebar", "sidebar-appearance", "sidebarappearance":
            return "sidebarAppearance"
        case "automation":
            return "automation"
        case "browser":
            return "browser"
        case "networking", "network":
            return "networking"
        case "advanced":
            return "advanced"
        case "browser-import", "browserimport", "import-browser-data":
            return "browserImport"
        case "global-hotkey", "globalhotkey", "hotkey":
            return "globalHotkey"
        case "keyboard-shortcuts", "keyboardshortcuts", "shortcuts", "keys", "keybindings":
            return "keyboardShortcuts"
        case "workspace-colors", "workspacecolors", "colors":
            return "workspaceColors"
        case "bree-json", "breejson", "settings-json", "settingsjson", "json", "file", "settings-file":
            return "settingsJSON"
        case "reset":
            return "reset"
        default:
            return nil
        }
    }

    private func openSettingsTarget(
        _ targetRaw: String?,
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        var params: [String: Any] = ["activate": true]
        if let targetRaw {
            params["target"] = targetRaw
        }

        let response = try client.sendV2(method: "settings.open", params: params)
        if jsonOutput {
            print(jsonString(response))
        } else {
            let target = (response["target"] as? String) ?? targetRaw ?? "general"
            print("OK target=\(target)")
        }
    }

    func runShortcuts(
        commandArgs: [String],
        socketPath: String,
        explicitPassword: String?,
        jsonOutput: Bool
    ) throws {
        let remaining = commandArgs.filter { $0 != "--" }
        if let unknown = remaining.first {
            throw CLIError(message: "shortcuts: unknown flag '\(unknown)'")
        }

        let client = try connectClient(
            socketPath: socketPath,
            explicitPassword: explicitPassword,
            launchIfNeeded: true
        )
        defer { client.close() }

        let response = try client.sendV2(method: "settings.open", params: [
            "target": "keyboardShortcuts",
            "activate": true,
        ])
        if jsonOutput {
            print(jsonString(response))
        } else {
            print("OK")
        }
    }

    func docsSettingsArguments(_ commandArgs: [String]) -> (head: [String], arguments: [String]) {
        let separatorIndex = commandArgs.firstIndex(of: "--")
        let head = separatorIndex.map { Array(commandArgs[..<$0]) } ?? commandArgs
        let tail = separatorIndex.map { Array(commandArgs[commandArgs.index(after: $0)...]) } ?? []
        let headArguments = head.filter { $0 != "--json" }
        return (head, headArguments + tail)
    }

    func hasHelpRequest(beforeSeparator args: [String]) -> Bool {
        let positionalArgs = args.filter { $0 != "--json" }
        return args.contains("--help") || args.contains("-h") || positionalArgs.first?.lowercased() == "help"
    }
}
