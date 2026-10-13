import BREEAgentLaunch
import Foundation

extension BreeVaultAgentRegistration {
    /// Amp's built-in Vault registration backed by bree's managed hook store.
    static var builtInAmp: BreeVaultAgentRegistration {
        BreeVaultAgentRegistration(
            id: "amp",
            name: "Amp",
            iconAssetName: "AgentIcons/Amp",
            detect: BreeVaultAgentDetectRule(processName: "amp"),
            sessionIdSource: .breeHookStore(.amp),
            resumeCommand: RegisteredAgentResumeKind.amp.commandTemplate,
            cwd: .preserve
        )
    }
}
