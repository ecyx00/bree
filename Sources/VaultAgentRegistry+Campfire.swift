import BREEAgentLaunch

extension BreeVaultAgentRegistration {
    static var builtInCampfire: BreeVaultAgentRegistration {
        BreeVaultAgentRegistration(
            id: "campfire",
            name: "Campfire",
            detect: BreeVaultAgentDetectRule(
                processName: "campfire",
                alternateProcessNames: ["bun", "node", "deno", "tsx", "ts-node"],
                alternateArgvContainsAny: [
                    "packages/session/bin/campfire.ts",
                    "packages/session/dist/campfire",
                ]
            ),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: RegisteredAgentResumeKind.campfire.commandTemplate,
            cwd: .preserve,
            sessionDirectory: "~/.campfire/agent/sessions"
        )
    }
}
