internal import Darwin
public import Foundation

/// Remembers the POSIX session id of each closed surface's shell so the Task Manager can
/// recognise its orphaned background jobs without reading their environment (SIP hides the
/// env of platform binaries). Bounded, in memory, pruned on access, no timers.
public enum TerminalClosedSessionLedger {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var entries: [Int32: (surfaceID: UUID, at: Date)] = [:]
    private static let maxEntries = 256
    private static let maxAge: TimeInterval = 24 * 3600

    /// Records the session of the processes on the surface's pty (shell and jobs share one session).
    /// Teardown runs after the runtime surface is gone, so the pty device is taken from the cache.
    public static func record(surfaceID: UUID, ttyDevice: Int64?, now: Date = Date()) {
        guard let ttyDevice, ttyDevice > 0, ttyDevice <= Int64(UInt32.max) else { return }
        var pids = [pid_t](repeating: 0, count: 256)
        let bytes = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_TTY_ONLY), UInt32(ttyDevice), $0.baseAddress, Int32($0.count))
        }
        guard bytes > 0 else { return }
        let sids = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride).filter { $0 > 1 }.map { getsid($0) }.filter { $0 > 1 }
        guard let sid = sids.first else { return }
        lock.lock()
        defer { lock.unlock() }
        entries = entries.filter { now.timeIntervalSince($0.value.at) < maxAge }
        if entries.count >= maxEntries, let oldest = entries.min(by: { $0.value.at < $1.value.at }) {
            entries[oldest.key] = nil
        }
        entries[sid] = (surfaceID, now)
    }

    /// The closed surface whose shell session `pid` still belongs to, if any.
    public static func closedSurfaceID(forProcess pid: Int, now: Date = Date()) -> UUID? {
        let sid = getsid(pid_t(pid))
        guard sid > 1 else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[sid], now.timeIntervalSince(entry.at) < maxAge else { return nil }
        return entry.surfaceID
    }
}
