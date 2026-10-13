import BreeFoundation
import Darwin

/// Native process reads, injected so census/enrichment costs and PID races can be exercised.
protocol BreeTopProcessReading: Sendable {
    func enumerate() -> DarwinProcessListing
    func taskInfo(for pid: Int) -> proc_taskinfo?
    func resourceUsage(for pid: Int) -> rusage_info_v4?
    func processName(pid: Int, fallback: String) -> String
    func processPath(pid: Int) -> String?
    func scope(for pid: Int, key: BreeTopProcessScopeCacheKey) -> BreeTopProcessScope?
    func matches(pid: Int, key: BreeTopProcessScopeCacheKey) -> Bool
    /// Whether the PID no longer exists. A process that exited mid-census is
    /// absent evidence, not a gap that makes the census incomplete.
    func processHasExited(pid: Int) -> Bool
}
