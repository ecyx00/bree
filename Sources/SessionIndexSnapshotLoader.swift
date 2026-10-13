import BreeAgentSessionStore

/// Explicit executor boundary for the Vault's initial filesystem snapshot.
struct SessionIndexSnapshotLoader: Sendable {
    /// Receives the merged-so-far entries each time one agent finishes, so the
    /// sidebar can show fast sources (Claude, OpenCode) before slow ones (Codex).
    typealias Progress = @MainActor @Sendable ([SessionEntry]) -> Void
    typealias LoadOperation = @Sendable (any AmpHookSessionReading, Progress?) async -> [SessionEntry]

    private let loadOperation: LoadOperation

    init() {
        self.loadOperation = { repository, progress in
            await SessionIndexStore.loadInitialEntries(
                ampSessionRepository: repository,
                progress: progress
            )
        }
    }

    init(loadOperation: @escaping @Sendable () async -> [SessionEntry]) {
        self.loadOperation = { _, _ in await loadOperation() }
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
    nonisolated func load(
        ampSessionRepository: any AmpHookSessionReading,
        progress: Progress? = nil
    ) async -> [SessionEntry] {
        await loadOperation(ampSessionRepository, progress)
    }
}
