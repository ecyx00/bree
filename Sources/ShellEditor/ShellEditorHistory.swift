import BreeTerminalCore
import Foundation

/// Command history for the shell editor, newest first. Seeded once off the
/// main thread from the shell history files; session commands go on top.
@MainActor
final class ShellEditorHistory {
    static let shared = ShellEditorHistory()
    nonisolated static let limit = 5000

    private(set) var entries: [String] = []
    /// Unsent buffer per panel, restored when the dock view is rebuilt.
    var drafts: [UUID: String] = [:]
    private var seeded = false

    func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true
        Task.detached(priority: .utility) {
            var seed = TerminalCompletionCache.shared.history()
            // ponytail: the engine reads the default histfiles; a custom HISTFILE is only honored here.
            if let path = ProcessInfo.processInfo.environment["HISTFILE"],
               let text = try? String(contentsOfFile: path, encoding: .utf8) {
                let parsed = TerminalCompletionHistoryParsers.parseZsh(text)
                seed = TerminalCompletionHistoryParsers.recent(Array(seed.reversed()) + parsed, limit: Self.limit)
            }
            let result = seed
            await MainActor.run { ShellEditorHistory.shared.merge(seed: result) }
        }
    }

    private func merge(seed: [String]) {
        var seen = Set<String>()
        entries = (entries + seed).filter { seen.insert($0).inserted }
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func record(_ command: String) {
        guard !command.hasPrefix(" "), !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        entries.removeAll { $0 == command }
        entries.insert(command, at: 0)
        if entries.count > Self.limit { entries.removeLast() }
    }

    /// Most recent entry strictly extending `prefix` (single line only).
    func ghost(for prefix: String) -> String? {
        guard !prefix.isEmpty,
              let hit = entries.first(where: { $0.count > prefix.count && $0.hasPrefix(prefix) && !$0.contains("\n") })
        else { return nil }
        return String(hit.dropFirst(prefix.count))
    }

    /// Index of the next entry after `index` (older, or newer when `forward` is false) with `prefix`.
    func walk(from index: Int, forward: Bool, prefix: String) -> Int? {
        var i = forward ? index + 1 : index - 1
        while entries.indices.contains(i) {
            if entries[i].hasPrefix(prefix) { return i }
            i += forward ? 1 : -1
        }
        return nil
    }
}
