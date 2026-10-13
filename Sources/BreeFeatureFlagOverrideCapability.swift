import BreeSettings
import Foundation

/// Grants the Cloud-only dogfood exception from the installed app identity.
/// Display names, environment variables and persisted defaults cannot grant it.
struct BreeFeatureFlagOverrideCapability: Equatable, Sendable {
    let allowsCloudOverride: Bool
    let enablesCloudDogfood: Bool
    let isDebugBuild: Bool
    let isTaggedDebugArtifact: Bool
    let hasCloudDogfoodMarker: Bool

    init(bundle: Bundle = .main) {
        #if DEBUG
        let marker = bundle.object(forInfoDictionaryKey: "BREECloudDogfoodEnabled") as? Bool
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: true,
                  cloudDogfoodRequested: marker == true,
                  cloudDogfoodMarkerPresent: marker != nil)
        #else
        self.init(bundleIdentifier: bundle.bundleIdentifier, isDebugBuild: false)
        #endif
    }

    init(
        bundleIdentifier: String?,
        isDebugBuild: Bool,
        cloudDogfoodRequested: Bool = false,
        cloudDogfoodMarkerPresent: Bool = false
    ) {
        self.isDebugBuild = isDebugBuild
        self.hasCloudDogfoodMarker = cloudDogfoodMarkerPresent
        // Only the shipping Nightly identity grants the exception in Release.
        // Debug also requires a debug bundle, so stable/staging identities fail closed.
        let debugID = SocketPathMarkerFiles.defaultBaseDebugBundleIdentifier
        isTaggedDebugArtifact = isDebugBuild && bundleIdentifier?.hasPrefix(debugID + ".") == true
        allowsCloudOverride = bundleIdentifier == SocketPathMarkerFiles.nightlyBundleIdentifier
            || (isDebugBuild && (bundleIdentifier == debugID
                || bundleIdentifier?.hasPrefix(debugID + ".") == true))
        enablesCloudDogfood = cloudDogfoodRequested && isDebugBuild
            && bundleIdentifier?.hasPrefix(debugID + ".") == true
    }

    func policy(for definition: BreeFeatureFlagDefinition) -> BreeFeatureFlagOverridePolicy {
        guard definition.key == BreeFeatureFlags.cloudMachinesFlag.key else { return .standard }
        return allowsCloudOverride ? .localFirst : .disabled
    }
}
