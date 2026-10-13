/// Write permission for one flag's local override in the current build.
enum BreeFeatureFlagOverridePolicy: Equatable, Sendable {
    case standard
    case localFirst
    case disabled
}
