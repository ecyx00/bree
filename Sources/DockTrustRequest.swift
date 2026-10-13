struct DockTrustRequest: Identifiable, Sendable {
    var id: String { descriptor.fingerprint }
    let descriptor: BreeActionTrustDescriptor
    let configPath: String
}
