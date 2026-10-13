import BreeCloud
import AppKit
import Foundation

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Separates accepting a local reservation from receiving the eventual machine receipt.
@MainActor
final class DelayedNewMachineSheetPresenter: NewMachineSheetPresenting {
    let workspaceID: UUID
    let accepted: AsyncStream<Void>
    private let acceptance: AsyncStream<Void>.Continuation
    private var completion: CheckedContinuation<UUID?, Never>?

    init(workspaceID: UUID) {
        self.workspaceID = workspaceID
        (accepted, acceptance) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func presentNewMachineFetchingPlan(preferredWindow: NSWindow?, onReservation: @escaping @MainActor (UUID) -> Void) async -> UUID? {
        onReservation(workspaceID)
        return await withCheckedContinuation { continuation in
            completion = continuation
            acceptance.yield(())
            acceptance.finish()
        }
    }

    func finish() {
        completion?.resume(returning: workspaceID)
        completion = nil
    }
}
