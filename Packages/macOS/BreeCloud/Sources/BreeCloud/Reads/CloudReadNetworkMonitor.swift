import Foundation
@preconcurrency import Network

/// One path observer for the VM client. The actor owns the mutable
/// Network.framework monitor; only its sendable stream crosses the actor
/// boundary, and it never protects domain state or runs UI work.
actor CloudReadNetworkMonitor {
    private let monitor: NWPathMonitor
    public nonisolated let updates: AsyncStream<Bool>

    public init() {
        let monitor = NWPathMonitor()
        self.monitor = monitor
        let (updates, continuation) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.updates = updates
        monitor.pathUpdateHandler = { continuation.yield($0.status != .unsatisfied) }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "bree.cloud.read-network"))
    }

    deinit { monitor.cancel() }
}

extension Notification.Name {
    static let breeCloudReadNetworkChanged = Notification.Name("bree.cloud.readNetworkChanged")
    static let breeCloudReadNetworkRecovered = Notification.Name("bree.cloud.readNetworkRecovered")
}
