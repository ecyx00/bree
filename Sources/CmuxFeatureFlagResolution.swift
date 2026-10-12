struct CmuxFeatureFlagResolution: Equatable, Sendable {
    let effectiveValue: Bool
    let source: CmuxFeatureFlagSource
    let allowsLocalOverride: Bool

    init(
        overrideValue: Bool?,
        defaultValue: Bool,
        overridePolicy: CmuxFeatureFlagOverridePolicy = .standard
    ) {
        allowsLocalOverride = overridePolicy != .disabled
        if allowsLocalOverride, let overrideValue {
            effectiveValue = overrideValue
            source = .override
        } else {
            effectiveValue = defaultValue
            source = .default
        }
    }
}
