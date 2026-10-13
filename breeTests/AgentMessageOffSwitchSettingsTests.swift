import BreeAgentJournal
import BreeSettings
import Foundation
import Testing
#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// `agentMessages.enabled` in bree.json reaches the switch the message store
/// reads, and a refused send names the recipient.
@Suite(.serialized)
struct AgentMessageOffSwitchSettingsTests {
    private let enabledKey = AgentMessagesCatalogSection().enabled.userDefaultsKey

    @Test func breeJSONTurnsAgentMessagesOffAndBackOn() throws {
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: enabledKey)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-messages-off-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configURL = directory.appendingPathComponent("bree.json")
        defer {
            if let original { defaults.set(original, forKey: enabledKey) } else { defaults.removeObject(forKey: enabledKey) }
            try? FileManager.default.removeItem(at: directory)
        }
        #expect(AgentMessagesCatalogSection().enabled.defaultValue)

        try #"{"agentMessages":{"enabled":false}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        let store = BreeSettingsFileStore(
            primaryPath: configURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        #expect(!AgentMessageCenter.isEnabled())

        // The store reads the same switch: with it off, a send is refused
        // and nothing is stored.
        let messages = AgentMessageStore(fileURL: nil, isEnabled: { AgentMessageCenter.isEnabled() })
        #expect(throws: AgentMessageBlockedError(block: .messagesDisabled)) {
            try messages.append(AgentMessageDraft(senderName: "a", recipientSurfaceId: "s", body: "hi"))
        }
        #expect(messages.messages(limit: .max).isEmpty)

        try #"{"agentMessages":{"enabled":true}}"#.write(to: configURL, atomically: true, encoding: .utf8)
        store.reload()
        #expect(AgentMessageCenter.isEnabled())
        #expect(try messages.append(AgentMessageDraft(senderName: "a", recipientSurfaceId: "s", body: "hi")).state == .queued)
    }

    @Test func refusedSendTextNamesTheRecipient() {
        let surface = AgentMessageCenter.blockedMessage(
            .recipientDisabled(surfaceId: "S-1"),
            recipientLabel: "surface:5 (reviewer)"
        )
        #expect(surface.contains("surface:5 (reviewer)"))
        let workspace = AgentMessageCenter.blockedMessage(.workspaceDisabled(workspaceId: "W-1"), recipientLabel: nil)
        #expect(workspace.contains("W-1"))
        #expect(AgentMessageCenter.blockedMessage(.messagesDisabled, recipientLabel: nil).contains("agentMessages.enabled"))
    }
}
