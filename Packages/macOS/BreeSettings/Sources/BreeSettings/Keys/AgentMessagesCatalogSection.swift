import Foundation

/// Settings under the dotted-id prefix `agentMessages.*`.
///
/// ``enabled`` is the app-wide switch for `bree agent message`: while it is
/// off, sends are refused and queued messages fail instead of being
/// delivered.
public struct AgentMessagesCatalogSection: SettingCatalogSection {
    /// Whether agents can message each other through bree.
    public let enabled = DefaultsKey<Bool>(
        id: "agentMessages.enabled",
        defaultValue: true,
        userDefaultsKey: "agentMessagesEnabled"
    )

    /// Whether an agent is told when another agent in the same checkout changes
    /// a file it read or edited in the last 30 minutes.
    public let fileOverlapNotice = DefaultsKey<Bool>(
        id: "agentMessages.fileOverlapNotice",
        defaultValue: true,
        userDefaultsKey: "agentMessagesFileOverlapNotice"
    )

    /// Creates the agent messages settings section with its default keys.
    public init() {}
}
