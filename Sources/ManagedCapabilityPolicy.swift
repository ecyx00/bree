import AppKit
import BreeSettings
import Foundation

/// MDM master switches for the capabilities that reach off this Mac.
///
/// Each type is the single authoritative answer to "may bree do this at all",
/// so every entry point (UI, command palette, menus, CLI, socket, session
/// restore, automation) composes the same check instead of repeating the
/// resolver lookup. All of them default to *allowed*: an unmanaged Mac, and a
/// managed Mac whose profile does not force the key, behave exactly as before.
///
/// Decisions read only the forced-preference resolver. Tests inject a resolver
/// into the resource owner instead of replacing process-wide policy state.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
enum ManagedRemoteConnectionsPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableRemoteConnections`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableRemoteConnections)
    }

    static var isEnabled: Bool { !isDisabled }

    /// The message shown wherever a refusal surfaces to the user.
    static var disabledMessage: String {
        String(
            localized: "managedPolicy.remoteConnections.disabled",
            defaultValue: "Remote connections are disabled by your organization."
        )
    }
}

/// MDM master switch for bree-mediated file transfer.
/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
enum ManagedFileTransferPolicy: Sendable {
    private static let policy = ManagedDevicePolicy()

    /// Whether a profile forces `DisableFileTransfer`.
    static var isDisabled: Bool {
        return policy.isEnforced(.disableFileTransfer)
    }

    static var isEnabled: Bool { !isDisabled }

    static var disabledMessage: String {
        String(
            localized: "managedPolicy.fileTransfer.disabled",
            defaultValue: "File transfer is disabled by your organization."
        )
    }

    /// The failure handed to upload callers. An `NSError` rather than a new
    /// `RemoteDropUploadError` case, so the shared package enum keeps its
    /// exhaustive switches intact.
    static func refusalError() -> NSError {
        NSError(
            domain: refusalErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: disabledMessage]
        )
    }

    static let refusalErrorDomain = "bree.managedPolicy.fileTransfer"

    /// Whether `error` is this policy's refusal (as opposed to a transport
    /// failure), so a drop or paste handler can explain it instead of beeping.
    static func isRefusal(_ error: Error) -> Bool {
        (error as NSError).domain == refusalErrorDomain
    }

    /// Tells the user why the drop or paste did nothing. The failure handlers
    /// otherwise reduce every upload error to a beep, which would leave a
    /// managed refusal indistinguishable from a broken connection. Callable
    /// from any context: the alert is presented on the main actor.
    static func presentRefusal() {
        let message = disabledMessage
        let detail = String(
            localized: "managedPolicy.fileTransfer.refusalDetail",
            defaultValue: "Bree did not upload the file. Your organization's device policy disables file transfer through Bree."
        )
        let present: @MainActor () -> Void = {
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.alertStyle = .informational
            alert.runModal()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(present)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(present) }
        }
    }
}

/// A managed-policy refusal thrown from a service boundary. Its description
/// is the user-facing message, so socket and CLI error paths print it as-is.
struct ManagedPolicyRefusal: Error, CustomStringConvertible, LocalizedError {
    let message: String
    var description: String { message }
    var errorDescription: String? { message }

    init(
        message: String
    ) {
        self.message = message
    }
}
