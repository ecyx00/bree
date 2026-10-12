import Foundation

/// Which paths count as "changed while away", and the bounded log that keeps them.
enum AttentionChangeRules {
    static let ignoredNames: Set<String> = [
        ".git", "node_modules", ".build", "DerivedData", "build", "dist",
        ".venv", "__pycache__", ".DS_Store",
    ]
    /// Hidden tool directories that hold generated data, not the user's work.
    static let ignoredHiddenDirectories: Set<String> = [
        ".next", ".nuxt", ".turbo", ".gradle", ".swiftpm", ".idea", ".tox", ".parcel-cache",
    ]

    /// `true` when `path` is outside `root`, inside an ignored directory, or
    /// inside a hidden cache directory (`.cache`, `.pytest_cache`, ...).
    /// Hidden files such as `.env` are real changes and stay.
    static func shouldIgnore(path: String, root: String) -> Bool {
        let rootComponents = (root as NSString).standardizingPath.split(separator: "/")
        let components = (path as NSString).standardizingPath.split(separator: "/")
        guard components.count > rootComponents.count,
              Array(components.prefix(rootComponents.count)) == rootComponents else { return true }
        let relative = components.dropFirst(rootComponents.count)
        for (index, name) in relative.enumerated() {
            let name = String(name)
            if ignoredNames.contains(name) { return true }
            let isDirectoryComponent = index < relative.count - 1
            if isDirectoryComponent, name.hasPrefix("."),
               ignoredHiddenDirectories.contains(name) || name.lowercased().contains("cache") {
                return true
            }
        }
        return false
    }

    /// Directories the watcher must never cover: the file system root and the home folder.
    static func isWatchableRoot(_ path: String, home: String = NSHomeDirectory()) -> Bool {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else { return false }
        return standardized != (home as NSString).standardizingPath
    }
}

enum AttentionChangeKind: String, Equatable, Sendable {
    case created
    case modified
    case deleted
}

/// Changed paths for one away workspace: first-seen order, at most `cap` entries.
struct AttentionChangeLog: Equatable, Sendable {
    static let cap = 500

    struct Entry: Equatable, Sendable {
        let path: String
        var kind: AttentionChangeKind
    }

    private(set) var entries: [Entry] = []
    /// More paths changed than were kept, or the OS dropped event history.
    private(set) var isTruncated = false
    private var indexByPath: [String: Int] = [:]

    var count: Int { entries.count }
    var isEmpty: Bool { entries.isEmpty && !isTruncated }

    mutating func markTruncated() { isTruncated = true }

    /// Folds one observed change into the log. A file created and then deleted
    /// while away nets out to nothing; a deleted file that comes back is modified.
    mutating func record(path: String, kind: AttentionChangeKind) {
        guard let index = indexByPath[path] else {
            guard entries.count < Self.cap else {
                isTruncated = true
                return
            }
            indexByPath[path] = entries.count
            entries.append(Entry(path: path, kind: kind))
            return
        }
        switch (entries[index].kind, kind) {
        case (.created, .deleted):
            entries.remove(at: index)
            indexByPath = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.path, $0) })
        case (.created, _):
            break
        case (.modified, .deleted):
            entries[index].kind = .deleted
        case (.modified, _):
            break
        case (.deleted, .created), (.deleted, .modified):
            entries[index].kind = .modified
        case (.deleted, .deleted):
            break
        }
    }
}
