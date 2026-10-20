import BreeSurfaceCatalogModel
import Foundation

/// A destination's ownership rule, independent of UI, drag payloads, and I/O.
struct SurfaceOwnershipPolicy: Equatable, Sendable {
    init(
        remoteMachine: SurfaceMachineID?
    ) {
        self.remoteMachine = remoteMachine
    }

    let remoteMachine: SurfaceMachineID?

    func rejection(for source: SurfaceMachineID?, kind: SurfaceResourceKind? = nil) -> SurfaceTransferRejection? {
        guard kind != .browser, let remoteMachine else { return nil }
        return source == remoteMachine ? nil : .remoteMachineMismatch
    }

    func rejection(for resources: [SurfaceResourceID]) -> SurfaceTransferRejection? {
        guard remoteMachine != nil else { return nil }
        guard !resources.isEmpty else { return .remoteMachineMismatch }
        let ownedResources = resources.filter { $0.kind != .browser }
        guard !ownedResources.isEmpty else { return nil }
        return ownedResources.contains(where: { rejection(for: $0.machine, kind: $0.kind) != nil })
            ? .remoteMachineMismatch : nil
    }

    func rejection(for machines: [SurfaceMachineID]) -> SurfaceTransferRejection? {
        guard remoteMachine != nil else { return nil }
        return machines.isEmpty || machines.contains(where: { rejection(for: $0) != nil })
            ? .remoteMachineMismatch : nil
    }
}
