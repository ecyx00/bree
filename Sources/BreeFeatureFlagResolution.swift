struct BreeFeatureFlagResolution: Equatable, Sendable {
    let effectiveValue: Bool
    let source: BreeFeatureFlagSource
    let allowsLocalOverride: Bool

    init(
        overrideValue: Bool?,
        defaultValue: Bool,
        overridePolicy: BreeFeatureFlagOverridePolicy = .standard
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
