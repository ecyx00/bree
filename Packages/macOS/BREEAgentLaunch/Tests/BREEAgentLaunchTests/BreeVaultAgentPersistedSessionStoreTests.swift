import BREEAgentLaunch
import Testing

@Suite("BreeVaultAgentPersistedSessionStore")
struct BreeVaultAgentPersistedSessionStoreTests {
    @Test("Parses every Hermes resume spelling", arguments: [
        ["--resume", "durable-session"],
        ["--resume=durable-session"],
        ["-r", "durable-session"],
        ["-r=durable-session"],
        ["-rdurable-session"],
    ])
    func parsesHermesResumeSpellings(arguments: [String]) {
        #expect(
            BreeVaultAgentPersistedSessionStore.hermesStateDB
                .explicitSessionID(arguments: arguments) == "durable-session"
        )
    }
}
