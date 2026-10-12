import Bonsplit
import CmuxCloud
import CmuxFoundation
import AppKit
import Combine
import Foundation
import QuartzCore
import SwiftUI

// MARK: - Explorer Visual Style

enum FileExplorerStyle: Int, CaseIterable {
    case liquidGlass = 0
    case highDensity = 1
    case terminalStealth = 2
    case proStudio = 3
    case finder = 4

    var label: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .highDensity: return "High-Density IDE"
        case .terminalStealth: return "Terminal Stealth"
        case .proStudio: return "Pro Studio"
        case .finder: return "Finder"
        }
    }

    var rowHeight: CGFloat {
        let baseHeight: CGFloat
        switch self {
        case .liquidGlass: baseHeight = 28
        case .highDensity: baseHeight = 20
        case .terminalStealth: baseHeight = 24
        case .proStudio: baseHeight = 32
        case .finder: baseHeight = 26
        }
        return GlobalFontMagnification.scaledSize(baseHeight)
    }

    var indentation: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 12
        case .terminalStealth: return 14
        case .proStudio: return 20
        case .finder: return 18
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .liquidGlass: return 16
        case .highDensity: return 14
        case .terminalStealth: return 12
        case .proStudio: return 18
        case .finder: return 18
        }
    }

    var iconWeight: NSFont.Weight {
        switch self {
        case .liquidGlass, .highDensity, .terminalStealth, .proStudio, .finder: return .regular
        }
    }

    var nameFont: NSFont {
        switch self {
        case .terminalStealth: return BreeType.nsFont(.mono)
        case .liquidGlass, .highDensity, .proStudio, .finder: return BreeType.nsFont(.body)
        }
    }

    var iconToTextSpacing: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 4
        case .terminalStealth: return 6
        case .proStudio: return 12
        case .finder: return 6
        }
    }

    var selectionInset: CGFloat {
        switch self {
        case .liquidGlass: return 8
        case .highDensity: return 0
        case .terminalStealth: return 0
        case .proStudio: return 4
        case .finder: return 4
        }
    }

    var selectionRadius: CGFloat {
        switch self {
        case .liquidGlass, .proStudio: return BreeMetrics.radiusControl
        case .highDensity, .terminalStealth: return 0
        case .finder: return BreeMetrics.radiusSmall
        }
    }

    var selectionColor: NSColor {
        switch self {
        case .liquidGlass, .highDensity, .terminalStealth, .proStudio, .finder:
            return FileExplorerPalette.selectedFill
        }
    }

    var hoverColor: NSColor {
        switch self {
        case .liquidGlass, .highDensity, .terminalStealth, .proStudio, .finder:
            return FileExplorerPalette.hoverFill
        }
    }

    var usesBorderSelection: Bool {
        self == .terminalStealth
    }

    var fileIconTint: NSColor {
        palette.fileIconTint
    }

    var folderIconTint: NSColor {
        palette.folderIconTint
    }

    func gitColor(for status: GitFileStatus) -> NSColor {
        palette.gitColor(for: status)
    }

    private var palette: FileExplorerPalette {
        switch self {
        case .liquidGlass, .highDensity, .terminalStealth, .proStudio, .finder: .bree
        }
    }

    static var current: FileExplorerStyle {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "fileExplorer.style") == nil {
            return .highDensity
        }
        return FileExplorerStyle(rawValue: defaults.integer(forKey: "fileExplorer.style")) ?? .highDensity
    }
}

// MARK: - Models

struct FileExplorerEntry: Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
}

final class FileExplorerNode: Identifiable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileExplorerNode]?
    var isLoading: Bool = false
    var error: String?
    var resourceContextID: UUID?

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
    }

    var isExpandable: Bool { isDirectory }

    /// Children are stored in display order (see ``FileExplorerListingMerge/precedes(_:_:)``),
    /// so no per-call sort is needed on the data-source hot path.
    var sortedChildren: [FileExplorerNode]? { children }
}

/// One parent's child list changed: indexes in the old list that were removed, and indexes in the
/// new list that were inserted. The outline view applies these instead of reloading.
struct FileExplorerStructuralChange: Equatable {
    /// `nil` means the root list.
    let parentPath: String?
    let removed: IndexSet
    let inserted: IndexSet
}

/// Pure diff of a fresh directory listing against the nodes already shown.
enum FileExplorerListingMerge {
    struct Result {
        let children: [FileExplorerNode]
        let removedIndexes: IndexSet
        let insertedIndexes: IndexSet
        let removedNodes: [FileExplorerNode]
        let insertedNodes: [FileExplorerNode]
        var isEmpty: Bool { removedIndexes.isEmpty && insertedIndexes.isEmpty }
    }

    /// Directories first, then case-insensitive name, path as a deterministic tie-break.
    static func precedes(_ a: FileExplorerNode, _ b: FileExplorerNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        let order = a.name.localizedCaseInsensitiveCompare(b.name)
        if order != .orderedSame { return order == .orderedAscending }
        return a.path < b.path
    }

    /// Reuses nodes whose path and kind are unchanged (keeping their loaded subtree), creates nodes
    /// for new entries, and reports removed/inserted indexes. A rename is one remove plus one insert.
    static func merge(
        existing: [FileExplorerNode],
        entries: [FileExplorerEntry],
        makeNode: (FileExplorerEntry) -> FileExplorerNode
    ) -> Result {
        var existingByPath: [String: FileExplorerNode] = [:]
        existingByPath.reserveCapacity(existing.count)
        for node in existing { existingByPath[node.path] = node }
        var kept = Set<ObjectIdentifier>()
        var inserted: [FileExplorerNode] = []
        var children: [FileExplorerNode] = []
        children.reserveCapacity(entries.count)
        for entry in entries {
            if let node = existingByPath[entry.path], node.isDirectory == entry.isDirectory {
                kept.insert(ObjectIdentifier(node))
                children.append(node)
            } else {
                let node = makeNode(entry)
                inserted.append(node)
                children.append(node)
            }
        }
        children.sort(by: precedes)
        var removedIndexes = IndexSet()
        var removedNodes: [FileExplorerNode] = []
        for (index, node) in existing.enumerated() where !kept.contains(ObjectIdentifier(node)) {
            removedIndexes.insert(index)
            removedNodes.append(node)
        }
        var insertedIndexes = IndexSet()
        if !inserted.isEmpty {
            let insertedIDs = Set(inserted.map(ObjectIdentifier.init))
            for (index, node) in children.enumerated() where insertedIDs.contains(ObjectIdentifier(node)) {
                insertedIndexes.insert(index)
            }
        }
        return Result(
            children: children, removedIndexes: removedIndexes, insertedIndexes: insertedIndexes,
            removedNodes: removedNodes, insertedNodes: inserted
        )
    }
}

/// Debounce with a cap: an event burst fires once it has been quiet for `quiet`, but never later
/// than `cap` after the first unserved event, so constant churn still refreshes at a bounded rate.
/// Times are monotonic seconds supplied by the caller (testable without a clock).
struct FileExplorerRefreshCoalescer: Equatable {
    var quiet: TimeInterval
    var cap: TimeInterval
    private(set) var firstPending: TimeInterval?
    private(set) var lastEvent: TimeInterval?

    init(quiet: TimeInterval = 0.25, cap: TimeInterval = 1.0) {
        self.quiet = quiet
        self.cap = cap
    }

    var hasPending: Bool { firstPending != nil }

    mutating func noteEvent(at now: TimeInterval) {
        if firstPending == nil { firstPending = now }
        lastEvent = now
    }

    /// When the pending burst should be served, or `nil` when nothing is pending.
    var deadline: TimeInterval? {
        guard let firstPending, let lastEvent else { return nil }
        return min(lastEvent + quiet, firstPending + cap)
    }

    mutating func didFire() {
        firstPending = nil
        lastEvent = nil
    }

    mutating func reset() { didFire() }
}

// MARK: - Root Resolver

enum FileExplorerRootResolver {
    static func displayPath(for fullPath: String, homePath: String?) -> String {
        guard let home = homePath, !home.isEmpty else { return fullPath }
        let normalizedHome = home.hasSuffix("/") ? String(home.dropLast()) : home
        let normalizedPath = fullPath.hasSuffix("/") ? String(fullPath.dropLast()) : fullPath
        if normalizedPath == normalizedHome {
            return "~"
        }
        let homePrefix = normalizedHome + "/"
        if normalizedPath.hasPrefix(homePrefix) {
            return "~/" + normalizedPath.dropFirst(homePrefix.count)
        }
        return fullPath
    }
}

// MARK: - Provider Protocol

protocol FileExplorerProvider: AnyObject {
    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry]
    var homePath: String { get }
    var isAvailable: Bool { get }
}

struct SSHFileExplorerConnection: Equatable, Sendable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let sshOptions: [String]
}

protocol SSHFileExplorerTransport: AnyObject {
    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String
    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry]
    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws
}

enum FileExplorerWorkspaceRoot: Equatable {
    case none
    case local(workspaceId: UUID, path: String)
    case remoteSSH(
        workspaceId: UUID,
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        rootPath: String?,
        isAvailable: Bool,
        unavailableDetail: String?
    )
}

// MARK: - Local Provider

/// Dedicated GCD queue for blocking file-system and child-process work.
/// `open()`/`readdir`/`waitpid` must never run on Swift's cooperative pool (about one thread per
/// core): a few stuck calls (TCC prompts, slow volumes) would starve every other async task.
enum BlockingFileSystem {
    /// General blocking work (stat, process wait, scans).
    private static let queue = BoundedBlockingQueue(label: "com.cmux.blocking-fs", maxConcurrent: 6)
    /// Directory listings get their own small lane so a burst of stuck `open()` calls
    /// (TCC prompt, dead volume) can pin at most this many threads and never starves other work.
    private static let listingQueue = BoundedBlockingQueue(label: "com.cmux.blocking-fs.listing", maxConcurrent: 3)

    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.submit { continuation.resume(returning: work()) }
        }
    }

    static func runThrowing<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.submit { continuation.resume(with: Result { try work() }) }
        }
    }

    private static let listingLock = NSLock()
    nonisolated(unsafe) private static var listingWaiters:
        [String: [CheckedContinuation<Result<[FileExplorerEntry], Error>, Never>]] = [:]

    /// Lists on the bounded listing lane. A listing already in flight for the same key is joined,
    /// not repeated: reloads of a path whose `open()` never returns add no threads.
    static func coalescedListing(
        key: String,
        _ work: @escaping @Sendable () throws -> [FileExplorerEntry]
    ) async throws -> [FileExplorerEntry] {
        let result: Result<[FileExplorerEntry], Error> = await withCheckedContinuation { continuation in
            listingLock.lock()
            if listingWaiters[key] != nil {
                listingWaiters[key]?.append(continuation)
                listingLock.unlock()
                return
            }
            listingWaiters[key] = [continuation]
            listingLock.unlock()
            listingQueue.submit {
                let outcome = Result { try work() }
                listingLock.lock()
                let waiters = listingWaiters.removeValue(forKey: key) ?? []
                listingLock.unlock()
                for waiter in waiters { waiter.resume(returning: outcome) }
            }
        }
        return try result.get()
    }

    /// Folders directly under home that macOS guards with a TCC privacy prompt.
    static func isTCCProtectedPath(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let protectedNames: Set<String> = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies"]
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let homeURL = URL(fileURLWithPath: home).standardizedFileURL
        guard url.deletingLastPathComponent().path == homeURL.path else { return false }
        return protectedNames.contains(url.lastPathComponent)
    }
}

/// GCD queue that runs at most `maxConcurrent` jobs at once; extra jobs wait in FIFO order.
/// Unlike a plain concurrent queue it cannot spawn an unbounded number of threads when jobs block.
final class BoundedBlockingQueue: @unchecked Sendable {
    private let queue: DispatchQueue
    private let maxConcurrent: Int
    private let lock = NSLock()
    private var running = 0
    private var pending: [@Sendable () -> Void] = []

    init(label: String, maxConcurrent: Int) {
        self.queue = DispatchQueue(label: label, qos: .utility, attributes: .concurrent)
        self.maxConcurrent = maxConcurrent
    }

    func submit(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        if running >= maxConcurrent {
            pending.append(job)
            lock.unlock()
            return
        }
        running += 1
        lock.unlock()
        launch(job)
    }

    private func launch(_ job: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            job()
            lock.lock()
            if pending.isEmpty {
                running -= 1
                lock.unlock()
            } else {
                let next = pending.removeFirst()
                lock.unlock()
                launch(next)
            }
        }
    }
}

final class LocalFileExplorerProvider: FileExplorerProvider {
    var homePath: String { NSHomeDirectory() }
    var isAvailable: Bool { true }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard !Task.isCancelled else { throw CancellationError() }
        return try await BlockingFileSystem.coalescedListing(key: "\(showHidden ? 1 : 0)|\(path)") {
            try Self.listDirectorySync(path: path, showHidden: showHidden)
        }
    }

    private static func listDirectorySync(path: String, showHidden: Bool) throws -> [FileExplorerEntry] {
        let fm = FileManager.default
        let contents = try fm.contentsOfDirectory(atPath: path)
        return contents.compactMap { name in
            let fullPath = (path as NSString).appendingPathComponent(name)
            if !showHidden {
                let flagged = (try? URL(fileURLWithPath: fullPath).resourceValues(forKeys: [.isHiddenKey]))?.isHidden == true
                if name.hasPrefix(".") || flagged { return nil }
            }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fullPath, isDirectory: &isDir) else { return nil }
            return FileExplorerEntry(name: name, path: fullPath, isDirectory: isDir.boolValue)
        }
    }
}

// MARK: - SSH Provider

// Captured by async SSH tasks; mutable availability/root state is guarded by stateLock.
final class SSHFileExplorerProvider: RemoteFileExplorerProvider, @unchecked Sendable {
    private struct State: Sendable {
        var homePath: String
        var isAvailable: Bool
    }

    let connection: SSHFileExplorerConnection
    let displayTarget: String
    private let transport: SSHFileExplorerTransport
    private let stateLock = NSLock()
    private var state: State

    var homePath: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.homePath
    }

    var isAvailable: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state.isAvailable
    }

    var destination: String { connection.destination }
    nonisolated var remoteIdentity: String {
        "ssh:\(connection.destination)|\(connection.port.map(String.init) ?? "")|\(connection.identityFile ?? "")|\(connection.sshOptions.joined(separator: "\u{1f}"))"
    }
    var port: Int? { connection.port }
    var identityFile: String? { connection.identityFile }
    var sshOptions: [String] { connection.sshOptions }

    init(
        destination: String,
        port: Int?,
        identityFile: String?,
        sshOptions: [String],
        displayTarget: String? = nil,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = SSHFileExplorerConnection(
            destination: destination,
            port: port,
            identityFile: identityFile,
            sshOptions: sshOptions
        )
        self.displayTarget = displayTarget ?? {
            guard let port else { return destination }
            return "\(destination):\(port)"
        }()
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    init(
        connection: SSHFileExplorerConnection,
        displayTarget: String,
        homePath: String,
        isAvailable: Bool,
        transport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        self.connection = connection
        self.displayTarget = displayTarget
        self.transport = transport
        self.state = State(homePath: homePath, isAvailable: isAvailable)
    }

    func updateAvailability(_ available: Bool, homePath: String?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        state.isAvailable = available
        if let homePath {
            state.homePath = homePath
        }
    }

    func resolveHomePath() async throws -> String {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        let home = try await transport.resolveHomePath(connection: connection)
        guard !home.isEmpty else {
            throw FileExplorerError.sshCommandFailed("remote HOME was empty")
        }
        return home
    }

    func listDirectory(path: String, showHidden: Bool) async throws -> [FileExplorerEntry] {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        return try await transport.listDirectory(path: path, connection: connection, showHidden: showHidden)
    }

    func downloadFile(path: String, to localURL: URL) async throws {
        guard isAvailable else {
            throw FileExplorerError.providerUnavailable
        }
        try await transport.downloadFile(path: path, connection: connection, to: localURL)
    }
}

final class ProcessSSHFileExplorerTransport: SSHFileExplorerTransport {
    static let shared = ProcessSSHFileExplorerTransport()

    nonisolated func resolveHomePath(connection: SSHFileExplorerConnection) async throws -> String {
        let output = try await Self.runSSHCommand(
            connection: connection,
            command: #"printf '%s\n' "$HOME""#
        )
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated func listDirectory(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        try await Self.runSSHListCommand(path: path, connection: connection, showHidden: showHidden)
    }

    nonisolated func downloadFile(
        path: String,
        connection: SSHFileExplorerConnection,
        to localURL: URL
    ) async throws {
        let escapedPath = Self.remoteShellPathWord(path)
        let outputURL = localURL
        let commandProcess = SSHDownloadCommandProcess(
            connection: connection,
            command: "test -f \(escapedPath) && cat -- \(escapedPath)",
            outputURL: outputURL
        )
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }
        guard result.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: outputURL)
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
    }

    private struct SSHCommandResult: Sendable {
        let stdout: String
        let stderr: String
        let terminationStatus: Int32
    }

    // Keeps the child process reachable from the cancellation handler while
    // the blocking wait runs off Swift's cooperative executor.
    private final class SSHCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let lock = NSLock()
        private var terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String) {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            do {
                try process.run()
            } catch {
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            let data = outPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: String(data: data, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private final class SSHDownloadCommandProcess: @unchecked Sendable {
        private let process = Process()
        private let outPipe = Pipe()
        private let errPipe = Pipe()
        private let outputURL: URL
        private let lock = NSLock()
        private var terminationGate = ProcessTerminationGate()
        private var cancelled = false

        init(connection: SSHFileExplorerConnection, command: String, outputURL: URL) {
            self.outputURL = outputURL
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ProcessSSHFileExplorerTransport.sshArguments(connection: connection, command: command)
            process.standardOutput = outPipe
            process.standardError = errPipe
        }

        func run() throws -> SSHCommandResult {
            lock.lock()
            let wasCancelled = cancelled
            lock.unlock()
            if wasCancelled {
                throw CancellationError()
            }

            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            FileManager.default.createFile(atPath: outputURL.path, contents: nil)
            let outputHandle = try FileHandle(forWritingTo: outputURL)
            defer { try? outputHandle.close() }

            do {
                try process.run()
            } catch {
                lock.lock()
                terminationGate.markFinished()
                lock.unlock()
                throw error
            }

            lock.lock()
            let shouldTerminate = cancelled
            let shouldTerminateDeferredRequest = terminationGate.markLaunched()
            lock.unlock()
            if shouldTerminateDeferredRequest || shouldTerminate {
                guard process.isRunning else {
                    process.waitUntilExit()
                    lock.lock()
                    terminationGate.markFinished()
                    lock.unlock()
                    throw CancellationError()
                }
                process.terminate()
            }

            try outPipe.fileHandleForReading.copyDataToEndOfFile(to: outputHandle)
            let stderrData = errPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
            process.waitUntilExit()
            lock.lock()
            terminationGate.markFinished()
            let cancelledAfterExit = cancelled
            lock.unlock()
            if cancelledAfterExit {
                throw CancellationError()
            }

            return SSHCommandResult(
                stdout: "",
                stderr: String(data: stderrData, encoding: .utf8) ?? "",
                terminationStatus: process.terminationStatus
            )
        }

        func terminate() {
            lock.lock()
            cancelled = true
            let shouldTerminate = terminationGate.requestTermination()
            lock.unlock()

            guard shouldTerminate else {
                return
            }
            guard process.isRunning else {
                return
            }
            process.terminate()
        }
    }

    private static func runSSHCommand(connection: SSHFileExplorerConnection, command: String) async throws -> String {
        let commandProcess = SSHCommandProcess(connection: connection, command: command)
        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result { try commandProcess.run() })
                }
            }
        } onCancel: {
            commandProcess.terminate()
        }

        guard result.terminationStatus == 0 else {
            throw FileExplorerError.sshCommandFailed(result.stderr)
        }
        return result.stdout
    }

    private static func sshArguments(connection: SSHFileExplorerConnection, command: String) -> [String] {
        var args: [String] = SSHHostConfiguredRemoteCommand().overrideArguments
        if let port = connection.port {
            args += ["-p", String(port)]
        }
        if let identityFile = connection.identityFile {
            args += ["-i", identityFile]
        }
        for option in connection.sshOptions {
            args += ["-o", option]
        }
        // Batch mode, no TTY, connection timeout
        args += ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T"]
        // Forwarding stays as configured: without `ControlMaster=no` this run
        // can become the shared master that interactive sessions reuse.
        args += ["--", connection.destination, command]
        return args
    }

    private static func runSSHListCommand(
        path: String,
        connection: SSHFileExplorerConnection,
        showHidden: Bool
    ) async throws -> [FileExplorerEntry] {
        let escapedPath = remoteShellPathWord(path)
        let lsFlags = showHidden ? "-1paFA" : "-1paF"
        let output = try await runSSHCommand(
            connection: connection,
            command: "ls \(lsFlags) \(escapedPath) 2>/dev/null"
        )

        let normalizedPath = path.hasSuffix("/") ? path : path + "/"
        return output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let entry = String(line)
            // Skip . and .. entries
            guard entry != "./" && entry != "../" else { return nil }
            let isDir = entry.hasSuffix("/")
            let name = isDir ? String(entry.dropLast()) : entry
            guard showHidden || !name.hasPrefix(".") else { return nil }
            // Strip type indicators from -F flag (*, @, =, |) for files
            let cleanName: String
            if !isDir, let last = name.last, "*@=|".contains(last) {
                cleanName = String(name.dropLast())
            } else {
                cleanName = name
            }
            let fullPath = normalizedPath + cleanName
            return FileExplorerEntry(name: cleanName, path: fullPath, isDirectory: isDir)
        }
    }

    /// Shell word that expands to `path` on the remote host, byte for byte.
    ///
    /// `Process` passes arguments through `fileSystemRepresentation`, which
    /// decomposes them to NFD. Remote Linux filesystems usually store names in
    /// NFC and treat the two forms as different files, so a non-ASCII path must
    /// not appear literally in the ssh command. Such paths travel base64-encoded
    /// and are decoded by the remote shell.
    static func remoteShellPathWord(_ path: String) -> String {
        guard !path.unicodeScalars.allSatisfy(\.isASCII) else {
            return shellSingleQuote(path)
        }
        let encoded = shellSingleQuote(Data(path.utf8).base64EncodedString())
        // GNU coreutils and macOS accept --decode, BusyBox (Alpine) only -d;
        // -D is the older macOS short flag.
        let decode = ["--decode", "-d", "-D"]
            .map { "printf '%s' \(encoded) | base64 \($0) 2>/dev/null" }
            .joined(separator: " || ")
        return "\"$(\(decode))\""
    }

    private static func shellSingleQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

enum FileExplorerError: LocalizedError {
    case providerUnavailable
    case sshCommandFailed(String)
    case remoteCommandFailed(String)
    case previewCapacity
    case remoteFileTooLarge

    var errorDescription: String? {
        switch self {
        case .providerUnavailable:
            return String(localized: "fileExplorer.error.unavailable", defaultValue: "File explorer is not available")
        case .sshCommandFailed:
            return String(localized: "fileExplorer.error.sshFailed", defaultValue: "SSH command failed")
        case .previewCapacity:
            return String(localized: "fileExplorer.preview.capacity", defaultValue: "Close a remote file preview and try again.")
        case .remoteFileTooLarge:
            return String(localized: "fileExplorer.error.cloudPreviewTooLarge", defaultValue: "Remote file previews are limited to 1 MB.")
        case .remoteCommandFailed:
            return String(localized: "fileExplorer.error.remoteFailed", defaultValue: "Remote command failed")
        }
    }
}

// MARK: - Selection Restoration

enum FileExplorerSelectionRestoration {
    static func scrollRow(anchorRow: Int?, exactRows: IndexSet) -> Int? {
        if let anchorRow, exactRows.contains(anchorRow) {
            return anchorRow
        }
        return exactRows.first
    }
}

// MARK: - Store

/// Main-actor store for file-explorer presentation and loading state.
@MainActor
final class FileExplorerStore: ObservableObject {
    @Published var rootPath: String = ""
    @Published var rootNodes: [FileExplorerNode] = []
    @Published private(set) var isRootLoading: Bool = false
    @Published private(set) var gitStatusByPath: [String: GitFileStatus] = [:]
    /// Structural child-list diffs from watcher refreshes, waiting for the outline view to apply them.
    private var pendingStructuralChanges: [FileExplorerStructuralChange] = []
    /// Paths whose git status changed since the view last drained them.
    private var pendingGitChangedPaths: Set<String> = []
    /// Number of watcher refreshes that listed the tree and found a change (diagnostics and tests).
    private(set) var incrementalRefreshCount = 0
    @Published private(set) var contentRevision = 0
    @Published private(set) var rootStatusMessage: String?
    private(set) var workspaceRootIdentity: UUID?

    var provider: FileExplorerProvider?

    static let showHiddenFilesDefaultsKey = "fileExplorer.showHidden"
    static let showHiddenFilesDidChange = Notification.Name("cmux.fileExplorer.showHiddenFilesDidChange")

    /// Whether hidden files are shown. Persisted, default off; every store follows `toggleShowHiddenFiles()`.
    private(set) var showHiddenFiles: Bool = UserDefaults.standard.bool(forKey: FileExplorerStore.showHiddenFilesDefaultsKey)
    private var showHiddenObserver: AnyCancellable?

    /// Flips and persists the hidden-files filter, then reloads this store and every sibling store.
    /// Expansion and selection are path-based, so the tree comes back as it was.
    func toggleShowHiddenFiles() {
        showHiddenFiles.toggle()
        UserDefaults.standard.set(showHiddenFiles, forKey: Self.showHiddenFilesDefaultsKey)
        reload()
        NotificationCenter.default.post(name: Self.showHiddenFilesDidChange, object: self)
    }

    /// Watches the root directory for filesystem changes (local only).
    private var directoryWatcher: FileWatcher?
    private var directoryWatchTask: Task<Void, Never>?
    private var directoryWatchPath: String?
    private var refreshCoalescer = FileExplorerRefreshCoalescer()
    private var refreshTimerTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var gitRefreshTrailingTask: Task<Void, Never>?
    private var lastGitRefreshAt: TimeInterval = 0
    /// Minimum spacing between watcher-driven `git status` runs.
    private static let gitRefreshMinInterval: TimeInterval = 2
    /// False while the Files view is hidden, off screen or its window is not visible: the watcher is
    /// released and the tree is resynced once when it becomes visible again.
    private(set) var isViewportVisible = true
    private var needsResyncOnVisible = false

    /// Paths that are logically expanded (persisted across provider changes)
    private(set) var expandedPaths: Set<String> = [] { didSet { if oldValue != expandedPaths { scheduleNavigationPersist() } } }

    /// Stable navigation selection. The outline view mirrors this path after reloads.
    private(set) var selectedPath: String? { didSet { if oldValue != selectedPath { breadcrumbOverridePath = nil; scheduleNavigationPersist() } } }

    /// Set only by a user chevron/keyboard expand or collapse; cleared on any selection
    /// assignment and workspace switch. Takes precedence over the selection-derived breadcrumb.
    var breadcrumbOverridePath: String?

    /// Stable multi-selection. `selectedPath` remains the keyboard/navigation anchor.
    private(set) var selectedPaths: Set<String> = []

    /// Folder path whose first child should be selected once its async load completes.
    private var pendingDescendIntoFirstChildPath: String?

    /// Paths currently being loaded
    private(set) var loadingPaths: Set<String> = []

    /// In-flight load tasks keyed by path
    private var loadTasks: [String: Task<Void, Never>] = [:]

    /// Cache of path -> node for quick lookup
    private(set) var nodesByPath: [String: FileExplorerNode] = [:]

    /// Prefetch debounce schedulers keyed by path.
    private var prefetchSchedulers: [String: MainActorDeferredActionScheduler] = [:]

    var workspaceRootObservation: FileExplorerWorkspaceObservation?
    var remoteHomeResolutionTask: Task<Void, Never>?
    var remoteHomeResolutionKey: String?
    private(set) var resourceContextID = UUID()
    let remotePreviewCache = RemoteFilePreviewCache()

    private let gitStatusProvider: GitStatusProvider
    private var gitStatusGeneration: UInt64 = 0

    init(
        gitStatusProvider: GitStatusProvider = GitStatusProvider(),
        navigationFileURL: URL? = FileExplorerNavigationStorage.defaultFileURL()
    ) {
        self.gitStatusProvider = gitStatusProvider
        self.navigationFileURL = navigationFileURL
        showHiddenObserver = NotificationCenter.default.publisher(for: Self.showHiddenFilesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] note in
                guard let self, note.object as AnyObject? !== self else { return }
                showHiddenFiles = UserDefaults.standard.bool(forKey: Self.showHiddenFilesDefaultsKey)
                reload()
            }
    }

    /// Directory shown by the header breadcrumb: the selected folder, the selected
    /// file's parent, or the root when nothing (known) is selected.
    var breadcrumbPath: String {
        if let override = breadcrumbOverridePath, Self.path(override, isContainedIn: rootPath) { return override }
        guard let selectedPath, Self.path(selectedPath, isContainedIn: rootPath),
              let node = nodesByPath[selectedPath] else { return rootPath }
        return node.isDirectory ? selectedPath : (selectedPath as NSString).deletingLastPathComponent
    }

    var displayRootPath: String {
        if let sshProvider = provider as? SSHFileExplorerProvider {
            guard !rootPath.isEmpty else {
                return "ssh://\(sshProvider.displayTarget)"
            }
            return "ssh://\(sshProvider.displayTarget):\(rootPath)"
        }
        return FileExplorerRootResolver.displayPath(for: rootPath, homePath: provider?.homePath)
    }

    // MARK: - Public API

    struct WorkspaceNavigation: Codable, Equatable {
        var workspaceRoot: String, rootPath: String, expandedPaths: Set<String>
        var selectedPath: String?, selectedPaths: Set<String>
        /// Seconds since 1970; orders the persisted LRU cap.
        var touched: TimeInterval = 0

        /// Drops saved paths that no longer exist (stat only the saved paths); nil if the workspace root is gone.
        func pruned(exists: (String) -> Bool) -> WorkspaceNavigation? {
            guard exists(workspaceRoot) else { return nil }
            var copy = self
            if !exists(rootPath) { copy.rootPath = workspaceRoot }
            copy.expandedPaths = expandedPaths.filter(exists)
            copy.selectedPaths = selectedPaths.filter(exists)
            if let selectedPath, !exists(selectedPath) { copy.selectedPath = nil }
            return copy
        }
    }
    // Local workspaces only; persisted to `navigationFileURL` (debounced) so it survives a restart.
    private var navigationByWorkspace: [UUID: WorkspaceNavigation] = [:]
    private let navigationFileURL: URL?
    private var navigationLoadedFromDisk = false
    private let navigationPersistScheduler = MainActorDeferredActionScheduler()

    private func scheduleNavigationPersist() {
        guard navigationFileURL != nil else { return }
        navigationPersistScheduler.schedule(after: .seconds(1)) { [weak self] in self?.persistNavigation() }
    }

    private func persistNavigation() {
        guard let url = navigationFileURL else { return }
        var mine = navigationByWorkspace
        if let id = workspaceRootIdentity, provider is LocalFileExplorerProvider, !rootPath.isEmpty, !workspaceRootPath.isEmpty {
            mine[id] = WorkspaceNavigation(
                workspaceRoot: workspaceRootPath, rootPath: rootPath, expandedPaths: expandedPaths,
                selectedPath: selectedPath, selectedPaths: selectedPaths, touched: Date().timeIntervalSince1970)
        }
        guard !mine.isEmpty else { return }
        // Merge with the file: other windows' stores write the same file.
        var merged = FileExplorerNavigationStorage.read(url)
        for (id, nav) in mine where nav.touched >= (merged[id]?.touched ?? 0) { merged[id] = nav }
        FileExplorerNavigationStorage.write(FileExplorerNavigationStorage.capped(merged), to: url)
    }

    private func loadPersistedNavigationIfNeeded() {
        guard !navigationLoadedFromDisk, let url = navigationFileURL else { return }
        navigationLoadedFromDisk = true
        for (id, nav) in FileExplorerNavigationStorage.read(url) where navigationByWorkspace[id] == nil {
            navigationByWorkspace[id] = nav
        }
    }

    /// Workspace-derived root last applied, as opposed to a root the user navigated to.
    private var workspaceRootPath = ""

    func applyWorkspaceRoot(
        _ request: FileExplorerWorkspaceRoot,
        sshTransport: SSHFileExplorerTransport = ProcessSSHFileExplorerTransport.shared
    ) {
        switch request {
        case .none:
            workspaceRootObservation?.stop(); workspaceRootObservation = nil
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(nil)
            if provider != nil { setProvider(nil, reloadIfAvailable: false) }
            setRootPath("")
        case .local(let workspaceId, let path):
            cancelRemoteHomeResolution(); setRootStatusMessage(nil); setWorkspaceRootIdentity(workspaceId)
            if !(provider is LocalFileExplorerProvider) {
                setRootPath("")
                setProvider(LocalFileExplorerProvider(), reloadIfAvailable: false)
            }
            loadPersistedNavigationIfNeeded()
            if let saved = navigationByWorkspace.removeValue(forKey: workspaceId),
               saved.workspaceRoot == path,
               let saved = saved.pruned(exists: { FileManager.default.fileExists(atPath: $0) }) {
                // Do not re-open TCC-protected folders at launch; the user expands them again on demand.
                expandedPaths = saved.expandedPaths.filter { !BlockingFileSystem.isTCCProtectedPath($0) }
                selectedPath = saved.selectedPath
                selectedPaths = saved.selectedPaths
                setRootPath(saved.rootPath)
            } else {
                setRootPath(path)
            }
            workspaceRootPath = path
        case .remoteSSH(let workspaceId, let connection, let displayTarget, let rootPath, let isAvailable, let unavailableDetail):
            applyRemoteSSHWorkspaceRoot(
                workspaceId: workspaceId,
                connection: connection,
                displayTarget: displayTarget,
                rootPath: rootPath,
                isAvailable: isAvailable,
                unavailableDetail: unavailableDetail,
                sshTransport: sshTransport
            )
        }
    }
    func setWorkspaceRootIdentity(_ identity: UUID?) {
        guard workspaceRootIdentity != identity else { return }
        if let old = workspaceRootIdentity, provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            navigationByWorkspace[old] = WorkspaceNavigation(
                workspaceRoot: workspaceRootPath, rootPath: rootPath, expandedPaths: expandedPaths,
                selectedPath: selectedPath, selectedPaths: selectedPaths, touched: Date().timeIntervalSince1970)
        }
        workspaceRootIdentity = identity
        breadcrumbOverridePath = nil
        resetResourceContext()
        rootPath = ""
        updateDirectoryWatcher()
    }

    /// True when the user re-rooted the Files tree away from the workspace directory (local only).
    var isRootOverridden: Bool {
        provider is LocalFileExplorerProvider && !workspaceRootPath.isEmpty && rootPath != workspaceRootPath
    }

    func resetRootToWorkspace() {
        if isRootOverridden { setRootPath(workspaceRootPath) }
    }

    /// Selects `path` even before its node has loaded; the outline mirrors it after the next reload.
    func selectPath(_ path: String) {
        selectedPath = path
        selectedPaths = [path]
    }

    /// Selects several paths (results of a paste or move); the first becomes the primary selection.
    func selectPaths(_ paths: [String]) {
        guard let first = paths.first else { return }
        selectedPath = first
        selectedPaths = Set(paths)
    }

    func setRootStatusMessage(_ message: String?) {
        guard rootStatusMessage != message else { return }
        rootStatusMessage = message
    }

    private func resetResourceContext(preservingNavigation: Bool = false) {
        resourceContextID = UUID()
        cancelRemoteHomeResolution()
        cancelAllLoads()
        if !preservingNavigation {
            selectedPath = nil; selectedPaths = []; expandedPaths = []
        }
        rootNodes = []; nodesByPath = [:]; gitStatusByPath = [:]
        contentRevision &+= 1
    }

    func setRootPath(_ path: String) {
        guard path != rootPath else {
            #if DEBUG
            NSLog("[FileExplorer] setRootPath skipped (same path): \(path)")
            #endif
            return
        }
        #if DEBUG
        NSLog("[FileExplorer] setRootPath: \(rootPath) -> \(path)")
        #endif
        if let selectedPath, !Self.path(selectedPath, isContainedIn: path) {
            self.selectedPath = nil
            selectedPaths = []
            pendingDescendIntoFirstChildPath = nil
        }
        resourceContextID = UUID()
        rootPath = path
        reload()
        refreshGitStatus()
        updateDirectoryWatcher()
    }

    func refreshGitStatus() {
        gitStatusGeneration &+= 1
        let generation = gitStatusGeneration, path = rootPath
        let context = resourceContextID, source = gitStatusProvider
        guard !path.isEmpty, provider?.isAvailable == true,
              provider is LocalFileExplorerProvider || provider is SSHFileExplorerProvider else {
            applyGitStatus([:])
            return
        }
        let connection = (provider as? SSHFileExplorerProvider)?.connection
        Task { [weak self] in
            let status = await BlockingFileSystem.run {
                if let connection {
                    return source.fetchStatusSSH(directory: path, destination: connection.destination,
                        port: connection.port, identityFile: connection.identityFile, sshOptions: connection.sshOptions)
                }
                return source.fetchStatus(directory: path)
            }
            guard let self, self.gitStatusGeneration == generation, self.resourceContextID == context else { return }
            self.applyGitStatus(status)
        }
    }

    /// Publishes only when the status map actually changed, and remembers which rows to refresh.
    private func applyGitStatus(_ status: [String: GitFileStatus]) {
        guard status != gitStatusByPath else { return }
        for (path, value) in status where gitStatusByPath[path] != value { pendingGitChangedPaths.insert(path) }
        for path in gitStatusByPath.keys where status[path] == nil { pendingGitChangedPaths.insert(path) }
        if pendingGitChangedPaths.count > 500 { pendingGitChangedPaths = []; contentRevision &+= 1 }
        gitStatusByPath = status
    }

    func materializeRemoteFileForPreview(
        path: String,
        expectedWorkspaceRootIdentity: UUID? = nil
    ) async throws -> URL {
        // `DisableFileTransfer` (MDM): a preview copies the file off the remote
        // host onto this Mac, which is a cmux-mediated download.
        guard !ManagedFileTransferPolicy.isDisabled else {
            throw ManagedFileTransferPolicy.refusalError()
        }
        guard expectedWorkspaceRootIdentity == nil || workspaceRootIdentity == expectedWorkspaceRootIdentity,
              let remoteProvider = provider as? SSHFileExplorerProvider else {
            throw FileExplorerError.providerUnavailable
        }
        let cacheURL = Self.remotePreviewCacheURL(
            displayTarget: remoteProvider.displayTarget,
            remotePath: path
        )
        try await remoteProvider.downloadFile(path: path, to: cacheURL)
        guard expectedWorkspaceRootIdentity == nil ||
              (workspaceRootIdentity == expectedWorkspaceRootIdentity && provider === remoteProvider) else {
            try? FileManager.default.removeItem(at: cacheURL)
            throw FileExplorerError.providerUnavailable
        }
        return cacheURL
    }

    #if DEBUG
    /// TEMPORARY A/B switch for measurement (BREE_FE_LEGACY=1): the pre-change watcher behaviour.
    static let legacyReloadMode = ProcessInfo.processInfo.environment["BREE_FE_LEGACY"] == "1"
    #endif

    private func updateDirectoryWatcher() {
        #if DEBUG
        if Self.legacyReloadMode, provider is LocalFileExplorerProvider, !rootPath.isEmpty {
            guard directoryWatchPath != rootPath || directoryWatcher == nil else { return }
            stopDirectoryWatcher()
            let watcher = FileWatcher(path: rootPath, throttle: .milliseconds(300))
            directoryWatcher = watcher
            directoryWatchPath = rootPath
            let events = watcher.events
            directoryWatchTask = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.reload()
                    self.refreshGitStatus()
                }
            }
            return
        }
        #endif
        if provider is LocalFileExplorerProvider, !rootPath.isEmpty, isViewportVisible {
            guard directoryWatchPath != rootPath || directoryWatcher == nil else { return }
            stopDirectoryWatcher()
            // No watcher-side throttle: bursts are debounced (with a cap) by `refreshCoalescer`.
            let watcher = FileWatcher(path: rootPath)
            directoryWatcher = watcher
            directoryWatchPath = rootPath
            let events = watcher.events
            directoryWatchTask = Task { @MainActor [weak self] in
                for await _ in events {
                    guard let self else { break }
                    self.watcherEventArrived()
                }
            }
        } else {
            stopDirectoryWatcher()
        }
    }

    /// Cancels the directory-watch consumer and drops the watcher; the watcher's
    /// deinit cancels its `DispatchSource`s synchronously.
    private func stopDirectoryWatcher() {
        directoryWatchTask?.cancel()
        directoryWatchTask = nil
        directoryWatcher = nil
        directoryWatchPath = nil
        refreshTimerTask?.cancel()
        refreshTimerTask = nil
        refreshCoalescer.reset()
    }

    /// Called by the Files view when it becomes (in)visible. Hidden: release the watcher and drop
    /// pending work. Visible again: re-attach and resync once.
    func setViewportVisible(_ visible: Bool) {
        guard visible != isViewportVisible else { return }
        isViewportVisible = visible
        #if DEBUG
        dlog("file.explorer.viewport visible=\(visible ? 1 : 0) root=\(rootPath)")
        #endif
        if visible {
            updateDirectoryWatcher()
            if needsResyncOnVisible {
                needsResyncOnVisible = false
                refreshInPlace()
                refreshGitStatus()
            }
        } else {
            refreshTask?.cancel()
            refreshTask = nil
            gitRefreshTrailingTask?.cancel()
            gitRefreshTrailingTask = nil
            if directoryWatcher != nil { needsResyncOnVisible = true }
            stopDirectoryWatcher()
        }
    }

    private static func monotonicNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func watcherEventArrived() {
        #if DEBUG
        dlog("file.explorer.watch.event visible=\(isViewportVisible ? 1 : 0)")
        #endif
        guard isViewportVisible else { needsResyncOnVisible = true; return }
        refreshCoalescer.noteEvent(at: Self.monotonicNow())
        armRefreshTimer()
    }

    private func armRefreshTimer() {
        guard let deadline = refreshCoalescer.deadline else { return }
        refreshTimerTask?.cancel()
        let delay = max(0, deadline - Self.monotonicNow())
        refreshTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.refreshCoalescer.didFire()
            #if DEBUG
            dlog("file.explorer.watch.fire provider=\(type(of: self.provider)) root=\(self.rootPath)")
            #endif
            self.refreshInPlace()
            self.scheduleGitRefresh()
        }
    }

    /// `git status` is a process spawn: run at most once per `gitRefreshMinInterval`, with one trailing run.
    private func scheduleGitRefresh() {
        let now = Self.monotonicNow()
        let wait = lastGitRefreshAt + Self.gitRefreshMinInterval - now
        if wait <= 0 {
            lastGitRefreshAt = now
            refreshGitStatus()
        } else if gitRefreshTrailingTask == nil {
            gitRefreshTrailingTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.gitRefreshTrailingTask = nil
                self.lastGitRefreshAt = Self.monotonicNow()
                self.refreshGitStatus()
            }
        }
    }

    /// Re-lists the root and every expanded, loaded folder, merging the results into the existing
    /// nodes. Unchanged listings publish nothing; changed ones queue index-level diffs for the view.
    func refreshInPlace() {
        guard provider is LocalFileExplorerProvider, !rootPath.isEmpty, isViewportVisible else { return }
        refreshTask?.cancel()
        let context = resourceContextID
        refreshTask = Task { @MainActor [weak self] in
            await self?.runIncrementalRefresh(context: context)
        }
    }

    private func runIncrementalRefresh(context: UUID) async {
        var queue: [(parent: FileExplorerNode?, path: String)] = [(nil, rootPath)]
        var changed = false
        while !queue.isEmpty {
            let (parent, path) = queue.removeFirst()
            guard !Task.isCancelled, context == resourceContextID, let provider else { return }
            if loadingPaths.contains(path) || (parent == nil && isRootLoading) {
                #if DEBUG
                dlog("file.explorer.refresh.skip loading path=\(path)")
                #endif
                continue
            }
            guard let entries = try? await provider.listDirectory(path: path, showHidden: showHiddenFiles) else { continue }
            guard !Task.isCancelled, context == resourceContextID else { return }
            if let parent, nodesByPath[parent.path] !== parent || parent.children == nil { continue }
            if parent == nil, path != rootPath { return }
            let existing = parent?.children ?? rootNodes
            let result = FileExplorerListingMerge.merge(existing: existing, entries: entries) { entry in
                let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
                node.resourceContextID = context
                return node
            }
            if !result.isEmpty {
                changed = true
                for removed in result.removedNodes { forgetSubtree(removed) }
                for inserted in result.insertedNodes { nodesByPath[inserted.path] = inserted }
                if let parent { parent.children = result.children } else { rootNodes = result.children }
                if pendingStructuralChanges.count >= 64 {
                    // The view is not draining (hidden or busy): fall back to one full reload.
                    pendingStructuralChanges = []
                    contentRevision &+= 1
                } else {
                    pendingStructuralChanges.append(FileExplorerStructuralChange(
                        parentPath: parent?.path, removed: result.removedIndexes, inserted: result.insertedIndexes))
                }
                objectWillChange.send()
                // A re-created folder that was expanded before loads its children again.
                for inserted in result.insertedNodes where inserted.isDirectory && expandedPaths.contains(inserted.path) {
                    inserted.isLoading = true
                    let childPath = inserted.path
                    loadTasks[childPath] = Task { [weak self] in
                        await self?.loadChildren(for: inserted, at: childPath)
                    }
                }
            }
            for child in result.children where child.isDirectory && child.children != nil && expandedPaths.contains(child.path) {
                queue.append((child, child.path))
            }
        }
        if changed {
            incrementalRefreshCount += 1
            #if DEBUG
            dlog("file.explorer.refresh.changed n=\(incrementalRefreshCount) rows=\(rootNodes.count)")
            #endif
        }
    }

    private func forgetSubtree(_ node: FileExplorerNode) {
        nodesByPath.removeValue(forKey: node.path)
        loadTasks.removeValue(forKey: node.path)?.cancel()
        loadingPaths.remove(node.path)
        for child in node.children ?? [] { forgetSubtree(child) }
    }

    /// Drains the diffs queued by `refreshInPlace` (view side).
    func takePendingStructuralChanges() -> [FileExplorerStructuralChange] {
        defer { pendingStructuralChanges = [] }
        return pendingStructuralChanges
    }

    /// Drains the paths whose git status changed (view side).
    func takePendingGitChangedPaths() -> Set<String> {
        defer { pendingGitChangedPaths = [] }
        return pendingGitChangedPaths
    }

    func setProvider(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        #if DEBUG
        NSLog("[FileExplorer] setProvider: \(type(of: newProvider).self) available=\(newProvider?.isAvailable ?? false)")
        #endif
        let providerChanged: Bool
        switch (provider, newProvider) {
        case let (current?, next?): providerChanged = current !== next
        case (nil, nil): providerChanged = false
        default: providerChanged = true
        }
        if providerChanged { resetResourceContext(preservingNavigation: true) }
        provider = newProvider
        // Re-expand previously expanded nodes if provider becomes available
        if reloadIfAvailable, newProvider?.isAvailable == true {
            reload()
        }
    }

    #if DEBUG
    func setProviderForTesting(_ newProvider: FileExplorerProvider?, reloadIfAvailable: Bool = true) {
        setProvider(newProvider, reloadIfAvailable: reloadIfAvailable)
    }
    #endif

    func reload() {
        #if DEBUG
        NSLog("[FileExplorer] reload() path=\(rootPath) provider=\(type(of: provider).self)")
        #endif
        contentRevision &+= 1
        #if DEBUG
        dlog("file.explorer.reload.full rev=\(contentRevision)")
        #endif
        cancelAllLoads()
        refreshTask?.cancel()
        pendingStructuralChanges = []
        rootNodes = []
        nodesByPath = [:]
        guard !rootPath.isEmpty, provider != nil else { return }
        isRootLoading = true
        let path = rootPath
        let task = Task { [weak self] in
            guard let self else { return }
            await self.loadChildren(for: nil, at: path)
        }
        loadTasks[rootPath] = task
    }

    func expand(node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        expandedPaths.insert(node.path)
        if node.children == nil, loadTasks[node.path] == nil, !loadingPaths.contains(node.path) {
            node.isLoading = true
            node.error = nil
            objectWillChange.send()
            let nodePath = node.path
            let task = Task { [weak self] in
                guard let self else { return }
                await self.loadChildren(for: node, at: nodePath)
            }
            loadTasks[node.path] = task
        }
    }

    func collapse(node: FileExplorerNode) {
        expandedPaths.remove(node.path)
        if pendingDescendIntoFirstChildPath == node.path {
            pendingDescendIntoFirstChildPath = nil
        }
        objectWillChange.send()
    }

    /// Breadcrumb after the user collapses `path`: its parent when the breadcrumb sits inside it.
    func breadcrumbPath(afterCollapsing path: String) -> String? {
        let current = breadcrumbPath
        guard current == path || current.hasPrefix(path + "/") else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        return Self.path(parent, isContainedIn: rootPath) ? parent : rootPath
    }

    func isExpanded(_ node: FileExplorerNode) -> Bool {
        expandedPaths.contains(node.path)
    }

    func select(node: FileExplorerNode?) {
        let path = node?.path
        let paths = path.map { Set([$0]) } ?? []
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func select(nodes: [FileExplorerNode], anchor: FileExplorerNode?) {
        let paths = Set(nodes.map(\.path))
        let path = anchor?.path ?? nodes.first?.path
        guard selectedPath != path || selectedPaths != paths else { return }
        selectedPath = path
        selectedPaths = paths
        if path != pendingDescendIntoFirstChildPath {
            pendingDescendIntoFirstChildPath = nil
        }
    }

    func requestDescendIntoFirstChild(of node: FileExplorerNode) {
        guard node.resourceContextID == nil || node.resourceContextID == resourceContextID, node.isDirectory else { return }
        selectedPath = node.path
        selectedPaths = [node.path]
        pendingDescendIntoFirstChildPath = node.path
        expand(node: node)
    }

    /// Hover prefetch is intentionally a no-op: listing unexpanded folders on hover opened
    /// TCC-protected folders (Desktop, Documents, ...) and blocked threads. Only a user expand lists a folder.
    func prefetchChildren(for node: FileExplorerNode) {}

    func cancelPrefetch(for node: FileExplorerNode) {}

    /// Called when SSH provider becomes available after being unavailable.
    /// Re-hydrates expanded nodes that were waiting.
    func hydrateExpandedNodes() {
        guard let provider, provider.isAvailable, !expandedPaths.isEmpty else { return }
        #if DEBUG
        NSLog("[FileExplorer] hydrateExpandedNodes: \(expandedPaths.count) paths to hydrate")
        #endif
        reload()
    }

    // MARK: - Private

    @MainActor
    private func loadChildren(for parentNode: FileExplorerNode?, at path: String, silent: Bool = false) async {
        guard parentNode?.resourceContextID == nil || parentNode?.resourceContextID == resourceContextID else { return }
        // A load cancelled by cancelAllLoads (e.g. a root reload during an SSH provider swap) must not
        // reach provider.listDirectory: the provider may have been replaced, so a stale in-flight load
        // would list the old path through the new transport. Bail before any listing.
        guard !Task.isCancelled else { return }
        guard let provider else { return }

        if !silent {
            loadingPaths.insert(path)
            parentNode?.error = nil
            objectWillChange.send()
        }

        do {
            let entries = try await provider.listDirectory(path: path, showHidden: showHiddenFiles)
            try Task.checkCancellation()
            let children = entries.map { entry in
                let node = FileExplorerNode(name: entry.name, path: entry.path, isDirectory: entry.isDirectory)
                node.resourceContextID = resourceContextID
                nodesByPath[entry.path] = node
                return node
            }.sorted(by: FileExplorerListingMerge.precedes)

            if let parentNode {
                parentNode.children = children
                parentNode.isLoading = false
                parentNode.error = nil
                if pendingDescendIntoFirstChildPath == parentNode.path {
                    let path = children.first?.path ?? parentNode.path
                    selectedPath = path
                    selectedPaths = [path]
                    pendingDescendIntoFirstChildPath = nil
                }
            } else {
                rootNodes = children
                isRootLoading = false
                setRootStatusMessage(nil)
                if selectedPath == nil {
                    selectedPath = children.first?.path
                    selectedPaths = selectedPath.map { Set([$0]) } ?? []
                }
            }
            loadingPaths.remove(path)
            loadTasks.removeValue(forKey: path)
            objectWillChange.send()

            // Auto-expand children that were previously expanded
            for child in children where child.isDirectory && expandedPaths.contains(child.path) {
                child.isLoading = true
                objectWillChange.send()
                let childPath = child.path
                let childTask = Task { [weak self] in
                    guard let self else { return }
                    await self.loadChildren(for: child, at: childPath)
                }
                loadTasks[child.path] = childTask
            }
        } catch {
            if !Task.isCancelled {
                if let parentNode {
                    parentNode.isLoading = false
                    parentNode.error = error.localizedDescription
                } else {
                    isRootLoading = false
                    setRootStatusMessage(error.localizedDescription)
                }
                loadingPaths.remove(path)
                loadTasks.removeValue(forKey: path)
                objectWillChange.send()
            }
        }
    }

    private func cancelAllLoads() {
        for (_, task) in loadTasks {
            task.cancel()
        }
        loadTasks.removeAll()
        loadingPaths.removeAll()
        pendingDescendIntoFirstChildPath = nil
        for scheduler in prefetchSchedulers.values {
            scheduler.cancel()
        }
        prefetchSchedulers.removeAll()
        isRootLoading = false
    }

    private static func remotePreviewCacheURL(displayTarget: String, remotePath: String) -> URL {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-remote-file-previews", isDirectory: true)
        let target = sanitizedCacheComponent(displayTarget)
        let remote = sanitizedCacheComponent(remotePath)
        let basename = URL(fileURLWithPath: remotePath).lastPathComponent
        let filename = basename.isEmpty ? remote : "\(remote)-\(basename)"
        return cacheRoot
            .appendingPathComponent(target, isDirectory: true)
            .appendingPathComponent(filename, isDirectory: false)
    }

    private static func sanitizedCacheComponent(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let candidate = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return candidate.isEmpty ? UUID().uuidString : String(candidate.prefix(160))
    }

    deinit {
        remoteHomeResolutionTask?.cancel()
        directoryWatchTask?.cancel()
        refreshTimerTask?.cancel()
        refreshTask?.cancel()
        gitRefreshTrailingTask?.cancel()
    }
}

/// JSON file behind the per-workspace Files navigation (expansion, selection, root override).
enum FileExplorerNavigationStorage {
    static let maxEntries = 200

    nonisolated static func defaultFileURL(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        isRunningUnderAutomatedTests: Bool = SessionRestorePolicy.isRunningUnderAutomatedTests()
    ) -> URL? {
        guard !isRunningUnderAutomatedTests,
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let id = (bundleIdentifier?.isEmpty == false ? bundleIdentifier! : "com.cmuxterm.app")
            .replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        return base.appendingPathComponent(CmuxIdentity.current.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("file-explorer-navigation-\(id).json", isDirectory: false)
    }

    /// Keeps the `maxEntries` most recently touched entries.
    static func capped(_ entries: [UUID: FileExplorerStore.WorkspaceNavigation]) -> [UUID: FileExplorerStore.WorkspaceNavigation] {
        guard entries.count > maxEntries else { return entries }
        let keep = entries.sorted { $0.value.touched > $1.value.touched }.prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }

    static func encode(_ entries: [UUID: FileExplorerStore.WorkspaceNavigation]) -> Data? {
        try? JSONEncoder().encode(Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) }))
    }

    /// Drops entries whose workspace root is gone; a corrupt file reads as empty.
    static func decode(_ data: Data, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [UUID: FileExplorerStore.WorkspaceNavigation] {
        guard let raw = try? JSONDecoder().decode([String: FileExplorerStore.WorkspaceNavigation].self, from: data) else { return [:] }
        var result: [UUID: FileExplorerStore.WorkspaceNavigation] = [:]
        for (key, nav) in raw {
            if let id = UUID(uuidString: key), exists(nav.workspaceRoot) { result[id] = nav }
        }
        return result
    }

    static func read(_ url: URL) -> [UUID: FileExplorerStore.WorkspaceNavigation] {
        (try? Data(contentsOf: url)).map { decode($0) } ?? [:]
    }

    static func write(_ entries: [UUID: FileExplorerStore.WorkspaceNavigation], to url: URL) {
        guard let data = encode(entries) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

/// Local file operations behind the explorer context menu. The naming and
/// validation helpers take the existence check as a parameter so tests stay pure.
enum FileExplorerFileOperations {
    enum RenameError: LocalizedError, Equatable {
        case empty, invalid, exists(String)

        var errorDescription: String? {
            switch self {
            case .empty:
                String(localized: "fileExplorer.rename.error.empty", defaultValue: "The name can't be empty.")
            case .invalid:
                String(localized: "fileExplorer.rename.error.invalid", defaultValue: "The name can't contain \"/\" or be \".\" or \"..\".")
            case .exists(let name):
                String(format: String(localized: "fileExplorer.rename.error.exists", defaultValue: "\"%@\" already exists in this folder."), name)
            }
        }
    }

    /// The destination path for renaming `oldPath` to `newName`, or the validation error.
    static func renameTarget(
        oldPath: String,
        newName: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> String {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RenameError.empty }
        guard !name.contains("/"), name != ".", name != ".." else { throw RenameError.invalid }
        let old = oldPath as NSString
        let target = (old.deletingLastPathComponent as NSString).appendingPathComponent(name)
        // A case-only rename targets the same file on a case-insensitive volume.
        if name.caseInsensitiveCompare(old.lastPathComponent) != .orderedSame, fileExists(target) {
            throw RenameError.exists(name)
        }
        return target
    }

    /// Finder-style duplicate name: "a copy.txt", then "a copy 2.txt", and so on.
    static func copyName(for name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        let ns = name as NSString
        let ext = isDirectory ? "" : ns.pathExtension
        let base = ext.isEmpty ? name : ns.deletingPathExtension
        let suffix = ext.isEmpty ? "" : "." + ext
        var n = 1
        while true {
            let candidate = base + " copy" + (n > 1 ? " \(n)" : "") + suffix
            if !isTaken(candidate) { return candidate }
            n += 1
        }
    }

    /// Copies `path` next to itself under a free "copy" name and returns the new path.
    @discardableResult
    static func duplicate(path: String, isDirectory: Bool) throws -> String {
        let ns = path as NSString
        let folder = ns.deletingLastPathComponent as NSString
        let name = copyName(for: ns.lastPathComponent, isDirectory: isDirectory) {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0))
        }
        let target = folder.appendingPathComponent(name)
        try FileManager.default.copyItem(atPath: path, toPath: target)
        return target
    }

    enum TransferError: LocalizedError, Equatable {
        case vaultReadOnly(String)
        case intoItself(String)
        case exists(String)

        var errorDescription: String? {
            switch self {
            case .vaultReadOnly(let name):
                String(format: String(localized: "fileExplorer.transfer.error.vault", defaultValue: "\"%@\" is in an Obsidian vault, which is read-only here."), name)
            case .intoItself(let name):
                String(format: String(localized: "fileExplorer.transfer.error.intoItself", defaultValue: "\"%@\" can't be placed inside itself."), name)
            case .exists(let name):
                String(format: String(localized: "fileExplorer.transfer.error.exists", defaultValue: "\"%@\" already exists in the destination folder."), name)
            }
        }
    }

    /// True when `path` sits inside an Obsidian vault (files there are never written by the explorer).
    static func isInsideVault(_ path: String) -> Bool {
        ObsidianVault.root(forFile: path) != nil
    }

    /// True when `path` is `folder` or lives below it.
    static func isSameOrDescendant(_ path: String, of folder: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let f = (folder as NSString).standardizingPath
        return p == f || p.hasPrefix(f.hasSuffix("/") ? f : f + "/")
    }

    /// Paste name: the original when free, otherwise the Finder-style "copy" name.
    static func pasteName(for name: String, isDirectory: Bool, isTaken: (String) -> Bool) -> String {
        isTaken(name) ? copyName(for: name, isDirectory: isDirectory, isTaken: isTaken) : name
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Copies `sources` into `folder`, renaming collisions with " copy" suffixes. Returns the new paths.
    @discardableResult
    static func paste(sources: [String], intoFolder folder: String) throws -> [String] {
        guard !isInsideVault(((folder as NSString).appendingPathComponent("x"))) else {
            throw TransferError.vaultReadOnly((folder as NSString).lastPathComponent)
        }
        var created: [String] = []
        for source in sources {
            let name = (source as NSString).lastPathComponent
            let isDir = isDirectory(source)
            if isDir, isSameOrDescendant(folder, of: source) { throw TransferError.intoItself(name) }
            let target = pasteName(for: name, isDirectory: isDir) {
                FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent($0))
            }
            let targetPath = (folder as NSString).appendingPathComponent(target)
            try FileManager.default.copyItem(atPath: source, toPath: targetPath)
            created.append(targetPath)
        }
        return created
    }

    /// Moves `sources` into `folder`. Items already in `folder` are skipped; a name collision
    /// throws instead of replacing. Returns (from, to) pairs for what moved, so callers can undo.
    static func move(sources: [String], intoFolder folder: String) throws -> [(from: String, to: String)] {
        guard !isInsideVault(((folder as NSString).appendingPathComponent("x"))) else {
            throw TransferError.vaultReadOnly((folder as NSString).lastPathComponent)
        }
        var moved: [(from: String, to: String)] = []
        for source in sources {
            let name = (source as NSString).lastPathComponent
            if isInsideVault(source) { throw TransferError.vaultReadOnly(name) }
            if (source as NSString).deletingLastPathComponent == (folder as NSString).standardizingPath { continue }
            if isDirectory(source), isSameOrDescendant(folder, of: source) { throw TransferError.intoItself(name) }
            let targetPath = (folder as NSString).appendingPathComponent(name)
            guard !FileManager.default.fileExists(atPath: targetPath) else { throw TransferError.exists(name) }
            try FileManager.default.moveItem(atPath: source, toPath: targetPath)
            moved.append((source, targetPath))
        }
        return moved
    }

    /// True when moving `source` into `folder` crosses volumes (a copy + delete, not a rename).
    static func crossesVolume(source: String, folder: String) -> Bool {
        let a = try? URL(fileURLWithPath: source).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let b = try? URL(fileURLWithPath: folder).resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        guard let a, let b else { return false }
        return !a.isEqual(b)
    }
}
