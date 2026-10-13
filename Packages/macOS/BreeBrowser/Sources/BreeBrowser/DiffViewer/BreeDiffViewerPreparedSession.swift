public import Foundation

/// A validated session ready for cheap installation into the WebKit-facing cache.
///
/// Preparation owns every filesystem, manifest-decoding, and lease operation. The
/// resulting value is `Sendable`, retains its shared lease, and performs no I/O when
/// queried from the main actor.
public struct BreeDiffViewerPreparedSession: Sendable {
    /// The capability token naming the custom-scheme origin.
    public let token: String

    /// When validation completed, used by the app to expire stale sessions.
    public let createdAt: Date

    private let filesByPath: [String: BreeDiffViewerRegisteredFile]
    private let restorableRequestPaths: Set<String>
    private let lease: BreeDiffViewerSessionLease

    /// Creates a prepared session from values validated by ``BreeDiffViewerSessionPreparer``.
    init(
        token: String,
        filesByPath: [String: BreeDiffViewerRegisteredFile],
        restorableRequestPaths: Set<String>,
        createdAt: Date,
        lease: BreeDiffViewerSessionLease
    ) {
        self.token = token
        self.filesByPath = filesByPath
        self.restorableRequestPaths = restorableRequestPaths
        self.createdAt = createdAt
        self.lease = lease
    }

    /// Returns the validated file for an exact request path.
    ///
    /// - Parameter requestPath: Absolute custom-scheme path to look up.
    /// - Returns: Its prepared allowlist entry, or `nil` when the path is not registered.
    public func registeredFile(forRequestPath requestPath: String) -> BreeDiffViewerRegisteredFile? {
        filesByPath[requestPath]
    }

    /// Returns whether an HTML entry is local and excludes pending or redirect placeholders.
    ///
    /// - Parameter requestPath: Absolute custom-scheme path to inspect.
    /// - Returns: `true` only for an entry that can survive restoration without its HTTP server.
    public func isRestorable(requestPath: String) -> Bool {
        restorableRequestPaths.contains(requestPath)
    }
}
