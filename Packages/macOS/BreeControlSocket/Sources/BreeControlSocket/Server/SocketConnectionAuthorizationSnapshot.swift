internal import BreeSettings
internal import Foundation

/// Mutable fields protected by ``SocketConnectionAuthorizationState``.
struct SocketConnectionAuthorizationSnapshot: Sendable {
    var accessMode: SocketControlMode = .breeOnly
    var isRunning = false
    var passwordFingerprint: Data?
    var generation = SocketConnectionAuthorizationGeneration(
        number: 0,
        revocationSignal: SocketAuthorizationRevocationSignal()
    )
}
