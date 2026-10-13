import BreeCommandPalette
import BreeFoundation
import BreeTerminalCore
import Foundation

/// One row of the terminal completion popup. Not shared with the text box
/// mention completion, whose insertion text produces markdown.
struct TerminalCompletionCandidate: Sendable, Equatable, Identifiable {
    enum Kind: Sendable, Equatable {
        case command, file, directory, gitRef, history, option
    }

    let kind: Kind
    /// Row label.
    let title: String
    /// Unescaped text that replaces the current word, or the whole line
    /// before the caret for `.history`.
    let insertion: String
    /// Dim secondary text in the row (an option's description).
    var detail: String?

    var id: String { "\(kind):\(insertion)" }
    var isDirectory: Bool { kind == .directory }
    /// Directories continue with the next path segment and `--opt=` waits
    /// for its value; everything else ends the word.
    var appendsSpace: Bool { !(isDirectory || (kind == .option && insertion.hasSuffix("="))) }

    /// What accepting this candidate types in place of the raw word: the
    /// escaped insertion, plus a space only when the word is finished.
    /// A directory yields `dir/` and nothing after it. History rows replace
    /// the whole line and are inserted verbatim by the callers.
    var replacementText: String {
        TerminalCompletionEscaping.escape(insertion, openQuote: nil) + (appendsSpace ? " " : "")
    }
}

/// Pure helpers shared by the shell editor (Tab, ghost text) and tests.
enum TerminalCompletionInline {
    /// The part of the escaped insertion that extends `rawWord`, or nil when
    /// the candidate does not start with what was typed (fuzzy matches).
    /// Used for ghost text: `rawWord` is the word as typed, so the check is
    /// done on the escaped form (`My\ Dir/` extends `My\ `).
    static func ghostSuffix(rawWord: String, candidate: TerminalCompletionCandidate) -> String? {
        guard candidate.kind == .file || candidate.kind == .directory else { return nil }
        let full = TerminalCompletionEscaping.escape(candidate.insertion, openQuote: nil)
        guard full.count > rawWord.count, full.hasPrefix(rawWord) else { return nil }
        return String(full.dropFirst(rawWord.count))
    }

    /// Index of the command whose name is exactly the typed command word, so
    /// Tab on a finished `cd` just adds the space instead of opening a fuzzy
    /// menu (`cd`, `bree-dev`, `clean-diff`...). Nil outside the command position.
    static func exactCommandIndex(word: String, isCommandPosition: Bool, candidates: [TerminalCompletionCandidate]) -> Int? {
        guard isCommandPosition, !word.isEmpty else { return nil }
        return candidates.firstIndex { $0.kind == .command && $0.insertion == word }
    }

    /// fish-style: the longest text every candidate shares that extends the
    /// typed word, as a suffix to insert. Nil when nothing can be added
    /// without choosing. History rows and fuzzy matches that do not extend
    /// the word are ignored.
    static func commonPrefixSuffix(rawWord: String, candidates: [TerminalCompletionCandidate]) -> String? {
        let fulls = candidates.filter { $0.kind != .history }
            .map { TerminalCompletionEscaping.escape($0.insertion, openQuote: nil) }
        guard fulls.count > 1, fulls.allSatisfy({ $0.hasPrefix(rawWord) }) else { return nil }
        var prefix = Substring(fulls[0])
        for other in fulls.dropFirst() {
            while !other.hasPrefix(prefix) { prefix = prefix.dropLast() }
        }
        return prefix.count > rawWord.count ? String(prefix.dropFirst(rawWord.count)) : nil
    }

    /// The first run of `ghost` an Option+Right accepts: up to and including
    /// the next `/`, or the next word boundary (an unescaped space).
    static func firstSegment(of ghost: String) -> String {
        var out = ""
        var escaped = false
        for ch in ghost {
            out.append(ch)
            if escaped { escaped = false; continue }
            if ch == "\\" { escaped = true; continue }
            if ch == "/" || (ch == " " && out.dropLast().contains { $0 != " " }) { break }
        }
        return out
    }
}

/// Fuzzy ranking: Nucleo for large corpora, the command-palette Swift engine
/// otherwise and whenever the Nucleo FFI is unavailable. Prefix matches come
/// first because completion is mostly prefix-driven.
struct TerminalCompletionRanker: Sendable {
    private static let nucleoMinimumCorpus = 256

    private let entries: [CommandPaletteSearchCorpusEntry<TerminalCompletionCandidate>]
    private let nucleo: CommandPaletteNucleoSearchIndex<TerminalCompletionCandidate>?

    /// `candidates` are in display order; that order breaks ties and serves
    /// the empty query.
    init(_ candidates: [TerminalCompletionCandidate]) {
        entries = candidates.enumerated().map { offset, candidate in
            CommandPaletteSearchCorpusEntry(
                payload: candidate,
                rank: offset,
                title: candidate.title,
                searchableTexts: [candidate.title]
            )
        }
        nucleo = entries.count >= Self.nucleoMinimumCorpus
            ? CommandPaletteNucleoSearchIndex(entries: entries)
            : nil
    }

    func rank(
        query: String,
        limit: Int,
        shouldCancel: @escaping () -> Bool = { false }
    ) -> [TerminalCompletionCandidate] {
        guard limit > 0, !shouldCancel() else { return [] }
        guard !query.isEmpty else { return entries.prefix(limit).map(\.payload) }

        let probe = min(entries.count, max(limit * 4, 128))
        var ranked: [TerminalCompletionCandidate]
        if let nucleo,
           let results = nucleo.search(query: query, resultLimit: probe, shouldCancel: shouldCancel) {
            ranked = results.map(\.payload)
        } else {
            ranked = CommandPaletteSearchEngine(entries: entries).search(
                query: query,
                resultLimit: probe,
                historyBoost: { _, _ in 0 },
                shouldCancel: shouldCancel
            ).map(\.payload)
        }
        if shouldCancel() { return [] }
        let lowered = query.lowercased()
        let prefixed = ranked.filter { $0.title.lowercased().hasPrefix(lowered) }
        let rest = ranked.filter { !$0.title.lowercased().hasPrefix(lowered) }
        return Array((prefixed + rest).prefix(limit))
    }
}

/// Process-wide caches for the slow-changing corpora (PATH executables and
/// shell history). Reads happen off the main thread.
final class TerminalCompletionCache: @unchecked Sendable {
    static let shared = TerminalCompletionCache()

    private static let commandTTL: TimeInterval = 30
    static let historyLimit = 5000

    private let lock = NSLock()
    private var commandEntry: (path: String, builtAt: Date, ranker: TerminalCompletionRanker)?
    private var historyEntry: (stamp: [String], lines: [String])?

    /// Executables on PATH. Rebuilt when PATH changes or after 30 seconds
    /// so a fresh `brew install` shows up.
    func commandRanker() -> TerminalCompletionRanker {
        let path = Self.searchPath()
        lock.lock()
        if let entry = commandEntry, entry.path == path,
           Date().timeIntervalSince(entry.builtAt) < Self.commandTTL {
            lock.unlock()
            return entry.ranker
        }
        lock.unlock()

        let fileManager = FileManager.default
        var names = Set<String>()
        for directory in path.split(separator: ":") {
            guard let items = try? fileManager.contentsOfDirectory(atPath: String(directory)) else { continue }
            for name in items where !name.hasPrefix(".") && !names.contains(name) {
                if fileManager.isExecutableFile(atPath: "\(directory)/\(name)") { names.insert(name) }
            }
        }
        let candidates = names.sorted().map {
            TerminalCompletionCandidate(kind: .command, title: $0, insertion: $0)
        }
        let ranker = TerminalCompletionRanker(candidates)
        lock.lock()
        commandEntry = (path, Date(), ranker)
        lock.unlock()
        return ranker
    }

    /// The app's PATH plus the usual user bin directories a GUI launch lacks.
    static func searchPath() -> String {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/bin", "\(home)/.cargo/bin"]
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var seen = Set<String>()
        return (base.split(separator: ":").map(String.init) + extra)
            .filter { seen.insert($0).inserted }
            .joined(separator: ":")
    }

    /// Recent commands, newest first, from zsh, bash and fish history.
    func history() -> [String] {
        let home = NSHomeDirectory()
        let dataHome = ProcessInfo.processInfo.environment["XDG_DATA_HOME"] ?? "\(home)/.local/share"
        let sources: [(path: String, parse: (String) -> [String])] = [
            ("\(home)/.zsh_history", TerminalCompletionHistoryParsers.parseZsh),
            ("\(home)/.bash_history", TerminalCompletionHistoryParsers.parseBash),
            ("\(dataHome)/fish/fish_history", TerminalCompletionHistoryParsers.parseFish),
        ]
        let fileManager = FileManager.default
        let present = sources.compactMap { source -> (path: String, parse: (String) -> [String], modified: Date, size: Int)? in
            guard let attributes = try? fileManager.attributesOfItem(atPath: source.path),
                  let modified = attributes[.modificationDate] as? Date else { return nil }
            return (source.path, source.parse, modified, (attributes[.size] as? Int) ?? 0)
        }
        let stamp = present.map { "\($0.path):\($0.modified.timeIntervalSince1970):\($0.size)" }
        lock.lock()
        if let entry = historyEntry, entry.stamp == stamp {
            lock.unlock()
            return entry.lines
        }
        lock.unlock()

        // Oldest-modified file first so the newest file's commands end up newest.
        var chronological: [String] = []
        for source in present.sorted(by: { $0.modified < $1.modified }) {
            chronological += source.parse(Self.tail(of: source.path))
        }
        let lines = TerminalCompletionHistoryParsers.recent(chronological, limit: Self.historyLimit)
        lock.lock()
        historyEntry = (stamp, lines)
        lock.unlock()
        return lines
    }

    /// The last 1 MiB of a file; ~5000 commands fit comfortably.
    private static func tail(of path: String) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let window: UInt64 = 1 << 20
        guard let size = try? handle.seekToEnd() else { return "" }
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        var text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        // A tail read starts mid-line; drop the partial first line.
        if start > 0, let newline = text.firstIndex(of: "\n") { text = String(text[text.index(after: newline)...]) }
        return text
    }
}

/// Builds the candidates for one completion request. All disk and process
/// work is synchronous, so callers run it off the main thread.
enum TerminalCompletionProviders {
    static let primaryLimit = 50
    static let historyLimit = 3

    static func candidates(
        for context: TerminalCompletionContext,
        cwd: String,
        cache: TerminalCompletionCache = .shared,
        isCancelled: @escaping () -> Bool
    ) async -> [TerminalCompletionCandidate] {
        let word = context.word
        var result: [TerminalCompletionCandidate] = []
        let pathLike = word.contains("/") || word.hasPrefix("~") || word.hasPrefix(".")

        if context.isCommandPosition {
            guard !word.isEmpty else { return [] }
            if pathLike {
                result += await pathCandidatesOffPool(word: word, cwd: cwd, directoriesOnly: false)
            } else {
                result += cache.commandRanker().rank(query: word, limit: primaryLimit, shouldCancel: isCancelled)
            }
        } else if !word.hasPrefix("-") {
            let git = TerminalCompletionGit.refCompletion(words: context.words, word: word)
            if git != .none {
                result += await gitRefCandidates(query: word, cwd: cwd, isCancelled: isCancelled)
            }
            if git != .refs {
                let directoriesOnly = ["cd", "pushd", "rmdir"].contains(context.command ?? "")
                result += await pathCandidatesOffPool(word: word, cwd: cwd, directoriesOnly: directoriesOnly)
            }
        }
        if isCancelled() { return [] }

        // Options always come from the shell; other words only when the
        // providers above found fewer than `fewResultsThreshold` results.
        if TerminalShellOptions.shouldRun(context: context, otherResults: result.count) {
            let known = Set(result.map(\.insertion))
            result += TerminalShellOptions.candidates(for: context, cwd: cwd, isCancelled: isCancelled)
                .filter { !known.contains($0.insertion) }
            if isCancelled() { return [] }
        }

        let prefix = context.linePrefix
        if !prefix.trimmingCharacters(in: .whitespaces).isEmpty {
            let titles = Set(result.map(\.insertion))
            let history = cache.history()
                .lazy
                .filter { $0.count > prefix.count && $0.hasPrefix(prefix) && !titles.contains($0) }
                .prefix(historyLimit)
            result += history.map { TerminalCompletionCandidate(kind: .history, title: $0, insertion: $0) }
        }
        return result
    }

    // MARK: Paths

    /// Directory listing on a GCD thread, so the blocking reads never park a
    /// Swift cooperative-pool thread (same pattern as FileExplorerStore).
    /// The listing is bounded (400 kept entries) and not cancellable midway;
    /// callers drop stale results by generation.
    static func pathCandidatesOffPool(
        word: String,
        cwd: String,
        directoriesOnly: Bool
    ) async -> [TerminalCompletionCandidate] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: pathCandidates(
                    word: word,
                    cwd: cwd,
                    directoriesOnly: directoriesOnly,
                    isCancelled: { false }
                ))
            }
        }
    }

    static func pathCandidates(
        word: String,
        cwd: String,
        directoriesOnly: Bool,
        isCancelled: @escaping () -> Bool
    ) -> [TerminalCompletionCandidate] {
        if word == "~" {
            return [TerminalCompletionCandidate(kind: .directory, title: "~/", insertion: "~/")]
        }
        let dirPart: String
        let namePart: String
        if let slash = word.lastIndex(of: "/") {
            dirPart = String(word[...slash])
            namePart = String(word[word.index(after: slash)...])
        } else {
            dirPart = ""
            namePart = word
        }
        let directory: String
        if dirPart.hasPrefix("~/") {
            directory = NSHomeDirectory() + "/" + dirPart.dropFirst(2)
        } else if dirPart.hasPrefix("~") {
            return []  // ponytail: ~user/ expansion skipped, add when asked
        } else if dirPart.hasPrefix("/") {
            directory = dirPart
        } else {
            directory = cwd + "/" + dirPart
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }

        let showHidden = namePart.hasPrefix(".")
        let loweredName = namePart.lowercased()
        var kept: [(name: String, isDirectory: Bool)] = []
        for name in names {
            if isCancelled() { return [] }
            if !showHidden, name.hasPrefix(".") { continue }
            if !loweredName.isEmpty, !isSubsequence(loweredName, of: name.lowercased()) { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory + "/" + name, isDirectory: &isDirectory) else { continue }
            if directoriesOnly, !isDirectory.boolValue { continue }
            kept.append((name, isDirectory.boolValue))
            if kept.count >= 400 { break }
        }
        kept.sort {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        // zsh order: case-sensitive prefix matches, then case-insensitive
        // ones; fuzzy matching only when nothing starts with the typed name.
        if !namePart.isEmpty {
            let exact = kept.filter { $0.name.hasPrefix(namePart) }
            let folded = kept.filter { $0.name.lowercased().hasPrefix(loweredName) }
            let prefixed = exact.isEmpty ? folded : exact
            if !prefixed.isEmpty { kept = prefixed }
        }
        let prefixOnly = !namePart.isEmpty && kept.allSatisfy { $0.name.lowercased().hasPrefix(loweredName) }
        let candidates = kept.map {
            TerminalCompletionCandidate(
                kind: $0.isDirectory ? .directory : .file,
                title: $0.name + ($0.isDirectory ? "/" : ""),
                insertion: dirPart + $0.name + ($0.isDirectory ? "/" : "")
            )
        }
        if prefixOnly { return Array(candidates.prefix(primaryLimit)) }
        return TerminalCompletionRanker(candidates).rank(query: namePart, limit: primaryLimit, shouldCancel: isCancelled)
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var index = needle.startIndex
        for character in haystack where index < needle.endIndex && character == needle[index] {
            index = needle.index(after: index)
        }
        return index == needle.endIndex
    }

    // MARK: Git

    static func gitRefCandidates(
        query: String,
        cwd: String,
        isCancelled: @escaping () -> Bool
    ) async -> [TerminalCompletionCandidate] {
        // Full names so local branches, remote branches and remote names
        // stay distinguishable; `%(refname:short)` collapses `origin/HEAD` to `origin`.
        guard let output = await CommandRunner().runStandardOutput(
            directory: cwd,
            executable: "git",
            arguments: ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes"],
            timeout: 1
        ), !isCancelled() else { return [] }
        var seen = Set<String>()
        var names: [String] = []
        for line in output.split(separator: "\n") {
            let name: Substring
            if line.hasPrefix("refs/heads/") {
                name = line.dropFirst("refs/heads/".count)
            } else if line.hasPrefix("refs/remotes/"), !line.hasSuffix("/HEAD") {
                name = line.dropFirst("refs/remotes/".count)
            } else {
                continue
            }
            if seen.insert(String(name)).inserted { names.append(String(name)) }
        }
        let candidates = names.map { TerminalCompletionCandidate(kind: .gitRef, title: $0, insertion: $0) }
        return TerminalCompletionRanker(candidates).rank(query: query, limit: primaryLimit, shouldCancel: isCancelled)
    }
}
