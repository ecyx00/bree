import BreeCloud
import Darwin
import Foundation

/// Owns only its newly-created preview files. Open panels hold leases, so no
/// scan, timeout, or another Files pane can delete a document still in use.
actor RemoteFilePreviewCache {
    private static let staleDirectoryAge: TimeInterval = 60 * 60
    private let root: URL
    private var entries: Set<URL> = []
    private var cleanupTask: Task<Void, Never>?
    private var refreshTasks: [URL: Task<Void, Error>] = [:]

    init(directory: URL = FileManager.default.temporaryDirectory) {
        let owner = ProcessInfo.processInfo.processIdentifier
        root = directory.appendingPathComponent(
            "bree-remote-previews-\(owner)-\(UUID().uuidString)",
            isDirectory: true
        )
        cleanupTask = Task.detached(priority: .utility) { Self.removeStaleDirectories(in: directory) }
    }

    private static func removeStaleDirectories(in directory: URL) {
        // Names only: the temp directory can hold thousands of unrelated entries, and
        // URL + resource-value prefetch for each one was a launch-time heap burst.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let cutoff = Date().addingTimeInterval(-staleDirectoryAge)
        for name in names where name.hasPrefix("bree-remote-previews-") {
            let url = directory.appendingPathComponent(name, isDirectory: true)
            let components = url.lastPathComponent.split(separator: "-")
            guard components.count > 3, let owner = Int32(components[3]) else { continue }
            if owner == ProcessInfo.processInfo.processIdentifier || kill(owner, 0) == 0 || errno == EPERM {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  (values.contentModificationDate ?? .distantFuture) < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    func materialize(path: String, provider: any RemoteFileExplorerProvider) async throws -> RemoteFilePreviewLease {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let filename = (path as NSString).lastPathComponent
        guard !filename.isEmpty, filename != ".", filename != ".." else { throw FileExplorerError.providerUnavailable }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        entries.insert(url)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
            try await provider.downloadFile(path: path, to: url)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
            return RemoteFilePreviewLease(url: url, remotePath: path, remoteIdentity: provider.remoteIdentity, cache: self)
        } catch {
            release(url)
            throw error
        }
    }

    func refresh(_ lease: RemoteFilePreviewLease, provider: any RemoteFileExplorerProvider) async throws {
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard entries.contains(lease.url) else { throw FileExplorerError.providerUnavailable }
        guard lease.remoteIdentity == provider.remoteIdentity else { throw FileExplorerError.providerUnavailable }
        if let task = refreshTasks[lease.url] { return try await task.value }
        let path = lease.remotePath, destination = lease.url
        let task = Task<Void, Error> {
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".bree-refresh-" + UUID().uuidString, isDirectory: false)
            defer { try? FileManager.default.removeItem(at: temporary) }
            try await provider.downloadFile(path: path, to: temporary)
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: temporary.path)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
        refreshTasks[destination] = task
        do {
            try await task.value
            refreshTasks[destination] = nil
        } catch {
            refreshTasks[destination] = nil
            throw error
        }
    }

    func release(_ url: URL) {
        guard entries.remove(url) != nil else { return }
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        if entries.isEmpty { try? FileManager.default.removeItem(at: root) }
    }

    deinit { cleanupTask?.cancel() }
}
