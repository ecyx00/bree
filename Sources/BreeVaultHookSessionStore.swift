import Foundation

/// A bree-owned hook-session store that a built-in Vault agent may read.
enum BreeVaultHookSessionStore: String, Codable, Hashable, Sendable {
    case amp
}
