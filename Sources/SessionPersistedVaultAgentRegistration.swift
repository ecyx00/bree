import Foundation

/// Decodes a Vault registration embedded in an app-session snapshot.
///
/// User Vault configuration keeps using ``BreeVaultAgentRegistration``'s strict
/// decoder. This bridge only accepts the bree-owned Hermes registration when its
/// persisted shape matches the built-in definition, then canonicalizes it to the
/// current localized name and icon metadata.
struct SessionPersistedVaultAgentRegistration: Decodable {
    let registration: BreeVaultAgentRegistration

    private enum CodingKeys: String, CodingKey {
        case id, name, iconAssetName, detect, sessionIdSource, resumeCommand
        case forkCommand, cwd, sessionDirectory
    }

    init(from decoder: Decoder) throws {
        do {
            registration = try BreeVaultAgentRegistration(from: decoder)
                .migratedPersistedBuiltInRegistration
            return
        } catch {
            let strictDecodingError = error
            let candidate: BreeVaultAgentRegistration
            do {
                candidate = try Self.decodeUncheckedCandidate(from: decoder)
            } catch {
                throw strictDecodingError
            }
            guard Self.matchesBuiltInHermes(candidate) else {
                throw strictDecodingError
            }
            registration = .builtInHermes
        }
    }

    /// Decodes the stored shape before applying the snapshot-only built-in check.
    private static func decodeUncheckedCandidate(from decoder: Decoder) throws -> BreeVaultAgentRegistration {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        return BreeVaultAgentRegistration(
            id: try container.decode(String.self, forKey: .id),
            name: try container.decode(String.self, forKey: .name),
            iconAssetName: try container.decodeIfPresent(String.self, forKey: .iconAssetName),
            detect: try container.decodeIfPresent(BreeVaultAgentDetectRule.self, forKey: .detect) ?? .init(),
            sessionIdSource: try container.decode(BreeVaultAgentSessionIDSource.self, forKey: .sessionIdSource),
            resumeCommand: try container.decode(String.self, forKey: .resumeCommand),
            forkCommand: try container.decodeIfPresent(String.self, forKey: .forkCommand),
            cwd: try container.decodeIfPresent(BreeVaultAgentCWDPolicy.self, forKey: .cwd) ?? .preserve,
            sessionDirectory: try container.decodeIfPresent(String.self, forKey: .sessionDirectory)
        )
    }

    private static func matchesBuiltInHermes(_ candidate: BreeVaultAgentRegistration) -> Bool {
        let current = BreeVaultAgentRegistration.builtInHermes
        guard candidate.id == current.id,
              !candidate.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        var normalized = candidate
        normalized.name = current.name
        // Early Hermes snapshots may predate the compiled Vault icon metadata.
        if normalized.iconAssetName == nil {
            normalized.iconAssetName = current.iconAssetName
        }
        return normalized == current
    }
}
