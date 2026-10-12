/// Write permission for one flag's local override in the current build.
enum CmuxFeatureFlagOverridePolicy: Equatable, Sendable {
    case standard
    case localFirst
    case disabled
}
