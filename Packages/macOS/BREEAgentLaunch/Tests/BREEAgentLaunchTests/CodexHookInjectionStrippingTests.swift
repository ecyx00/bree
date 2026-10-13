import BREEAgentLaunch
import Testing

@Suite("Codex bree hook injection stripping")
struct CodexHookInjectionStrippingTests {
    private let codexExecutable = "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"

    @Test("Strips realistic bree-injected Codex hook flags")
    func stripsRealisticBreeInjectedCodexHookFlags() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                ["codex"] + realisticCodexHookArgv().dropFirst(),
                launcher: "",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--dangerously-bypass-approvals-and-sandbox",
                "--model",
                "gpt-5.5",
                "-c",
                "model_reasoning_effort=xhigh",
            ]
        )
    }

    @Test("Strips the legacy saved-layout Codex hook block")
    func stripsLegacySavedLayoutCodexHookBlock() {
        let arguments = ["codex"] + hookArguments(
            events: legacySavedLayoutHookEvents
        ) { subcommand in
            "/Users/u/.bree/hooks/bree-codex-hook-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips the legacy synchronous Codex child hook block")
    func stripsLegacySynchronousCodexChildHookBlock() {
        let arguments = ["codex"] + hookArguments(
            events: legacySynchronousChildHookEvents
        ) { subcommand in
            "/Users/u/.bree/hooks/bree-codex-hook-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("The current block pairs the agent message handlers with prompt submit and stop")
    func currentBlockHasInboxCompanions() {
        let companions = CodexHookInjectionSchema.current.events.compactMap { event in
            event.companion.map { "\(event.agentEvent):\($0.breeSubcommand)" }
        }
        #expect(companions == ["UserPromptSubmit:inbox-drain", "Stop:inbox-stop"])
        let value = CodexHookInjectionSchema.current.events[1].configValue { "/h/\($0).sh" }
        #expect(value == "hooks.UserPromptSubmit=[{hooks=[{type=\"command\",command='''/h/prompt-submit.sh''',timeout=5000},{type=\"command\",command='''/h/inbox-drain.sh''',timeout=5000}]}]")
    }

    @Test("Strips the block from before the agent message handlers")
    func stripsBlockWithoutInboxCompanions() {
        let events = CodexHookInjectionSchema.current.events.map {
            CodexHookInjectionEvent(
                agentEvent: $0.agentEvent,
                breeSubcommand: $0.breeSubcommand,
                timeoutMs: $0.timeoutMs,
                delivery: $0.delivery
            )
        }
        let arguments = ["codex"] + hookArguments(events: events) { subcommand in
            "/Users/u/.bree/hooks/bree-codex-hook-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Keeps a hook block whose second handler is not bree's")
    func keepsBlockWithForeignCompanion() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            subcommand == "inbox-drain"
                ? "/Users/u/bin/my-prompt-hook.sh"
                : legacyNamedScriptPath(subcommand)
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == arguments
        )
    }

    @Test("Strips the legacy alias Codex hook block")
    func stripsLegacyAliasCodexHookBlock() {
        let arguments = ["codex"] + hookArguments(
            events: legacyAliasHookEvents,
            joined: true
        ) { subcommand in
            "/Users/u/.bree/hooks/bree-codex-hook-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips inline bree Codex hook snippets")
    func stripsInlineBreeCodexHookSnippets() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            "payload=$(mktemp -t bree-codex-hook.XXXXXX); sh -c 'echo ok' bree-codex-hook \"$payload\" \"$bree_cli\" hooks codex \(subcommand)"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips the inline queued hook fallback")
    func stripsInlineQueuedHookFallback() {
        // If ~/.bree/hooks cannot be written, the wrapper embeds this marked
        // shell body directly in Codex argv. Resume capture must still remove
        // it so the wrapper does not inject a second hook set.
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            if subcommand == "notification" {
                return ": bree-codex-hook; bree hooks codex notification"
            }
            return ": bree-codex-hook; bree hooks enqueue codex \(subcommand)"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips joined bree Codex hook options")
    func stripsJoinedBreeCodexHookOptions() {
        let arguments = ["codex"] + codexWrapperHookArguments(joined: true) { subcommand in
            legacyNamedScriptPath(subcommand)
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips content-addressed bree Codex hook scripts")
    func stripsContentAddressedBreeCodexHookScripts() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            "/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Strips content-addressed hooks below a spaced home path")
    func stripsContentAddressedHooksBelowSpacedHomePath() {
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            "/Volumes/Home Disk/u/.bree/hooks/bree-codex-hook-0123456789abcdef-\(subcommand).sh"
        } + ["--model", "gpt-5.5"]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == ["codex", "--model", "gpt-5.5"]
        )
    }

    @Test("Preserves malformed content-addressed Codex hook paths")
    func preservesMalformedContentAddressedCodexHookPaths() {
        let arguments = [
            "codex",
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-not-a-content-id-stop.sh''',timeout=10000}]}]",
            "--model",
            "gpt-5.5",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == arguments
        )
    }

    @Test("Preserves content-addressed hook paths embedded in commands")
    func preservesContentAddressedHookPathsEmbeddedInCommands() {
        let arguments = [
            "codex",
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''curl https://example.test/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh''',timeout=10000}]}]",
            "--model",
            "gpt-5.5",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == arguments
        )

        let absoluteCommandArguments = [
            "codex",
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/bin/echo /Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh''',timeout=10000}]}]",
            "--model",
            "gpt-5.5",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                absoluteCommandArguments,
                launcher: "",
                fallbackKind: "codex"
            ) == absoluteCommandArguments
        )

        for command in [
            "/bin/true&&/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh",
            "/bin/true\\Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh",
            "/usr/bin/env sh relative/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh",
            "/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-stop.sh*",
        ] {
            let userHookArguments = [
                "--enable",
                "hooks",
                "--dangerously-bypass-hook-trust",
                "-c",
                "hooks.Stop=[{hooks=[{type=\"command\",command='''\(command)''',timeout=10000}]}]",
                "--model",
                "gpt-5.5",
            ]
            let standaloneUserHookArguments = ["codex"] + userHookArguments
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    standaloneUserHookArguments,
                    launcher: "",
                    fallbackKind: "codex"
                ) == standaloneUserHookArguments
            )

            let compoundCommandArguments = ["codex"] + codexWrapperHookArguments { subcommand in
                "/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-\(subcommand).sh"
            } + userHookArguments
            #expect(
                AgentLaunchSanitizer.sanitizedLaunchArguments(
                    compoundCommandArguments,
                    launcher: "",
                    fallbackKind: "codex"
                ) == ["codex"] + userHookArguments
            )
        }
    }

    @Test("Keeps user hook enabling flags when bree injection is stripped")
    func keepsUserHookEnablingFlagsWhenBreeInjectionIsStripped() {
        // bree splices exactly one `--enable hooks` + one trust flag alongside
        // its marker configs; the user's own enable flag and hook config after
        // them must survive stripping so the preserved hook stays enabled.
        let arguments = ["codex"] + codexWrapperHookArguments { subcommand in
            legacyNamedScriptPath(subcommand)
        } + [
            "--enable",
            "hooks",
            "-c",
            "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/bree-codex-hook-wrapper.sh'''}]}]",
            "--model",
            "gpt-5.5",
        ]
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                arguments,
                launcher: "",
                fallbackKind: "codex"
            ) == [
                "codex",
                "--enable",
                "hooks",
                "-c",
                "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/bree-codex-hook-wrapper.sh'''}]}]",
                "--model",
                "gpt-5.5",
            ]
        )
    }

    @Test("Preserves user Codex hook config without bree marker")
    func preservesUserCodexHookConfigWithoutBreeMarker() {
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    codexExecutable,
                    "--enable",
                    "hooks",
                    "-c",
                    "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/bree-codex-hook-wrapper.sh'''}]}]",
                    "--model",
                    "gpt-5.5",
                ],
                launcher: "",
                fallbackKind: "codex"
            ) == [
                codexExecutable,
                "--enable",
                "hooks",
                "-c",
                "hooks.SessionStart=[{hooks=[{type=\"command\",command='''/Users/u/bin/bree-codex-hook-wrapper.sh'''}]}]",
                "--model",
                "gpt-5.5",
            ]
        )
    }

    @Test("Codex resume preservation keeps hooks with captured executable")
    func codexResumePreservationKeepsHooksWithCapturedExecutable() throws {
        let resume = try #require(AgentResumeArgv().builtInKind(
            kind: "codex",
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            executablePath: codexExecutable,
            arguments: realisticCodexHookArgv()
        ))
        #expect(resume.contains("--dangerously-bypass-hook-trust"))
        #expect(resume.contains("--enable"))
        #expect(resume.contains("hooks"))
        #expect(resume.contains { $0.contains("bree-codex-hook") })
        #expect(resume.first == codexExecutable)
        #expect(resume.contains("--dangerously-bypass-approvals-and-sandbox"))
        #expect(resume.contains("gpt-5.5"))
        #expect(resume.contains("model_reasoning_effort=xhigh"))
    }

    @Test("Codex fork preservation keeps hooks with captured executable")
    func codexForkPreservationKeepsHooksWithCapturedExecutable() throws {
        let fork = try #require(AgentForkArgv().builtInKind(
            kind: "codex",
            sessionId: "019dad34-d218-7943-b81a-eddac5c87951",
            executablePath: codexExecutable,
            arguments: realisticCodexHookArgv()
        ))
        #expect(fork.contains("--dangerously-bypass-hook-trust"))
        #expect(fork.contains { $0.contains("bree-codex-hook") })
        #expect(fork.first == codexExecutable)
    }

    @Test("Claude bree hook settings preserve captured executable")
    func claudeBreeHookSettingsPreserveCapturedExecutable() {
        let hookSettings = #"{"env":{"USER_FLAG":"1"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"hooks claude session-start"}]}]},"preferredNotifChannel":"notifications_disabled"}"#
        #expect(
            AgentLaunchSanitizer.sanitizedLaunchArguments(
                [
                    "/Users/u/.local/bin/claude",
                    "--settings",
                    hookSettings,
                    "--dangerously-skip-permissions",
                    "--model",
                    "claude-fable-5",
                    "--effort",
                    "high",
                ],
                launcher: "",
                fallbackKind: "claude"
            ) == [
                "/Users/u/.local/bin/claude",
                "--settings",
                hookSettings,
                "--dangerously-skip-permissions",
                "--model",
                "claude-fable-5",
                "--effort",
                "high",
            ]
        )
    }

    @Test("Unwrap preserves node-hosted Codex without identity proof")
    func unwrapPreservesNodeHostedCodexWithoutIdentityProof() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + breeCodexHookArgs + ["resume", "019dad34-d218-7943-b81a-eddac5c87951", "--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap skips node options before script")
    func unwrapSkipsNodeOptionsBeforeScript() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                [
                    "node",
                    "--require",
                    "tsx",
                    "--import=loader",
                    "--conditions",
                    "development",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.js",
                    breeClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ]
            ) == [
                "node",
                "--require",
                "tsx",
                "--import=loader",
                "--conditions",
                "development",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/claude.js",
                breeClaudeHookSettingsMarker,
                "--model",
                "claude-fable-5",
            ]
        )
    }

    @Test("Unwrap bails when node option consumes script")
    func unwrapBailsWhenNodeOptionConsumesScript() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "-e", "require('/tools/codex')"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "--eval", "require('/tools/codex')"] + breeCodexHookArgs
            ) == nil
        )
    }

    @Test("Unwrap preserves Claude package entrypoints without identity proof")
    func unwrapPreservesClaudePackageEntrypointsWithoutIdentityProof() {
        // Claude Code's real npm entrypoint is cli.js — the basename never
        // matches an agent name, so the package path identifies the sanitizer
        // policy while preserving the captured runtime and script path.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    breeClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ]
            ) == ["node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js", breeClaudeHookSettingsMarker, "--model", "claude-fable-5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                [
                    "node",
                    "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                    "--session-id",
                    "4e06e114-61b2-48ed-93cd-561a23eb5216",
                    breeClaudeHookSettingsMarker,
                    "--model",
                    "claude-fable-5",
                ]
            ) == [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                breeClaudeHookSettingsMarker,
                "--model",
                "claude-fable-5",
            ]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/dist/cli.js"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/dist/cli.js"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", breeClaudeHookSettingsMarker]
            ) == ["node", "/opt/homebrew/lib/node_modules/@openai/codex/bin/codex", breeClaudeHookSettingsMarker]
        )
        // Hook-looking argv contents on a script outside the agent's package
        // must never rewrite it into an agent command.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "script.js"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/tools/router.js", breeClaudeHookSettingsMarker, "--model", "claude-fable-5"]
            ) == nil
        )
    }

    @Test("Unwrap preserves bun-hosted Codex without identity proof")
    func unwrapPreservesBunHostedCodexWithoutIdentityProof() {
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["bun", "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.mjs"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
            ) == ["bun", "/Users/u/.bun/install/global/node_modules/@openai/codex/bin/codex.mjs"] + breeCodexHookArgs + ["--model", "gpt-5.5"]
        )
    }

    @Test("Unwrap does not rewrite project-local scripts")
    func unwrapDoesNotRewriteProjectLocalScripts() {
        // A script named like an agent must never be rewritten into whatever
        // the bare name resolves to. Known package-manager entrypoints can be
        // sanitized while preserving their captured runtime and script path.
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/tools/claude.js", "--model", "claude-fable-5"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "./codex.js", "--foo"]
            ) == nil
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["node", "/repo/node_modules/@openai/codex/bin/codex", "--model", "gpt-5.5"]
            ) == ["node", "/repo/node_modules/@openai/codex/bin/codex", "--model", "gpt-5.5"]
        )
        #expect(
            runtimeUnwrapper.unwrappedArgv(
                ["bun", "/repo/bin/codex.mjs", "--model", "gpt-5.5"]
            ) == nil
        )
    }

    @Test("Wrapper marker detection does not trust hook argv")
    func wrapperMarkerDetectionDoesNotTrustHookArgv() {
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments(realisticCodexHookArgv()))
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments([
            "/Users/u/.local/bin/claude", breeClaudeHookSettingsMarker,
        ]))
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments([
            "/Users/u/.local/bin/claude",
            "--session-id",
            "4e06e114-61b2-48ed-93cd-561a23eb5216",
            "--settings",
            breeClaudeHookSettingsValue,
        ]))
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments([
            "/opt/pinned/claude",
            "--settings",
            userOwnedClaudeHookSettingsValue,
        ]))
        #expect(
            runtimeUnwrapper.unwrappedArgv([
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "--settings",
                userOwnedClaudeHookSettingsValue,
            ]) == [
                "node",
                "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
                "--settings",
                userOwnedClaudeHookSettingsValue,
            ]
        )
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments([
            codexExecutable,
            "--enable",
            "hooks",
            "--dangerously-bypass-hook-trust",
            "-c",
            "hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-stop.sh''',timeout=10000}]}]",
            "--model",
            "gpt-5.5",
        ]))
        #expect(!runtimeUnwrapper.containsBreeWrapperInjectedHookArguments([
            codexExecutable, "--model", "gpt-5.5",
        ]))
    }

    /// Legacy script names (no content ID) for the subcommands that had
    /// them; the agent message handlers only ever had content-addressed names.
    private func legacyNamedScriptPath(_ subcommand: String) -> String {
        subcommand.hasPrefix("inbox-")
            ? "/Users/u/.bree/hooks/bree-codex-hook-0123456789abcdef-\(subcommand).sh"
            : "/Users/u/.bree/hooks/bree-codex-hook-\(subcommand).sh"
    }

    private var runtimeUnwrapper: JavaScriptRuntimeAgentLaunchUnwrapper {
        JavaScriptRuntimeAgentLaunchUnwrapper(isKnownAgentExecutableName: isKnownAgentExecutableName)
    }

    private func realisticCodexHookArgv() -> [String] {
        [codexExecutable] + codexWrapperHookArguments { subcommand in
            legacyNamedScriptPath(subcommand)
        } + [
            "--dangerously-bypass-approvals-and-sandbox",
            "--model",
            "gpt-5.5",
            "-c",
            "model_reasoning_effort=xhigh",
        ]
    }

    private func codexWrapperHookArguments(
        joined: Bool = false,
        command: (String) -> String
    ) -> [String] {
        hookArguments(
            events: codexWrapperHookEvents,
            joined: joined,
            command: command
        )
    }

    private func hookArguments(
        events: [CodexHookInjectionEvent],
        joined: Bool = false,
        command: (String) -> String
    ) -> [String] {
        var arguments = joined
            ? ["--enable=hooks", "--dangerously-bypass-hook-trust"]
            : ["--enable", "hooks", "--dangerously-bypass-hook-trust"]
        for (index, event) in events.enumerated() {
            let value = event.configValue(command: command)
            let option = index.isMultiple(of: 2) ? "-c" : "--config"
            if joined {
                arguments.append("\(option)=\(value)")
            } else {
                arguments.append(contentsOf: [option, value])
            }
        }
        return arguments
    }

    private var codexWrapperHookEvents: [CodexHookInjectionEvent] {
        CodexHookInjectionSchema.current.events
    }

    private var legacySavedLayoutHookEvents: [CodexHookInjectionEvent] {
        let events: [(String, String, Int)] = [
            ("SessionStart", "session-start", 10000),
            ("UserPromptSubmit", "prompt-submit", 10000),
            ("PreToolUse", "pre-tool-use", 10000),
            ("PostToolUse", "post-tool-use", 10000),
            ("Notification", "notification", 10000),
            ("Stop", "stop", 10000),
        ]
        return events.map { CodexHookInjectionEvent(agentEvent: $0.0, breeSubcommand: $0.1, timeoutMs: $0.2) }
    }

    private var legacySynchronousChildHookEvents: [CodexHookInjectionEvent] {
        let events: [(String, String, Int)] = [
            ("SessionStart", "session-start", 10000),
            ("UserPromptSubmit", "prompt-submit", 10000),
            ("Stop", "stop", 10000),
            ("PreToolUse", "pre-tool-use", 120000),
            ("PostToolUse", "post-tool-use", 10000),
            ("PermissionRequest", "notification", 120000),
            ("SubagentStart", "subagent-start", 10000),
            ("SubagentStop", "subagent-stop", 10000),
        ]
        return events.map { CodexHookInjectionEvent(agentEvent: $0.0, breeSubcommand: $0.1, timeoutMs: $0.2) }
    }

    private var legacyAliasHookEvents: [CodexHookInjectionEvent] {
        let events: [(String, String, Int)] = [
            ("SessionStart", "session-start", 10000),
            ("SessionStop", "stop", 10000),
            ("Notification", "notification", 10000),
        ]
        return events.map { CodexHookInjectionEvent(agentEvent: $0.0, breeSubcommand: $0.1, timeoutMs: $0.2) }
    }

    private func isKnownAgentExecutableName(_ name: String) -> Bool {
        name == "codex" || name == "claude"
    }

    /// A minimal bree-wrapper-injected Codex hook argument prefix: the
    /// launch-time marker proving the PATH shim wrapper spawned the process.
    private let breeCodexHookArgs = [
        "--enable",
        "hooks",
        "--dangerously-bypass-hook-trust",
        "-c=hooks.Stop=[{hooks=[{type=\"command\",command='''/Users/u/.bree/hooks/bree-codex-hook-stop.sh''',timeout=10000}]}]",
    ]

    /// A bree-wrapper-injected claude hook settings payload in joined
    /// `--settings=` form.
    private let breeClaudeHookSettingsMarker =
        #"--settings={"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${BREE_CLAUDE_HOOK_BREE_BIN:-bree}\" hooks claude session-start","timeout":10}]}]}}"#

    /// The same bree-wrapper-injected claude hook settings payload in split
    /// `--settings <json>` form.
    private let breeClaudeHookSettingsValue =
        #"{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"matcher":"","hooks":[{"type":"command","command":"\"${BREE_CLAUDE_HOOK_BREE_BIN:-bree}\" hooks claude session-start","timeout":10}]}]}}"#

    /// User-owned settings may mention hook commands without proving that bree's
    /// wrapper launched the executable.
    private let userOwnedClaudeHookSettingsValue =
        #"{"preferredNotifChannel":"notifications_disabled","hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"/Users/u/bin/hooks claude session-start"}]}]}}"#
}
