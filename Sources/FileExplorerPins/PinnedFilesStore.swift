import Foundation

extension Notification.Name {
    /// Posted after any pin was added or removed. The object is the project root.
    static let pinnedFilesDidChange = Notification.Name("bree.pinnedFilesDidChange")
}

/// Pinned files per project, kept in UserDefaults (never in the user's repo).
///
/// A project is identified by its root: the nearest ancestor holding `.git`,
/// else the directory itself. Pins are stored as paths relative to that root,
/// so moving or renaming the project folder only needs one key to change.
/// There are no default pins.
struct PinnedFilesStore {
    static let defaultsKey = "fileExplorer.pinnedFiles"
    static let collapsedKey = "fileExplorer.pinnedFiles.collapsed"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: Project root and paths

    /// The nearest ancestor of `directory` holding `.git`, else `directory`.
    static func projectRoot(forDirectory directory: String, fileManager: FileManager = .default) -> String {
        let start = URL(fileURLWithPath: directory).standardizedFileURL
        var url = start
        while true {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return start.path }
            url = parent
        }
    }

    /// `path` relative to `root`, or nil when `path` is the root or outside it.
    static func relativePath(for path: String, root: String) -> String? {
        let normalizedRoot = URL(fileURLWithPath: root).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        let prefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedPath.hasPrefix(prefix), normalizedPath.count > prefix.count else { return nil }
        return String(normalizedPath.dropFirst(prefix.count))
    }

    static func absolutePath(for relativePath: String, root: String) -> String {
        URL(fileURLWithPath: root).appendingPathComponent(relativePath).standardizedFileURL.path
    }

    private static func key(forRoot root: String) -> String {
        URL(fileURLWithPath: root).standardizedFileURL.path
    }

    // MARK: Reading

    private var table: [String: [String]] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: [String]] ?? [:]
    }

    /// Relative pinned paths for `root`, in the order they were pinned.
    func pins(forRoot root: String) -> [String] {
        table[Self.key(forRoot: root)] ?? []
    }

    func isPinned(path: String, root: String) -> Bool {
        guard let relative = Self.relativePath(for: path, root: root) else { return false }
        return pins(forRoot: root).contains(relative)
    }

    // MARK: Writing

    /// Pins `path`. Returns false when it is outside `root` or already pinned.
    @discardableResult
    func pin(path: String, root: String) -> Bool {
        guard let relative = Self.relativePath(for: path, root: root) else { return false }
        var current = pins(forRoot: root)
        guard !current.contains(relative) else { return false }
        current.append(relative)
        write(current, forRoot: root)
        return true
    }

    func unpin(relativePath: String, root: String) {
        var current = pins(forRoot: root)
        guard let index = current.firstIndex(of: relativePath) else { return }
        current.remove(at: index)
        write(current, forRoot: root)
    }

    func unpin(path: String, root: String) {
        guard let relative = Self.relativePath(for: path, root: root) else { return }
        unpin(relativePath: relative, root: root)
    }

    private func write(_ pins: [String], forRoot root: String) {
        var next = table
        // An empty list is removed so the section hides and nothing lingers.
        next[Self.key(forRoot: root)] = pins.isEmpty ? nil : pins
        defaults.set(next, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .pinnedFilesDidChange, object: root)
    }

    // MARK: Section state

    var isSectionCollapsed: Bool {
        get { defaults.bool(forKey: Self.collapsedKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.collapsedKey) }
    }
}
