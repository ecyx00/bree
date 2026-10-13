import BREEAgentLaunch
import Foundation

extension BreeVaultAgentRegistration {
    static var builtInHermes: BreeVaultAgentRegistration {
        BreeVaultAgentRegistration(
            id: "hermes-agent",
            name: String(
                localized: "sessionIndex.agent.hermesAgent",
                defaultValue: "Hermes Agent"
            ),
            iconAssetName: "AgentIcons/HermesAgent",
            detect: BreeVaultAgentDetectRule(
                processNames: ["hermes", "hermes-agent"],
                alternateProcessNames: ["python", "python3"],
                alternateArgvBasenamesAny: ["hermes", "hermes-agent"]
            ),
            sessionIdSource: .persistedStore(.hermesStateDB),
            resumeCommand: "{{executable}} --resume {{sessionId}}",
            cwd: .preserve
        )
    }

    /// The persisted-session semantics supported by this exact bree-owned registration.
    ///
    /// Keeping this separate from the decoded `sessionIdSource` prevents a custom Vault
    /// registration from claiming the built-in Hermes argument and indexing contract.
    var persistedSessionStoreCapability: BreeVaultAgentPersistedSessionStore? {
        self == Self.builtInHermes ? .hermesStateDB : nil
    }
}
