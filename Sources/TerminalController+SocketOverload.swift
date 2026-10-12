import CmuxControlSocket
import Foundation
import os

extension TerminalController {
    /// Builds the app's ``ControlOverloadResponder`` with localized copy and
    /// default rejection handling.
    nonisolated static func makeSocketOverloadResponder() -> ControlOverloadResponder {
        ControlOverloadResponder(
            strings: ControlOverloadResponder.Strings(
                message: String(
                    localized: "socket.overloaded.message",
                    defaultValue: "Bree is handling too many control-socket requests right now, so this one was not run. Retry in a moment."
                )
            ),
            configuration: ControlOverloadResponder.Configuration(
                maximumConcurrentReplies: socketOverloadMaximumConcurrentReplies
            )
        )
    }

    /// Maps the pool's drop reason onto the wire-visible rejection reason.
    nonisolated static func socketOverloadReason(
        for dropReason: ControlClientWorkerPool.DropReason
    ) -> ControlOverloadReason {
        switch dropReason {
        case .pendingQueueFull: .poolSaturated
        case .pendingExpired: .pendingExpired
        case .stopped: .serverStopping
        }
    }

    /// Hands an accepted connection the server cannot serve to the overload
    /// responder, which answers it with a structured `overloaded` error and
    /// closes it. Replaces the bare `close(2)` that every rejected client used
    /// to see as `EPIPE` (#13369).
    nonisolated func rejectSocketClient(_ socket: Int32, reason: ControlOverloadReason) {
        socketOverloadResponder.reject(socket: socket, reason: reason)
    }
}
