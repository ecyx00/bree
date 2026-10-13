import BreeAuthRuntime
import Foundation

public protocol CloudTelemetrySending: Sendable {
    nonisolated func enqueue(_ span: CloudTelemetrySpan, identity: AuthenticatedSessionIdentity) async
    nonisolated func clearForSignOut() async
}
