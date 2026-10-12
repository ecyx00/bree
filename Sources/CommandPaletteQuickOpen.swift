import CmuxCommandPalette
import Foundation

/// A Quick Open query with a trailing `:N` or `:N:M` (line, column) split off.
struct QuickOpenQuery: Equatable {
    var text: String
    var line: Int?
    var column: Int?

    static func parse(_ raw: String) -> QuickOpenQuery {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var numbers: [Int] = []
        while numbers.count < 2, let colon = text.lastIndex(of: ":"), colon != text.startIndex,
              let n = Int(text[text.index(after: colon)...]), n > 0 {
            numbers.insert(n, at: 0)
            text = String(text[..<colon])
        }
        return QuickOpenQuery(
            text: text,
            line: numbers.first,
            column: numbers.count == 2 ? numbers[1] : nil
        )
    }
}

/// Off-main snapshot of the active workspace's project: indexed files and architecture nodes.
struct CommandPaletteQuickOpenSnapshot: Sendable {
    struct Node: Sendable {
        let label: String
        let path: String
        let line: Int?
    }

    var rootPath: String
    var files: [String] = []
    var nodes: [Node] = []

    static func load(rootPath: String) async -> CommandPaletteQuickOpenSnapshot {
        var snapshot = CommandPaletteQuickOpenSnapshot(rootPath: rootPath)
        snapshot.files = await TextBoxMentionIndexStore.shared.indexedFilePaths(rootDirectory: rootPath)
        let json = rootPath + "/.architecture/current.architecture.json"
        if let data = FileManager.default.contents(atPath: json),
           // Diffing against an empty document lists every component as "added".
           let changes = ArchitectureDiff.changes(old: Data("{}".utf8), new: data) {
            snapshot.nodes = changes.compactMap { change in
                guard !change.isEdge, let source = change.sourcePath,
                      let location = ArchitectureSourceLink.resolve(source, root: rootPath) else { return nil }
                return Node(label: change.label, path: location.path, line: change.line ?? location.line)
            }
        }
        return snapshot
    }
}

enum CommandPaletteQuickOpen {
    static let maxSessions = 300
    static let maxURLs = 500

    /// Cheap change signal for the palette fingerprint (the stores are not hashed per keystroke).
    static func fingerprint(
        snapshot: CommandPaletteQuickOpenSnapshot?,
        sessionCount: Int,
        newestSession: Date?,
        urlCount: Int,
        newestURL: Date?
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(snapshot?.rootPath)
        hasher.combine(snapshot?.files.count)
        hasher.combine(snapshot?.nodes.count)
        hasher.combine(sessionCount)
        hasher.combine(newestSession)
        hasher.combine(urlCount)
        hasher.combine(newestURL)
        return hasher.finalize()
    }

    /// Entries ranked after the workspace/surface rows so an empty query keeps the old order.
    @MainActor
    static func entries(
        snapshot: CommandPaletteQuickOpenSnapshot?,
        sessions: [SessionEntry],
        history: [BrowserHistoryStore.Entry],
        startRank: Int,
        openFile: @escaping (String) -> Void,
        openNode: @escaping (CommandPaletteQuickOpenSnapshot.Node) -> Void,
        openSession: @escaping (SessionEntry) -> Void,
        openURL: @escaping (URL) -> Void
    ) -> [CommandPaletteCommand] {
        var rank = startRank
        var result: [CommandPaletteCommand] = []
        func add(_ id: String, _ title: String, _ subtitle: String, _ kind: String, _ keywords: [String], _ action: @escaping () -> Void) {
            result.append(CommandPaletteCommand(
                id: id, rank: rank, title: title, subtitle: subtitle, shortcutHint: nil,
                kindLabel: kind, keywords: keywords, dismissOnRun: true, action: action
            ))
            rank += 1
        }

        let fileKind = String(localized: "commandPalette.kind.file", defaultValue: "File")
        let rootPrefix = (snapshot?.rootPath ?? "") + "/"
        for path in snapshot?.files ?? [] {
            let relative = path.hasPrefix(rootPrefix) ? String(path.dropFirst(rootPrefix.count)) : path
            add("quickOpen.file.\(path)", (path as NSString).lastPathComponent, relative, fileKind, []) { openFile(path) }
        }
        let componentKind = String(localized: "commandPalette.kind.component", defaultValue: "Component")
        for node in snapshot?.nodes ?? [] {
            add("quickOpen.node.\(node.path):\(node.line ?? 0):\(node.label)", node.label, (node.path as NSString).abbreviatingWithTildeInPath,
                componentKind, [node.path]) { openNode(node) }
        }
        let sessionKind = String(localized: "commandPalette.kind.session", defaultValue: "Agent Session")
        for entry in sessions.prefix(maxSessions) {
            add("quickOpen.session.\(entry.id)", entry.title.isEmpty ? entry.agent.displayName : entry.title,
                entry.agent.displayName + (entry.cwd.map { " • " + ($0 as NSString).abbreviatingWithTildeInPath } ?? ""),
                sessionKind, [entry.agent.displayName, entry.cwd ?? ""]) { openSession(entry) }
        }
        let urlKind = String(localized: "commandPalette.kind.webPage", defaultValue: "Web Page")
        for entry in history.prefix(maxURLs) {
            guard let url = URL(string: entry.url) else { continue }
            add("quickOpen.url.\(entry.id.uuidString)", entry.title ?? entry.url, entry.url, urlKind, [entry.url]) { openURL(url) }
        }
        return result
    }
}
