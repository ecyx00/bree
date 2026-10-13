import Foundation
import Testing
import BreeGit
import BreeFoundation
@testable import BreeSidebarGit

/// A reader returning canned metadata, with an optional gate the test holds
/// closed to control exactly when a snapshot probe completes.
actor GatedMetadataReader: WorkspaceGitMetadataReading {
    private let metadata: GitWorkspaceMetadata
    private let gated: Bool
    private var gateWaiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var probedDirectories: [String] = []
    private(set) var probedTrackedPathEventGenerations: [GitTrackedPathEventGeneration?] = []
    private struct ProbeWaiter {
        let id: UUID
        let minimumCount: Int
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var probeWaiters: [ProbeWaiter] = []

    init(metadata: GitWorkspaceMetadata, gated: Bool = false) {
        self.metadata = metadata
        self.gated = gated
        self.isOpen = !gated
    }

    func openGate() {
        isOpen = true
        while !gateWaiters.isEmpty {
            gateWaiters.removeFirst().resume()
        }
    }

    /// Suspends until the reader has recorded at least `minimumCount`
    /// probes. Event-driven: the probe itself resumes the waiter, and a probe
    /// that already happened satisfies the wait immediately.
    func waitForTrackedPathEventGenerationProbe(
        count minimumCount: Int = 1,
        timeout: Duration = sidebarGitTestWaitTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        await waitForProbe(count: minimumCount, timeout: timeout, sourceLocation: sourceLocation)
    }

    func waitForProbe(
        count minimumCount: Int = 1,
        timeout: Duration = sidebarGitTestWaitTimeout,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        if probedDirectories.count >= minimumCount { return true }
        let id = UUID()
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.expireProbeWaiter(id: id)
        }
        let satisfied = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            probeWaiters.append(ProbeWaiter(id: id, minimumCount: minimumCount, continuation: continuation))
        }
        timeoutTask.cancel()
        if !satisfied {
            recordWaitTimeout(
                "\(minimumCount) metadata probe(s); saw \(probedDirectories.count)",
                timeout: timeout,
                sourceLocation: sourceLocation
            )
        }
        return satisfied
    }

    private func expireProbeWaiter(id: UUID) {
        guard let index = probeWaiters.firstIndex(where: { $0.id == id }) else { return }
        probeWaiters.remove(at: index).continuation.resume(returning: false)
    }

    private func resumeSatisfiedProbeWaiters() {
        let count = probedDirectories.count
        let satisfied = probeWaiters.filter { $0.minimumCount <= count }
        probeWaiters.removeAll { $0.minimumCount <= count }
        for waiter in satisfied {
            waiter.continuation.resume(returning: true)
        }
    }

    func workspaceMetadata(for directory: String) async -> GitWorkspaceMetadata {
        await workspaceMetadata(for: directory, trackedPathEventGeneration: nil)
    }

    func workspaceMetadata(
        for directory: String,
        trackedPathEventGeneration: GitTrackedPathEventGeneration?
    ) async -> GitWorkspaceMetadata {
        probedDirectories.append(directory)
        probedTrackedPathEventGenerations.append(trackedPathEventGeneration)
        resumeSatisfiedProbeWaiters()
        if !isOpen {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if isOpen {
                    continuation.resume()
                } else {
                    gateWaiters.append(continuation)
                }
            }
        }
        return metadata
    }
}

/// Holds watch-descriptor reads until the test supplies each ordered result.
actor GatedWatchDescriptorReader: GitMetadataWatchDescriptorReading {
    private(set) var requestCount = 0
    private var queuedRequestDirectories: [String] = []
    private var requestContinuations: [CheckedContinuation<String, Never>] = []
    private var responseContinuations: [
        CheckedContinuation<GitWorkspaceMetadataWatchDescriptor?, Never>
    ] = []

    func watchDescriptor(for directory: String) async -> GitWorkspaceMetadataWatchDescriptor? {
        requestCount += 1
        if requestContinuations.isEmpty {
            queuedRequestDirectories.append(directory)
        } else {
            requestContinuations.removeFirst().resume(returning: directory)
        }
        return await withCheckedContinuation { continuation in
            responseContinuations.append(continuation)
        }
    }

    /// Waits for the next descriptor request using the request itself as the signal.
    func nextRequestedDirectory() async -> String {
        if !queuedRequestDirectories.isEmpty {
            return queuedRequestDirectories.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            requestContinuations.append(continuation)
        }
    }

    /// Completes the oldest outstanding descriptor request.
    func resumeNext(with descriptor: GitWorkspaceMetadataWatchDescriptor?) {
        precondition(!responseContinuations.isEmpty, "No descriptor request is awaiting a response")
        responseContinuations.removeFirst().resume(returning: descriptor)
    }
}

/// A `CommandRunning` that fails the test if any subprocess is spawned.
struct ForbiddenCommandRunner: CommandRunning {
    func run(
        directory: String,
        executable: String,
        arguments: [String],
        timeout: TimeInterval?
    ) async -> CommandResult {
        CommandResult(
            stdout: "",
            stderr: "unexpected subprocess: \(executable) \(arguments.joined(separator: " "))",
            exitStatus: 1,
            timedOut: false,
            executionError: "unexpected subprocess"
        )
    }
}

extension GitWorkspaceMetadata {
    static func repository(branch: String, isDirty: Bool = false) -> GitWorkspaceMetadata {
        GitWorkspaceMetadata(
            isRepository: true,
            branch: branch,
            isDirty: isDirty,
            indexSignature: "index",
            indexContentSignature: "content",
            headSignature: "head"
        )
    }

    static let nonRepository = GitWorkspaceMetadata(
        isRepository: false,
        branch: nil,
        isDirty: false,
        indexSignature: nil,
        indexContentSignature: nil,
        headSignature: nil
    )
}
