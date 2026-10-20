import Foundation

/// Shared copy for drag feedback and rejected catalog/socket mutations.
enum SurfaceTransferRejection: Error, LocalizedError, Equatable, Sendable {
    case remoteMachineMismatch

    var errorDescription: String? { message }

    var message: String {
        String(
            localized: "surfaceDrop.remoteMachineMismatch",
            defaultValue: "Remote workspaces can only hold terminals and displays from their own remote machine. Browser tabs can move freely. Open a local workspace to move other splits there."
        )
    }
}
