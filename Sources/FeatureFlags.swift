import CmuxSettings
import Foundation
import Observation
import os

/// Local runtime feature flags for the macOS app. Nothing is fetched: every
/// flag resolves from a permitted local override (`cmux.flags.override.`),
/// then the explicit per-flag compiled default.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class CmuxFeatureFlags {
    static let shared = CmuxFeatureFlags(publishesOffMainSnapshot: true)

    private static let appKitSidebarListDefault = true
    private static let agentInboxQuickViewDefault = true
    #if DEBUG
    nonisolated static let cloudMachinesDefault = true
    #else
    nonisolated static let cloudMachinesDefault = false
    #endif

    private static let overrideKeyPrefix = "cmux.flags.override."

    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default.
    static let appKitSidebarListFlag = CmuxFeatureFlagDefinition(
        key: "sidebar-appkit-list-experiment",
        title: String(
            localized: "featureFlags.appKitSidebarList.title",
            defaultValue: "Lawrence Sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.appKitSidebarList.description",
            defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
        ),
        defaultWhenUnavailable: CmuxFeatureFlags.appKitSidebarListDefault
    )

    // FLAG(key: agent-inbox-quick-view-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2026-10-15, defaultWhenUnavailable: true)
    // Keeps the agent inbox quick view behind an explicit rollout while the
    // placement and cross-agent attention model are evaluated.
    static let agentInboxQuickViewFlag = CmuxFeatureFlagDefinition(
        key: "agent-inbox-quick-view-enabled-release",
        title: String(localized: "featureFlags.agentInbox.title", defaultValue: "Agent Inbox quick view"),
        flagDescription: String(localized: "featureFlags.agentInbox.description", defaultValue: "Shows a keyboard-summoned inbox for agent messages, pending Feed decisions, and finished turns."),
        defaultWhenUnavailable: CmuxFeatureFlags.agentInboxQuickViewDefault
    )

    static let allFlags: [CmuxFeatureFlagDefinition] = [
        appKitSidebarListFlag,
        cloudMachinesFlag,
        agentInboxQuickViewFlag,
    ]

    var isAppKitSidebarListEnabled: Bool {
        effectiveValue(for: Self.appKitSidebarListFlag)
    }

    var isAgentInboxQuickViewEnabled: Bool {
        effectiveValue(for: Self.agentInboxQuickViewFlag)
    }


    /// Effective values mirrored for nonisolated readers that run off the main
    /// actor (the control-socket capability list). Written only by the shared instance so test instances cannot
    /// stomp process-wide state. Before the shared instance exists, readers
    /// get the per-flag compile-time default (fail-closed for release flags).
    private nonisolated static let offMainEffectiveValues = OSAllocatedUnfairLock(
        initialState: [String: Bool]()
    )

    nonisolated static func offMainEffectiveValue(
        for definition: CmuxFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
    @ObservationIgnored
    private let overrideCapability: CmuxFeatureFlagOverrideCapability
    @ObservationIgnored
    private let defaults: UserDefaults

    private var localOverridesByKey: [String: Bool] = [:]
    private var resolutionsByKey: [String: CmuxFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        overrideCapability: CmuxFeatureFlagOverrideCapability = .init(),
        publishesOffMainSnapshot: Bool = false
    ) {
        self.defaults = defaults
        self.overrideCapability = overrideCapability
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        // Cloud's local value is now a first-use activation marker, so it must
        // survive tagged debug artifact reloads just like any other persisted
        // product state. The explicit dogfood marker may still opt a fresh
        // debug artifact in; only the temporary cloud override is reset when
        // a tagged artifact is reopened.
        if overrideCapability.enablesCloudDogfood {
            defaults.set(true, forKey: BetaFeaturesCatalogSection().cloudMachines.userDefaultsKey)
            defaults.set(true, forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
        } else if overrideCapability.isTaggedDebugArtifact {
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
            if overrideCapability.hasCloudDogfoodMarker {
                defaults.set(false, forKey: Self.overrideDefaultsKey(for: Self.cloudMachinesFlag.key))
            }
        }
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    func effectiveValue(for definition: CmuxFeatureFlagDefinition) -> Bool {
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: CmuxFeatureFlagDefinition) -> CmuxFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? CmuxFeatureFlagResolution(
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable,
            overridePolicy: overrideCapability.policy(for: definition)
        )
    }

    func overrideValue(for definition: CmuxFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: CmuxFeatureFlagDefinition) {
        guard value == nil || resolution(for: definition).allowsLocalOverride else { return }

        let previousResolutions = resolutionsByKey
        if let value {
            localOverridesByKey[definition.key] = value
            defaults.set(value, forKey: Self.overrideDefaultsKey(for: definition.key))
        } else {
            localOverridesByKey.removeValue(forKey: definition.key)
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    func clearAllOverrides() {
        let previousResolutions = resolutionsByKey
        var clearedAnyOverride = false
        for definition in Self.allFlags {
            if localOverridesByKey.removeValue(forKey: definition.key) != nil {
                clearedAnyOverride = true
            }
            defaults.removeObject(forKey: Self.overrideDefaultsKey(for: definition.key))
        }
        guard clearedAnyOverride else { return }
        recomputeEffectiveValues()
        postChangeIfNeeded(previousResolutions: previousResolutions)
    }

    private func recomputeEffectiveValues() {
        resolutionsByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            values[definition.key] = CmuxFeatureFlagResolution(
                overrideValue: localOverridesByKey[definition.key],
                defaultValue: definition.defaultWhenUnavailable,
                overridePolicy: overrideCapability.policy(for: definition)
            )
        }
        if publishesOffMainSnapshot {
            let effectiveValues = resolutionsByKey.mapValues(\.effectiveValue)
            Self.offMainEffectiveValues.withLock { $0 = effectiveValues }
        }
    }

    private func postChangeIfNeeded(previousResolutions: [String: CmuxFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
            NotificationCenter.default.post(name: .cmuxFeatureFlagsDidChange, object: self)
        }
    }

    private static func overrideDefaultsKey(for key: String) -> String {
        overrideKeyPrefix + key
    }

    private static func storedOverrideValue(for key: String, defaults: UserDefaults) -> Bool? {
        storedBoolValue(forKey: overrideDefaultsKey(for: key), defaults: defaults)
    }

    private static func storedBoolValue(forKey key: String, defaults: UserDefaults) -> Bool? {
        guard let value = defaults.object(forKey: key) else {
            return nil
        }
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let numberValue = value as? NSNumber {
            return numberValue.boolValue
        }
        return nil
    }
}

extension Notification.Name {
    static let cmuxFeatureFlagsDidChange = Notification.Name("cmuxFeatureFlagsDidChange")
}
