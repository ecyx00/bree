import BREEAgentLaunch
import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

struct BreeConfigActionSaverTests {

    private func temporaryRoot(_ label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "bree-action-saver-\(label)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    // MARK: - Slugs and ids

    @Test func slugForTitle() {
        #expect(BreeConfigActionSaver.slug(forTitle: "My Dev Setup!") == "my-dev-setup")
        #expect(BreeConfigActionSaver.slug(forTitle: "  --  ") == "workspace")
        #expect(BreeConfigActionSaver.slug(forTitle: "日本語 Dev") == "日本語-dev")
    }

    @Test func uniqueActionID() {
        #expect(BreeConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: []) == "dev")
        #expect(
            BreeConfigActionSaver.uniqueActionID(forTitle: "Dev", existingIDs: ["dev", "dev-2"]) == "dev-3"
        )
    }

    // MARK: - Saving

    @Test func savePreservesCommentsAndDecodes() throws {
        let root = try temporaryRoot("comments")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let existing = """
        {
          // build actions
          "actions": {
            "dev": { "type": "command", "command": "make" } // keep me
          }
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        let definition = BreeWorkspaceDefinition(
            name: "Dev",
            cwd: "~/code",
            setup: "make deps",
            layout: .pane(BreePaneDefinition(surfaces: [
                BreeSurfaceDefinition(type: .terminal, command: "claude", focus: true)
            ]))
        )
        let result = try BreeConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: definition,
            globalConfigPath: configPath
        )
        #expect(result.actionID == "dev-2", "id should be uniquified against the existing 'dev'")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// build actions"))
        #expect(saved.contains("// keep me"))

        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        let inline = try #require(config.actions["dev-2"]?.action?.inlineWorkspace)
        #expect(inline.definition.name == "Dev")
        #expect(inline.definition.setup == "make deps")
        #expect(config.actions["dev-2"]?.title == "Dev")
        guard case .pane(let pane)? = inline.definition.layout else {
            Issue.record("Expected pane layout")
            return
        }
        #expect(pane.surfaces.first?.command == "claude")
    }

    @Test func saveRejectsNonObjectActionsBlock() throws {
        let root = try temporaryRoot("nonobject")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let original = "{\n  \"actions\": [\"not\", \"an\", \"object\"]\n}\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try BreeConfigActionSaver.saveWorkspaceAction(
                title: "Nope",
                definition: BreeWorkspaceDefinition(name: "Nope"),
                globalConfigPath: configPath
            )
        }
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    @Test func saveRejectsUnparseableConfig() throws {
        let root = try temporaryRoot("unparseable")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let original = "{ \"actions\": tru }\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try BreeConfigActionSaver.saveWorkspaceAction(
                title: "Nope",
                definition: BreeWorkspaceDefinition(name: "Nope"),
                globalConfigPath: configPath
            )
        }
        // Broken user content must survive byte-identical.
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    @Test func savePreservesSymlinkedConfig() throws {
        let root = try temporaryRoot("symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let realConfig = root.appendingPathComponent("dotfiles-bree.json")
        try "{}\n".write(to: realConfig, atomically: true, encoding: .utf8)
        let linkPath = root.appendingPathComponent("bree.json").path
        try FileManager.default.createSymbolicLink(
            atPath: linkPath,
            withDestinationPath: realConfig.path
        )

        _ = try BreeConfigActionSaver.saveWorkspaceAction(
            title: "Linked",
            definition: BreeWorkspaceDefinition(name: "Linked"),
            globalConfigPath: linkPath
        )

        let attributes = try FileManager.default.attributesOfItem(atPath: linkPath)
        #expect(attributes[.type] as? FileAttributeType == .typeSymbolicLink)
        let saved = try String(contentsOf: realConfig, encoding: .utf8)
        #expect(saved.contains("\"linked\""))
    }

    @Test func saveRespectsReservedIDs() throws {
        let root = try temporaryRoot("reserved")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path

        let result = try BreeConfigActionSaver.saveWorkspaceAction(
            title: "Dev",
            definition: BreeWorkspaceDefinition(name: "Dev"),
            globalConfigPath: configPath,
            reservedActionIDs: ["dev"]
        )
        #expect(result.actionID == "dev-2", "id reserved by the active store must not be reused")
    }

    @Test func saveCreatesFileFromTemplateOwnerOnly() throws {
        let root = try temporaryRoot("template")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("nested/bree.json").path

        let result = try BreeConfigActionSaver.saveWorkspaceAction(
            title: "Fresh",
            definition: BreeWorkspaceDefinition(name: "Fresh"),
            globalConfigPath: configPath
        )
        #expect(result.actionID == "fresh")

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("$schema"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        #expect(config.actions["fresh"]?.action?.inlineWorkspace != nil)

        let permissions = try #require(
            FileManager.default.attributesOfItem(atPath: configPath)[.posixPermissions] as? NSNumber
        )
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    // MARK: - Deleting

    @Test func deleteRemovesActionAndPreservesComments() throws {
        let root = try temporaryRoot("delete")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let existing = """
        {
          // build actions
          "actions": {
            "keep": { "type": "command", "command": "make" }, // keep me
            "gone": {
              "type": "workspace",
              "workspace": { "name": "Gone" }
            }
          },
          "commands": []
        }
        """
        try existing.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "gone", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// build actions"))
        #expect(saved.contains("// keep me"))
        #expect(!saved.contains("\"gone\""))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        #expect(config.actions.count == 1)
        #expect(config.actions["keep"] != nil)
    }

    @Test func deleteFirstOfTwoActionsKeepsValidJSON() throws {
        let root = try temporaryRoot("delete-first")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "a" },
            "second": { "type": "command", "command": "b" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "first", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        #expect(Array(config.actions.keys) == ["second"])
    }

    @Test func deleteLastActionRemovesSeparatorComma() throws {
        let root = try temporaryRoot("delete-last")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "actions": {
            "first": { "type": "command", "command": "https://example.com" }, // url note
            "last": { "type": "command", "command": "b" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "last", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        #expect(saved.contains("// url note"))
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        #expect(Array(config.actions.keys) == ["first"])
    }

    @Test func deleteSoleActionLeavesEmptyObject() throws {
        let root = try temporaryRoot("delete-sole")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        try """
        {
          "actions": {
            "only": { "type": "command", "command": "a" }
          }
        }
        """.write(toFile: configPath, atomically: true, encoding: .utf8)

        try BreeConfigActionSaver.deleteAction(id: "only", globalConfigPath: configPath)

        let saved = try String(contentsOfFile: configPath, encoding: .utf8)
        let sanitized = try JSONCParser.preprocess(data: Data(saved.utf8))
        let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
        #expect(config.actions.isEmpty)
    }

    @Test func deleteMissingActionThrowsAndPreservesFile() throws {
        let root = try temporaryRoot("delete-missing")
        defer { try? FileManager.default.removeItem(at: root) }
        let configPath = root.appendingPathComponent("bree.json").path
        let original = "{\n  \"actions\": {}\n}\n"
        try original.write(toFile: configPath, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            try BreeConfigActionSaver.deleteAction(id: "ghost", globalConfigPath: configPath)
        }
        #expect(try String(contentsOfFile: configPath, encoding: .utf8) == original)
    }

    // MARK: - Foreground command capture

    @Test func commandLinePreservesInvocationFormAndQuotes() {
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["htop"]) == "htop")
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["./gradlew", "test"]) == "./gradlew test"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/usr/bin/npm", "run", "dev server"])
                == "/usr/bin/npm run 'dev server'"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: ["/Apps/My Tool.app/Contents/MacOS/my tool", "--flag"])
                == "'/Apps/My Tool.app/Contents/MacOS/my tool' --flag"
        )
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["-zsh"]) == nil)
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: ["/bin/zsh"]) == nil)
        #expect(TerminalForegroundCommandCapture.commandLine(fromArgv: []) == nil)
    }

    @Test func commandLineStripsAgentResumeArtifacts() {
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/opt/homebrew/bin/claude", "--resume", "abc-123", "--dangerously-skip-permissions",
            ]) == "/opt/homebrew/bin/claude --dangerously-skip-permissions"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "codex", "resume", "0199d9c1", "--yolo",
            ]) == "codex --yolo"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "mytool", "--resume", "state.bin",
            ]) == "mytool --resume state.bin"
        )
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "agy", "--continue", "old-conversation", "--sandbox", "danger-full-access",
            ]) == "agy --sandbox danger-full-access"
        )
    }

    @Test func commandLineStripsNodeCodexBreeHooksAndResume() {
        let command = TerminalForegroundCommandCapture.commandLine(fromArgv: nodeWrappedCodexHookArgv())
        #expect(command?.hasPrefix("node /opt/homebrew/lib/node_modules/@openai/codex/bin/codex ") == true)
        #expect(command?.contains("bree-codex-hook") == false)
        #expect(command?.contains("019dad34-d218-7943-b81a-eddac5c87951") == false)
        #expect(command?.contains("--model gpt-5.5") == true)
    }

    @Test func commandLinePreservesNodeClaudeRuntimeAndUserSettingsOnly() {
        let mergedHookSettings = #"{"env":{"USER_FLAG":"1"},"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${BREE_CLAUDE_HOOK_BREE_BIN:-bree}\" hooks claude session-start","timeout":10}]}]}}"#
        let command = TerminalForegroundCommandCapture.commandLine(fromArgv: [
            "node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "--settings", mergedHookSettings, "--model", "claude-fable-5",
        ])
        #expect(command?.hasPrefix("node /opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js --settings ") == true)
        #expect(command?.contains("USER_FLAG") == true)
        #expect(command?.contains("hooks claude session-start") == false)
        #expect(command?.hasPrefix("claude --settings") == false)
    }

    @Test func commandLineStripsNativeCodexBreeHooksWithoutRewritingExecutable() {
        let nativeCommand = TerminalForegroundCommandCapture.commandLine(
            fromArgv:
            ["/usr/local/bin/codex"] + currentCodexHookArguments() + [
                "--model", "gpt-5.5",
            ]
        )
        #expect(nativeCommand?.hasPrefix("/usr/local/bin/codex ") == true)
        #expect(nativeCommand?.contains("bree-codex-hook-stop.sh") == false)
        #expect(nativeCommand?.contains("--model gpt-5.5") == true)
        #expect(nativeCommand?.hasPrefix("codex ") == false)
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/usr/local/bin/codex", "--model", "gpt-5.5",
            ]) == "/usr/local/bin/codex --model gpt-5.5"
        )
        let explicitPinnedCommand = TerminalForegroundCommandCapture.commandLine(
            fromArgv:
            ["/opt/pinned/bin/codex"] + currentCodexHookArguments() + [
                "--model",
                "gpt-5.5",
            ]
        )
        #expect(explicitPinnedCommand?.hasPrefix("/opt/pinned/bin/codex ") == true)
        #expect(explicitPinnedCommand?.contains("bree-codex-hook-stop.sh") == false)
        #expect(explicitPinnedCommand?.hasPrefix("codex ") == false)
    }

    @Test func commandLineKeepsClaudeDirectBinaryBehavior() {
        #expect(
            TerminalForegroundCommandCapture.commandLine(fromArgv: [
                "/Users/u/.local/bin/claude",
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "high",
            ]) == "/Users/u/.local/bin/claude --dangerously-skip-permissions --model claude-fable-5 --effort high"
        )
    }

    @Test func commandLineStripsNativeClaudeBreeHookSettingsWithoutRewritingExecutable() {
        let mergedHookSettings = #"{"env":{"USER_FLAG":"1"},"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${BREE_CLAUDE_HOOK_BREE_BIN:-bree}\" hooks claude session-start","timeout":10}]}]}}"#
        let command = TerminalForegroundCommandCapture.commandLine(fromArgv: [
            "/opt/homebrew/bin/claude", "--settings", mergedHookSettings, "--model", "claude-fable-5",
        ])
        #expect(command?.hasPrefix("/opt/homebrew/bin/claude --settings ") == true)
        #expect(command?.contains("USER_FLAG") == true)
        #expect(command?.contains("hooks claude session-start") == false)
        #expect(command?.hasPrefix("claude ") == false)
    }

    @Test func knownAgentKindCoversAliasesAndArchSuffixedBuilds() {
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "claude") == "claude")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "agy") == "antigravity")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "cursor-agent") == "cursor")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "grok-macos-aarch64") == "grok")
        // Registry-owned kinds are omitted from allCases but must still match.
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "pi") == "pi")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "grok") == "grok")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "antigravity") == "antigravity")
        #expect(TerminalForegroundCommandCapture.knownAgentKind(forExecutableName: "mytool") == nil)
    }

    @Test func snapshotDisclosuresListEveryPersistedCommandURLAndEnvKey() {
        let snapshot = WorkspaceConfigActionSnapshot(
            definition: BreeWorkspaceDefinition(
                name: "W",
                env: ["API_TOKEN": "secret"],
                layout: .split(BreeSplitDefinition(
                    direction: .horizontal,
                    split: 0.5,
                    children: [
                        .pane(BreePaneDefinition(surfaces: [
                            BreeSurfaceDefinition(type: .terminal, command: "claude", env: ["RUST_LOG": "debug"])
                        ])),
                        .pane(BreePaneDefinition(surfaces: [
                            BreeSurfaceDefinition(type: .browser, url: "https://example.com/callback?code=abc"),
                            BreeSurfaceDefinition(type: .terminal, command: "curl -H 'Authorization: Bearer x'"),
                        ])),
                    ]
                ))
            ),
            skippedPanelCount: 0
        )
        #expect(snapshot.capturedCommands == ["claude", "curl -H 'Authorization: Bearer x'"])
        #expect(snapshot.capturedURLs == ["https://example.com/callback?code=abc"])
        #expect(snapshot.capturedEnvironmentKeys == ["API_TOKEN", "RUST_LOG"])

        let plain = WorkspaceConfigActionSnapshot(
            definition: BreeWorkspaceDefinition(name: "P"),
            skippedPanelCount: 0
        )
        #expect(plain.capturedCommands == [])
        #expect(plain.capturedURLs == [])
        #expect(plain.capturedEnvironmentKeys == [])
    }

    @Test func snapshotReportsOversizedCommands() {
        let exactLimit = String(repeating: "a", count: TerminalForegroundCommandCapture.maxReplayableCommandUTF8Length)
        let oversized = exactLimit + "b"
        let snapshot = WorkspaceConfigActionSnapshot(
            definition: BreeWorkspaceDefinition(
                name: "W",
                setup: oversized,
                layout: .pane(BreePaneDefinition(surfaces: [
                    BreeSurfaceDefinition(type: .terminal, command: exactLimit),
                    BreeSurfaceDefinition(type: .terminal, command: oversized),
                ]))
            ),
            skippedPanelCount: 0
        )
        #expect(snapshot.oversizedCommands == [oversized, oversized])
    }

    private func nodeWrappedCodexHookArgv() -> [String] {
        [
            "node",
            "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex",
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-session-start.sh''',timeout=10000}]}]",
            "-c",
            "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-user-prompt-submit.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PreToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-pre-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.PostToolUse=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-post-tool-use.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Notification=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-notification.sh''',timeout=10000}]}]",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-stop.sh''',timeout=10000}]}]",
            "resume",
            "019dad34-d218-7943-b81a-eddac5c87951",
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            "gpt-5.5",
            "-c",
            "model_reasoning_effort=xhigh",
        ]
    }

    private func currentCodexHookArguments() -> [String] {
        var arguments = ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for event in CodexHookInjectionSchema.current.events {
            arguments.append("-c")
            arguments.append(event.configValue { "/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-\($0).sh" })
        }
        return arguments
    }
}
