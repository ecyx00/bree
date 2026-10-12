import Foundation

/// Spawns the plain-text reader on the first paste and lets it exit after an idle
/// period. Dropping the connection closes its pipe, which ends an idle server.
/// A failed or cancelled reader is reaped before its replacement is admitted.
actor TerminalPlainTextPasteWorkerPool {
    private let executableURL: URL
    private let idleTimeout: Duration
    private var reader: Task<TerminalPlainTextPasteWorkerConnection, Error>?
    private var generation = UUID()
    private var activeRequests = 0
    private var idleTask: Task<Void, Never>?

    init(executableURL: URL, idleTimeout: Duration = .seconds(60)) {
        self.executableURL = executableURL
        self.idleTimeout = idleTimeout
    }

    func request(_ data: Data) async throws -> (status: Int32, payload: Data) {
        try Task.checkCancellation()
        idleTask?.cancel()
        idleTask = nil
        activeRequests += 1
        defer {
            activeRequests -= 1
            if activeRequests == 0 { scheduleIdleExit() }
        }
        let currentGeneration = generation
        let current = reader ?? Self.startReader(executableURL: executableURL)
        reader = current
        do {
            let connection = try await current.value
            return try await connection.request(data)
        } catch {
            if generation == currentGeneration {
                generation = UUID()
                reader = nil
            }
            throw error
        }
    }

    private func scheduleIdleExit() {
        let timeout = idleTimeout
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: timeout) } catch { return }
            await self?.releaseIdleReader()
        }
    }

    private func releaseIdleReader() {
        guard activeRequests == 0 else { return }
        generation = UUID()
        reader = nil
        idleTask = nil
    }

    private static func startReader(
        executableURL: URL
    ) -> Task<TerminalPlainTextPasteWorkerConnection, Error> {
        Task {
            let connection = TerminalPlainTextPasteWorkerConnection(executableURL: executableURL)
            try await connection.start()
            return connection
        }
    }
}
