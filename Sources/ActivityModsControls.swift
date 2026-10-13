import Foundation

// Pure helpers behind the Activity → Mods controls: press files, link detection, the
// All/Warnings filter, hidden consumers and the sidebar attention computation.
// File I/O helpers are nonisolated and meant to run off the main thread.

// MARK: Press

/// What Bree writes to `~/.claude/status/<sid>/press.json`. Bree never sends a command; the
/// journal mod looks the button up by consumer + key + label.
struct ModPress: Equatable, Sendable {
    let id: String
    let consumer: String
    let key: String
    let label: String
    let at: Double

    func encoded() -> Data {
        let object: [String: Any] = ["id": id, "consumer": consumer, "key": key, "label": label, "at": Int64(at)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// Atomic write (temp file + rename), overwriting the previous press.
    nonisolated static func write(
        _ press: ModPress, sessionId: String, root: URL = ActivityModsStream.defaultRoot
    ) -> Bool {
        let dir = root.appendingPathComponent(sessionId, isDirectory: true)
        do {
            try press.encoded().write(to: dir.appendingPathComponent("press.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Just the answer of a session, for the 5 s wait after a press.
    nonisolated static func readAnswer(sessionId: String, root: URL = ActivityModsStream.defaultRoot) -> ModAnswer? {
        let url = root.appendingPathComponent(sessionId, isDirectory: true).appendingPathComponent("sections.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ActivityModsStream.parseSections(data).answer
    }
}

enum ModAnswerRules {
    /// An answer fades 30 s after the journal wrote it.
    static let fadeSeconds: Double = 30
    /// No answer within this long means the Claude session is probably gone.
    static let timeoutSeconds: Double = 5

    static func isVisible(_ answer: ModAnswer, nowMs: Double) -> Bool {
        nowMs - answer.at < fadeSeconds * 1000
    }

    /// Id of the section or row that owns the buttons the answer is about: a live section first,
    /// else the newest stream row. Nil when no button matches (for example "no such button").
    static func ownerId(answer: ModAnswer, sessionId: String, live: [ModLiveSection], rows: [ModStreamRow]) -> String? {
        func matches(_ buttons: [ModButton]) -> Bool {
            buttons.contains { $0.label == answer.label && (answer.command.isEmpty || $0.command == answer.command) }
        }
        if let section = live.first(where: { $0.sessionId == sessionId && matches($0.buttons) }) {
            return liveId(section)
        }
        return rows.first(where: { $0.entry.sessionId == sessionId && matches($0.entry.buttons) })?.id
    }

    static func liveId(_ section: ModLiveSection) -> String { "live-\(section.sessionId)-\(section.consumer)-\(section.key)" }

    /// One answer or notice line waiting for a place. `at` is nil for notices (no fade here).
    struct Footnote: Equatable, Sendable {
        let ownerId: String?
        /// Consumer or command shown in front of orphan lines.
        let title: String
        let text: String
        let failed: Bool
        let at: Double?
    }

    /// Visible footnotes whose owner is rendered go under the owner; the rest (owner nil or gone,
    /// for example after "stop <task>" removed its own section) are orphans for the top of the list.
    static func placeFootnotes(
        _ footnotes: [Footnote], renderedOwners: Set<String>, nowMs: Double
    ) -> (byOwner: [String: Footnote], orphans: [Footnote]) {
        var byOwner: [String: Footnote] = [:]
        var orphans: [Footnote] = []
        for note in footnotes {
            if let at = note.at, nowMs - at >= fadeSeconds * 1000 { continue }
            if let owner = note.ownerId, renderedOwners.contains(owner) {
                byOwner[owner] = note
            } else {
                orphans.append(note)
            }
        }
        return (byOwner, orphans)
    }
}

// MARK: Links

enum ModLink: Equatable, Sendable {
    case url(String)
    case path(path: String, line: Int?, column: Int?)

    var pathCandidate: String? {
        if case .path(let path, _, _) = self { return path }
        return nil
    }
}

struct ModTextSegment: Equatable, Sendable {
    let text: String
    /// Nil for plain text. A `.path` link is only a candidate until it is known to exist.
    let link: ModLink?
}

enum ModLinkDetector {
    private static let regex = try? NSRegularExpression(
        pattern: #"https?://[^\s<>"'`]+|(?<![\w/.~%-])~?/[^\s<>"'`:,;()\[\]]+(?::\d+(?::\d+)?)?"#)

    /// Splits `text` into plain and link segments. Joined segment texts equal `text`.
    static func segments(in text: String) -> [ModTextSegment] {
        guard let regex, text.contains("/") else { return [ModTextSegment(text: text, link: nil)] }
        let ns = text as NSString
        var out: [ModTextSegment] = []
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var range = match.range
            var raw = ns.substring(with: range)
            let isURL = raw.hasPrefix("http://") || raw.hasPrefix("https://")
            // Sentence punctuation after the link is not part of it.
            let trimSet: Set<Character> = isURL ? [".", ",", ";", ":", "!", "?", ")", "]"] : ["."]
            while let last = raw.last, trimSet.contains(last), raw.count > 1 {
                raw.removeLast()
                range.length -= (String(last) as NSString).length
            }
            if !isURL, raw.count < 2 || raw == "~/" { continue }
            if range.location > cursor {
                out.append(ModTextSegment(text: ns.substring(with: NSRange(location: cursor, length: range.location - cursor)), link: nil))
            }
            out.append(ModTextSegment(text: raw, link: isURL ? .url(raw) : pathLink(raw)))
            cursor = range.location + range.length
        }
        if cursor < ns.length {
            out.append(ModTextSegment(text: ns.substring(from: cursor), link: nil))
        }
        return out.isEmpty ? [ModTextSegment(text: text, link: nil)] : out
    }

    private static func pathLink(_ raw: String) -> ModLink {
        var path = raw
        var numbers: [Int] = []
        while let colon = path.lastIndex(of: ":"), let n = Int(path[path.index(after: colon)...]), numbers.count < 2 {
            numbers.insert(n, at: 0)
            path = String(path[..<colon])
        }
        return .path(path: (path as NSString).expandingTildeInPath, line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
    }

    /// Blocking: call off the main thread.
    nonisolated static func existing(_ paths: [String]) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for path in paths { result[path] = FileManager.default.fileExists(atPath: path) }
        return result
    }
}

// MARK: Filter and mute

enum ModFilterRules {
    static let hiddenDefaultsKey = "activityMods.hiddenConsumers"

    static func isWarning(_ kind: String?) -> Bool { kind == "warn" || kind == "error" }

    /// Drops hidden consumers; with `warningsOnly`, keeps only warn/error lines and drops what has none left.
    static func apply(_ snapshot: ActivityModsSnapshot, warningsOnly: Bool, hidden: Set<String>) -> ActivityModsSnapshot {
        var result = snapshot
        result.live = snapshot.live.compactMap { section in
            guard !hidden.contains(section.consumer) else { return nil }
            guard warningsOnly else { return section }
            let kept = section.lines.filter { isWarning($0.kind) }
            guard !kept.isEmpty else { return nil }
            return ModLiveSection(
                consumer: section.consumer, key: section.key, title: section.title, order: section.order,
                until: section.until, lines: kept, buttons: section.buttons, sessionId: section.sessionId)
        }
        result.rows = snapshot.rows.compactMap { row in
            let entry = row.entry
            guard !hidden.contains(entry.consumer) else { return nil }
            guard warningsOnly else { return row }
            let kept = entry.lines.filter { isWarning($0.kind) }
            guard !kept.isEmpty else { return nil }
            let narrowed = ModStreamEntry(
                at: entry.at, consumer: entry.consumer, key: entry.key, title: entry.title,
                lines: kept, buttons: entry.buttons, sessionId: entry.sessionId)
            return ModStreamRow(entry: narrowed, count: row.count)
        }
        return result
    }

    /// "Hidden: wall, bash-diet"
    static func hiddenList(_ hidden: Set<String>) -> String { hidden.sorted().joined(separator: ", ") }
}

// MARK: Attention

enum ModAttentionKind: Int, Comparable, Sendable {
    case warn = 1
    case error = 2

    static func < (lhs: ModAttentionKind, rhs: ModAttentionKind) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where the attention poller stopped reading one `stream.jsonl`.
struct ModStreamCursor: Equatable, Sendable {
    var offset: UInt64
    var mtime: Date
}

enum ModAttentionRules {
    /// The strongest warn/error line among `entries`, ignoring hidden consumers.
    static func severity(in entries: [ModStreamEntry], hidden: Set<String>) -> ModAttentionKind? {
        var best: ModAttentionKind?
        for entry in entries where !hidden.contains(entry.consumer) {
            for line in entry.lines {
                let kind: ModAttentionKind?
                switch line.kind {
                case "error": kind = .error
                case "warn": kind = .warn
                default: kind = nil
                }
                if let kind, kind > (best ?? .warn) || best == nil { best = kind }
            }
        }
        return best
    }

    /// Reads what was appended to `url` since `cursor`, only when the mtime or size moved. The first
    /// sight of a file sets a baseline and reports nothing (old history is not news). Blocking.
    nonisolated static func readNew(url: URL, cursor: inout ModStreamCursor?) -> [ModStreamEntry] {
        var url = url
        url.removeAllCachedResourceValues()  // URL caches attributes per instance
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let mtime = values.contentModificationDate, let size = values.fileSize.map(UInt64.init) else { return [] }
        guard var current = cursor else {
            cursor = ModStreamCursor(offset: size, mtime: mtime)
            return []
        }
        guard mtime != current.mtime else { return [] }
        if size < current.offset { current.offset = 0 }
        let start = max(current.offset, size > UInt64(ActivityModsStream.maxTailBytes) ? size - UInt64(ActivityModsStream.maxTailBytes) : 0)
        defer { cursor = current }
        current.mtime = mtime
        guard size > start, let handle = try? FileHandle(forReadingFrom: url) else {
            current.offset = size
            return []
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: start)
        guard var data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return [] }
        // Only whole lines; a half-written last line is picked up on the next change.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else {
            current.offset = start
            return []
        }
        data = data.prefix(through: lastNewline)
        current.offset = start + UInt64(data.count)
        return ActivityModsStream.parseStream(data)
    }
}

// MARK: Attention store

/// Which workspaces have a mod warning/error the user has not looked at yet, for the dot on the
/// sidebar card. Polls only the `stream.jsonl` mtime of live Claude sessions (3 s) and reads the
/// appended tail when it changed. Last-seen state is in memory only.
@MainActor
final class ModAttentionStore: ObservableObject {
    static let shared = ModAttentionStore()

    @Published private(set) var kinds: [UUID: ModAttentionKind] = [:]

    private var cursors: [String: ModStreamCursor] = [:]
    /// Workspaces whose Activity → Mods is on screen right now.
    private var visible: Set<UUID> = []
    private var task: Task<Void, Never>?

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    /// Called by the Mods view on appear/disappear. Becoming visible clears the dot.
    func setVisible(_ workspaceId: UUID, _ isVisible: Bool) {
        if isVisible {
            visible.insert(workspaceId)
            clear(workspaceId)
        } else {
            visible.remove(workspaceId)
        }
    }

    func clear(_ workspaceId: UUID) {
        guard kinds.removeValue(forKey: workspaceId) != nil else { return }
#if DEBUG
        breeDebugLog("mods.attention cleared ws=\(workspaceId.uuidString.prefix(8))")
#endif
    }

    private func poll() async {
        let sessions = AgentLensStore.shared.cards.map { ($0.claudeSessionID ?? $0.id, $0.workspaceID) }
        guard !sessions.isEmpty else { return }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: ModFilterRules.hiddenDefaultsKey) ?? [])
        let known = cursors
        let result = await Task.detached(priority: .utility) { () -> ([(UUID, ModAttentionKind)], [String: ModStreamCursor]) in
            var updated = known
            var found: [(UUID, ModAttentionKind)] = []
            for (sid, workspaceId) in sessions {
                let url = ActivityModsStream.defaultRoot
                    .appendingPathComponent(sid, isDirectory: true).appendingPathComponent("stream.jsonl")
                var cursor = updated[sid]
                let entries = ModAttentionRules.readNew(url: url, cursor: &cursor)
                updated[sid] = cursor
                if let kind = ModAttentionRules.severity(in: entries, hidden: hidden) { found.append((workspaceId, kind)) }
            }
            return (found, updated)
        }.value
        cursors = result.1
        for (workspaceId, kind) in result.0 where !visible.contains(workspaceId) {
            if let existing = kinds[workspaceId], existing >= kind { continue }
            kinds[workspaceId] = kind
#if DEBUG
            breeDebugLog("mods.attention set ws=\(workspaceId.uuidString.prefix(8)) kind=\(kind == .error ? "error" : "warn")")
#endif
        }
    }
}
