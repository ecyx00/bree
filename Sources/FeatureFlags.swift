import BreeSettings
import Foundation
import Observation
import os

/// Local runtime feature flags for the macOS app. Nothing is fetched: every
/// flag resolves from a permitted local override (`bree.flags.override.`),
/// then the explicit per-flag compiled default.
///
/// Registry contract (enforced by scripts/lint-feature-flags.py in CI): each
/// flag declares key / owner / reviewBy / defaultWhenUnavailable in the FLAG
/// comment above its property, and its key literal appears nowhere else.
@MainActor
@Observable
final class BreeFeatureFlags {
    static let shared = BreeFeatureFlags(publishesOffMainSnapshot: true)

    private static let appKitSidebarListDefault = true
    private static let agentInboxQuickViewDefault = true

    private static let overrideKeyPrefix = "bree.flags.override."

    // FLAG(key: sidebar-appkit-list-experiment, owner: lawrencecchen,
    //      reviewBy: 2026-11-16, defaultWhenUnavailable: true)
    // Renders the workspace sidebar with the AppKit NSTableView list
    // (virtualized rows, measured-once heights) instead of the SwiftUI
    // LazyVStack. On by default.
    static let appKitSidebarListFlag = BreeFeatureFlagDefinition(
        key: "sidebar-appkit-list-experiment",
        title: String(
            localized: "featureFlags.appKitSidebarList.title",
            defaultValue: "Lawrence Sidebar"
        ),
        flagDescription: String(
            localized: "featureFlags.appKitSidebarList.description",
            defaultValue: "Renders the workspace sidebar with a native AppKit list and divider for smoother scrolling and resizing with many workspaces."
        ),
        defaultWhenUnavailable: BreeFeatureFlags.appKitSidebarListDefault
    )

    // FLAG(key: agent-inbox-quick-view-enabled-release, owner: lawrencecchen,
    //      reviewBy: 2027-01-15, defaultWhenUnavailable: true)
    // Keeps the agent inbox quick view behind an explicit rollout while the
    // placement and cross-agent attention model are evaluated.
    static let agentInboxQuickViewFlag = BreeFeatureFlagDefinition(
        key: "agent-inbox-quick-view-enabled-release",
        title: String(localized: "featureFlags.agentInbox.title", defaultValue: "Agent Inbox quick view"),
        flagDescription: String(localized: "featureFlags.agentInbox.description", defaultValue: "Shows a keyboard-summoned inbox for agent messages, pending Feed decisions, and finished turns."),
        defaultWhenUnavailable: BreeFeatureFlags.agentInboxQuickViewDefault
    )

    static let allFlags: [BreeFeatureFlagDefinition] = [
        appKitSidebarListFlag,
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
        for definition: BreeFeatureFlagDefinition
    ) -> Bool {
        offMainEffectiveValues.withLock { $0[definition.key] }
            ?? definition.defaultWhenUnavailable
    }

    @ObservationIgnored
    private let publishesOffMainSnapshot: Bool
    @ObservationIgnored
    private let overrideCapability: BreeFeatureFlagOverrideCapability
    @ObservationIgnored
    private let defaults: UserDefaults

    private var localOverridesByKey: [String: Bool] = [:]
    private var resolutionsByKey: [String: BreeFeatureFlagResolution] = [:]

    init(
        defaults: UserDefaults = .standard,
        overrideCapability: BreeFeatureFlagOverrideCapability = .init(),
        publishesOffMainSnapshot: Bool = false
    ) {
        self.defaults = defaults
        self.overrideCapability = overrideCapability
        self.publishesOffMainSnapshot = publishesOffMainSnapshot
        localOverridesByKey = Self.allFlags.reduce(into: [:]) { values, definition in
            if let value = Self.storedOverrideValue(for: definition.key, defaults: defaults) {
                values[definition.key] = value
            }
        }
        recomputeEffectiveValues()
    }

    func effectiveValue(for definition: BreeFeatureFlagDefinition) -> Bool {
        resolution(for: definition).effectiveValue
    }

    func resolution(for definition: BreeFeatureFlagDefinition) -> BreeFeatureFlagResolution {
        resolutionsByKey[definition.key] ?? BreeFeatureFlagResolution(
            overrideValue: localOverridesByKey[definition.key],
            defaultValue: definition.defaultWhenUnavailable,
            overridePolicy: overrideCapability.policy(for: definition)
        )
    }

    func overrideValue(for definition: BreeFeatureFlagDefinition) -> Bool? {
        localOverridesByKey[definition.key]
    }

    func setOverride(_ value: Bool?, for definition: BreeFeatureFlagDefinition) {
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
            values[definition.key] = BreeFeatureFlagResolution(
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

    private func postChangeIfNeeded(previousResolutions: [String: BreeFeatureFlagResolution]) {
        if previousResolutions != resolutionsByKey {
            NotificationCenter.default.post(name: .breeFeatureFlagsDidChange, object: self)
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
    static let breeFeatureFlagsDidChange = Notification.Name("breeFeatureFlagsDidChange")
}
