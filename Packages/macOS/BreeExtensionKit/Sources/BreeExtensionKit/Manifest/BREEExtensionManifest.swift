import Foundation

/// Metadata and permission request declared by a BREE extension.
public struct BreeExtensionManifest: Codable, Equatable, Identifiable, Sendable {
    /// Stable reverse-DNS style identifier for the extension.
    public var id: String

    /// Human-readable extension name shown by BREE permission and management UI.
    public var displayName: String

    /// Minimum BREE extension API version required by this extension.
    @_spi(BreeHostTransport) public var minimumAPIVersion: BreeExtensionAPIVersion

    /// Sidebar data scopes the extension asks BREE to include in snapshots.
    public var readScopes: [BreeExtensionScope]

    /// Host action scopes the extension asks BREE to allow.
    public var actionScopes: [BreeExtensionActionScope]

    /// Creates a sidebar extension manifest.
    public init(
        id: String,
        displayName: String,
        readScopes: [BreeExtensionScope] = [],
        actionScopes: [BreeExtensionActionScope] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.minimumAPIVersion = .sidebarV2
        self.readScopes = readScopes
        self.actionScopes = actionScopes
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case minimumAPIVersion
        case readScopes
        case actionScopes
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        minimumAPIVersion = try container.decodeIfPresent(BreeExtensionAPIVersion.self, forKey: .minimumAPIVersion) ?? .sidebarV2
        readScopes = try container.decode([BreeExtensionScope].self, forKey: .readScopes)
        actionScopes = try container.decodeIfPresent(
            [BreeExtensionActionScope].self,
            forKey: .actionScopes
        ) ?? []
    }
}
