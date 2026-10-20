import Foundation

/// Per-flag override policy. Every flag is standard now that the remote-only
/// dogfood exception is gone.
struct BreeFeatureFlagOverrideCapability: Equatable, Sendable {
    init(bundle: Bundle = .main) {}

    func policy(for definition: BreeFeatureFlagDefinition) -> BreeFeatureFlagOverridePolicy {
        .standard
    }
}
