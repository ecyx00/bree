import Foundation
import Dispatch

/// Counts entries in `git status --porcelain=v1 -z` output.
enum GitPorcelainChangedFileCount {
    /// Number of changed paths, untracked included. A rename or copy entry
    /// (`R`/`C` in the index column) is followed by its origin path, which is
    /// skipped so one rename counts once.
    static func count(in output: Data) -> Int {
        var count = 0
        var skipNext = false
        for field in output.split(separator: 0, omittingEmptySubsequences: true) {
            if skipNext {
                skipNext = false
                continue
            }
            count += 1
            if let first = field.first, first == UInt8(ascii: "R") || first == UInt8(ascii: "C") {
                skipNext = true
            }
        }
        return count
    }
}

extension GitDirtyStatusReading {
    /// Readers that cannot count (test fakes) report `nil`.
    func changedFileCount(workTreeRoot _: String) -> Int? { nil }
}

extension SystemGitDirtyStatusReader {
    /// Runs the full porcelain status (untracked files included) under the
    /// same bounded runners as `isDirty`. Returns `nil` on timeout or when
    /// the output exceeds the byte bound.
    // ponytail: one extra `git status` per metadata read; share the isDirty run if profiling shows cost.
    func changedFileCount(workTreeRoot: String) -> Int? {
        let candidates = runnerSelector.candidateRunners
        let deadline = DispatchTime.now() + runnerSelector.candidateWallTimeLimit
        for runner in candidates {
            let now = DispatchTime.now()
            guard deadline > now else { break }
            let remaining = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds)
                / 1_000_000_000
            guard let result = try? runner.run(
                arguments: ["status", "--porcelain=v1", "-z", "--ignore-submodules=dirty"],
                in: URL(fileURLWithPath: workTreeRoot, isDirectory: true),
                maximumOutputByteCount: 1_048_576,
                wallTimeLimit: remaining
            ) else { continue }
            if result.exitCode == 0, !result.standardOutputWasTruncated {
                return GitPorcelainChangedFileCount.count(in: result.output)
            }
        }
        return nil
    }
}
