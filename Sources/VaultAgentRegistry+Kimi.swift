import BREEAgentLaunch

extension BreeVaultAgentRegistration {
    /// True only for bree's exact built-in registration, not user registrations reusing its id.
    var isBuiltInKimi: Bool {
        self == Self.builtInKimi
    }

    static var builtInKimi: BreeVaultAgentRegistration {
        BreeVaultAgentRegistration(
            id: "kimi",
            name: RestorableAgentKind.kimi.displayName,
            detect: BreeVaultAgentDetectRule(processNames: ["kimi", "kimi-cli", "kimi-code"]),
            sessionIdSource: .argvOption("--resume"),
            resumeCommand: RegisteredAgentResumeKind.kimi.commandTemplate,
            cwd: .preserve
        )
    }
}
