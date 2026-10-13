import BreeFoundation
import Darwin

/// Darwin reader for the current process's fixed host and effective user scope.
struct BreeTopProcessReader: BreeTopProcessReading {
    func enumerate() -> DarwinProcessListing { DarwinProcessEnumerator().capture() }
    func taskInfo(for pid: Int) -> proc_taskinfo? { BreeTopProcessSnapshot.taskInfo(for: pid) }
    func resourceUsage(for pid: Int) -> rusage_info_v4? { BreeTopProcessSnapshot.resourceUsage(for: pid) }
    func processName(pid: Int, fallback: String) -> String {
        BreeTopProcessSnapshot.processName(pid: pid, fallback: fallback)
    }
    func processPath(pid: Int) -> String? { BreeTopProcessSnapshot.processPath(pid: pid) }
    func scope(for pid: Int, key: BreeTopProcessScopeCacheKey) -> BreeTopProcessScope? {
        // No cross-census scope cache: exec can change argv/environment without
        // changing the PID's birth timestamp. In particular, absence cannot be
        // cached across authoritative restore scans.
        guard case .resolved(let value) = BreeTopProcessSnapshot.breeScopeProbe(
            for: pid, expectedCacheKey: key
        ) else { return nil }
        return value
    }
    func matches(pid: Int, key: BreeTopProcessScopeCacheKey) -> Bool {
        BreeTopProcessSnapshot.processMatchesKey(pid, key)
    }
    func processHasExited(pid: Int) -> Bool {
        guard pid > 0, pid <= Int(Int32.max) else { return false }
        return PIDPresence.current(pid: pid_t(pid)) == .absent
    }
}
