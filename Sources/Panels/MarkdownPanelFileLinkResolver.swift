import AppKit
import Foundation

enum MarkdownPanelFileLinkResolver {
    private static let markdownExtensions: Set<String> = ["md", "markdown", "mkd", "mdx"]

    static func isMarkdownPathLike(_ rawPath: String) -> Bool {
        let trimmed = stripFragmentAndQuery(rawPath)
        guard !trimmed.isEmpty else { return false }
        // Keep this intentionally path-like: code spans such as `foo.md`,
        // `docs/foo.md`, `../foo.md`, or `/tmp/foo.md` qualify. URLs do not.
        if let url = URL(string: trimmed), url.scheme != nil, url.scheme != "file" {
            return false
        }
        let ext = (trimmed as NSString).pathExtension.lowercased()
        return markdownExtensions.contains(ext)
    }

    static func resolve(rawPath: String, relativeToMarkdownFile markdownFilePath: String) -> String? {
        let stripped = stripFragmentAndQuery(rawPath)
        guard !stripped.isEmpty else { return nil }

        let candidatePaths: [String] = {
            if let url = URL(string: stripped), url.scheme == "file" {
                return [url.path]
            }
            if (stripped as NSString).isAbsolutePath {
                return [stripped]
            }
            let markdownDir = (markdownFilePath as NSString).deletingLastPathComponent
            let pwd = FileManager.default.currentDirectoryPath
            return [
                (markdownDir as NSString).appendingPathComponent(stripped),
                (pwd as NSString).appendingPathComponent(stripped)
            ]
        }()

        for path in candidatePaths {
            let standardized = (path as NSString).standardizingPath
            guard isMarkdownPathLike(standardized) else { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue {
                return standardized
            }
        }
        return nil
    }

    private static func stripFragmentAndQuery(_ rawPath: String) -> String {
        var s = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if let hash = s.firstIndex(of: "#") {
            s = String(s[..<hash])
        }
        if let question = s.firstIndex(of: "?") {
            s = String(s[..<question])
        }
        return s.removingPercentEncoding ?? s
    }
}

/// Obsidian integration through the file system and `obsidian://` URIs only.
/// A vault is any directory containing `.obsidian/`.
enum ObsidianVault {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var roots: [String: String?] = [:]
        private var indexes: [String: (date: Date, paths: [String])] = [:]
        private var backlinks: [String: (date: Date, items: [String])] = [:]

        func root(_ dir: String) -> String?? {
            lock.lock(); defer { lock.unlock() }
            return roots[dir]
        }
        func setRoot(_ root: String?, forDirs dirs: [String]) {
            lock.lock(); defer { lock.unlock() }
            for dir in dirs { roots[dir] = .some(root) }
        }
        func index(_ root: String) -> (date: Date, paths: [String])? {
            lock.lock(); defer { lock.unlock() }
            return indexes[root]
        }
        func setIndex(_ paths: [String], root: String) {
            lock.lock(); defer { lock.unlock() }
            indexes[root] = (Date(), paths)
        }
        func backlinks(_ key: String) -> (date: Date, items: [String])? {
            lock.lock(); defer { lock.unlock() }
            return backlinks[key]
        }
        func setBacklinks(_ items: [String], key: String) {
            lock.lock(); defer { lock.unlock() }
            backlinks[key] = (Date(), items)
        }
    }

    private static let cache = Cache()
    /// Index/backlink entries older than this are rebuilt on the next request.
    private static let cacheLifetime: TimeInterval = 30
    private static let maxBacklinkFilesScanned = 5000
    private static let maxEmbedBytes = 200_000

    // MARK: Vault detection

    /// The vault root containing `path`, walking up to (excluding) the home directory or `/`.
    static func root(forFile path: String, home: String = NSHomeDirectory()) -> String? {
        let start = ((path as NSString).standardizingPath as NSString).deletingLastPathComponent
        let homePath = (home as NSString).standardizingPath
        var visited: [String] = []
        var dir = start
        var found: String?
        while !dir.isEmpty, dir != "/", dir != homePath {
            if let cached = cache.root(dir) { found = cached; break }
            visited.append(dir)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(
                atPath: (dir as NSString).appendingPathComponent(".obsidian"),
                isDirectory: &isDir
            ), isDir.boolValue {
                found = dir
                break
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        cache.setRoot(found, forDirs: visited)
        return found
    }

    static func isVaultMarkdown(_ path: String) -> Bool {
        MarkdownPanelFileLinkResolver.isMarkdownPathLike(path) && root(forFile: path) != nil
    }

    // MARK: Obsidian URI

    /// `obsidian://open?path=<percent-encoded absolute path>`; `/` stays literal.
    static func openURL(forPath path: String) -> URL? {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~/")
        guard let encoded = path.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "obsidian://open?path=" + encoded)
    }

    /// Nil when no app handles `obsidian://` (Obsidian is not installed).
    static func installedAppURL() -> URL? {
        guard let probe = URL(string: "obsidian://open") else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: probe)
    }

    // MARK: Wikilink resolution

    /// Resolves a wikilink target (`Note`, `folder/Note`, `Note#Heading`, `img.png`) against vault-relative
    /// paths: exact relative path first, then a case-insensitive filename (or trailing-path) match anywhere,
    /// shortest path winning. `.md` is implied when the target has no extension.
    static func resolve(target: String, in relativePaths: [String]) -> String? {
        var name = target
        if let hash = name.firstIndex(of: "#") { name = String(name[..<hash]) }
        if let pipe = name.firstIndex(of: "|") { name = String(name[..<pipe]) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespaces))
        guard !name.isEmpty else { return nil }
        if (name as NSString).pathExtension.isEmpty { name += ".md" }
        if let exact = relativePaths.first(where: { $0 == name }) { return exact }
        let lowered = name.lowercased()
        return relativePaths
            .filter {
                let candidate = $0.lowercased()
                return candidate == lowered || candidate.hasSuffix("/" + lowered)
            }
            .min { ($0.count, $0) < ($1.count, $1) }
    }

    /// Vault-relative paths of every non-hidden file (so `.obsidian/` and `.trash/` are skipped), sorted.
    /// Built off the main thread; cached and rebuilt when stale or `refresh` is set.
    static func index(root: String, refresh: Bool = false) async -> [String] {
        if !refresh, let hit = cache.index(root), Date().timeIntervalSince(hit.date) < cacheLifetime {
            return hit.paths
        }
        let paths = await Task.detached(priority: .utility) { () -> [String] in
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            var result: [String] = []
            for case let url as URL in enumerator {
                guard result.count < 100_000 else { break }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                      url.path.hasPrefix(prefix) else { continue }
                result.append(String(url.path.dropFirst(prefix.count)))
            }
            return result.sorted()
        }.value
        cache.setIndex(paths, root: root)
        return paths
    }

    /// Absolute path for `target`, refreshing the index once when the first lookup misses.
    static func resolveAbsolutePath(target: String, root: String) async -> String? {
        var relative = resolve(target: target, in: await index(root: root))
        if relative == nil { relative = resolve(target: target, in: await index(root: root, refresh: true)) }
        return relative.map { (root as NSString).appendingPathComponent($0) }
    }

    /// Note text for an embed, capped so a huge file cannot flood the web view.
    static func embedText(atPath path: String) async -> String? {
        await Task.detached(priority: .utility) { () -> String? in
            guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: maxEmbedBytes) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    // MARK: Backlinks

    /// True when `text` contains `[[name]]`, `[[name|alias]]` or `[[name#heading]]` (case-insensitive).
    static func text(_ text: String, linksToNote name: String) -> Bool {
        let haystack = text.lowercased()
        let needle = "[[" + name.lowercased()
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let hit = haystack.range(of: needle, range: searchRange) {
            if let next = haystack[hit.upperBound...].first, next == "]" || next == "|" || next == "#" { return true }
            searchRange = hit.upperBound..<haystack.endIndex
        }
        return false
    }

    /// Vault-relative paths of notes linking to the note at `notePath`. A plain scan of at most
    /// `maxBacklinkFilesScanned` `.md` files, cached per vault + note mtime for `cacheLifetime`.
    static func backlinks(root: String, notePath: String) async -> [String] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: notePath)
        let mtime = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(root)\u{0}\(notePath)\u{0}\(mtime)"
        if let hit = cache.backlinks(key), Date().timeIntervalSince(hit.date) < cacheLifetime { return hit.items }
        let name = ((notePath as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidates = await index(root: root)
            .filter { MarkdownPanelFileLinkResolver.isMarkdownPathLike($0) }
            .prefix(maxBacklinkFilesScanned)
        let selfPath = (notePath as NSString).standardizingPath
        let items = await Task.detached(priority: .utility) { () -> [String] in
            var result: [String] = []
            for relative in candidates {
                let path = (root as NSString).appendingPathComponent(relative)
                guard (path as NSString).standardizingPath != selfPath,
                      let text = try? String(contentsOfFile: path, encoding: .utf8),
                      Self.text(text, linksToNote: name) else { continue }
                result.append(relative)
            }
            return result
        }.value
        cache.setBacklinks(items, key: key)
        return items
    }
}
