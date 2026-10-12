import Foundation

/// One line a headless mod wrote; `kind` is the sidebar mod's kind (ok, warn, error, dim, info).
struct ModLine: Equatable, Sendable {
    let text: String
    let kind: String?
    /// Colour runs whose texts join to `text`; a part without `kind` takes the line's kind.
    var parts: [ModLinePart]? = nil
}

struct ModLinePart: Equatable, Sendable {
    let text: String
    let kind: String?
}

/// A button a mod attached to a section or stream entry. Pressing it asks the journal mod to run
/// `/<command> <args>` (see docs/state/2026-10-08-mods-actions-contract.md).
struct ModButton: Equatable, Sendable {
    let label: String
    let command: String
    let args: String?
}

/// The result of the latest press, written by the journal mod into sections.json.
struct ModAnswer: Equatable, Sendable {
    let id: String
    let label: String
    let command: String
    let text: String
    let failed: Bool
    let at: Double
}

/// A live section from `~/.claude/status/<sid>/sections.json`.
struct ModLiveSection: Equatable, Sendable {
    let consumer: String
    let key: String
    let title: String
    let order: Double
    /// Lifetime hint from the sidebar API: "turn", "session" or "stream". Informational only;
    /// the journal mod rewrites sections.json on clear, so the file is the truth.
    let until: String?
    let lines: [ModLine]
    var buttons: [ModButton] = []
    /// Session folder the section came from; presses are written there.
    var sessionId: String = ""
}

/// One entry of `~/.claude/status/<sid>/stream.jsonl`.
struct ModStreamEntry: Equatable, Sendable {
    let at: Double
    let consumer: String
    let key: String
    let title: String
    let lines: [ModLine]
    var buttons: [ModButton] = []
    var sessionId: String = ""

    /// The title adds nothing when it just repeats the consumer (or is empty).
    var showsTitle: Bool {
        !title.isEmpty && title.caseInsensitiveCompare(consumer) != .orderedSame
    }

    func isSameContent(as other: ModStreamEntry) -> Bool {
        consumer == other.consumer && key == other.key && title == other.title && lines == other.lines
            && buttons == other.buttons
    }
}

/// Consecutive identical entries folded into one row.
struct ModStreamRow: Equatable, Identifiable, Sendable {
    let entry: ModStreamEntry
    let count: Int
    var id: String { "\(entry.at)-\(entry.consumer)-\(entry.key)" }
}

struct ActivityModsSnapshot: Equatable, Sendable {
    var live: [ModLiveSection] = []
    var rows: [ModStreamRow] = []
    /// Latest press answer per session id.
    var answers: [String: ModAnswer] = [:]
    var isEmpty: Bool { live.isEmpty && rows.isEmpty }
}

/// Pure parsing and collapsing for the Activity "Mods" section. File I/O is in `load`.
enum ActivityModsStream {
    static let maxRows = 200
    /// Only the tail of a stream file is read; older entries would be cut by the row cap anyway.
    static let maxTailBytes = 512 * 1024

    private static func lines(_ value: Any?) -> [ModLine] {
        (value as? [[String: Any]] ?? []).compactMap { raw in
            guard let text = raw["text"] as? String else { return nil }
            let parts = (raw["parts"] as? [[String: Any]]).map { rawParts in
                rawParts.compactMap { part -> ModLinePart? in
                    guard let partText = part["text"] as? String else { return nil }
                    return ModLinePart(text: partText, kind: part["kind"] as? String)
                }
            }
            return ModLine(text: text, kind: raw["kind"] as? String, parts: (parts?.isEmpty ?? true) ? nil : parts)
        }
    }

    /// At most 6 buttons; entries without a label or a valid command are dropped.
    static func buttons(_ value: Any?) -> [ModButton] {
        let valid = (value as? [[String: Any]] ?? []).compactMap { raw -> ModButton? in
            guard let label = raw["label"] as? String, !label.isEmpty, !label.contains("\n"),
                  let command = raw["command"] as? String,
                  command.range(of: "^[A-Za-z0-9._:-]{1,64}$", options: .regularExpression) != nil else { return nil }
            let args = raw["args"] as? String
            return ModButton(label: label, command: command, args: args.map { String($0.prefix(200)) })
        }
        return Array(valid.prefix(6))
    }

    static func parseAnswer(_ value: Any?) -> ModAnswer? {
        guard let raw = value as? [String: Any],
              let id = raw["id"] as? String, !id.isEmpty,
              let label = raw["label"] as? String else { return nil }
        return ModAnswer(
            id: id, label: label,
            command: raw["command"] as? String ?? "",
            text: raw["text"] as? String ?? "",
            failed: raw["failed"] as? Bool ?? false,
            at: (raw["at"] as? NSNumber)?.doubleValue ?? 0)
    }

    static func parseSections(_ data: Data, sessionId: String = "") -> (cwd: String?, sections: [ModLiveSection], answer: ModAnswer?) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return (nil, [], nil) }
        let sections = (root["sections"] as? [[String: Any]] ?? []).compactMap { raw -> ModLiveSection? in
            guard let consumer = raw["consumer"] as? String else { return nil }
            return ModLiveSection(
                consumer: consumer,
                key: raw["key"] as? String ?? "",
                title: raw["title"] as? String ?? "",
                order: (raw["order"] as? NSNumber)?.doubleValue ?? 0,
                until: raw["until"] as? String,
                lines: lines(raw["lines"]),
                buttons: buttons(raw["buttons"]),
                sessionId: sessionId
            )
        }
        return (root["cwd"] as? String, sections, parseAnswer(root["answer"]))
    }

    /// Parses JSONL; malformed lines (including a torn first line of a tail read) are skipped.
    static func parseStream(_ data: Data, sessionId: String = "") -> [ModStreamEntry] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { slice in
            guard let raw = (try? JSONSerialization.jsonObject(with: Data(slice))) as? [String: Any],
                  let consumer = raw["consumer"] as? String,
                  let at = (raw["at"] as? NSNumber)?.doubleValue else { return nil }
            return ModStreamEntry(
                at: at,
                consumer: consumer,
                key: raw["key"] as? String ?? "",
                title: raw["title"] as? String ?? "",
                lines: lines(raw["lines"]),
                buttons: buttons(raw["buttons"]),
                sessionId: sessionId
            )
        }
    }

    /// Live sections that have text, in `order` (ties by consumer).
    static func liveSections(_ sections: [ModLiveSection]) -> [ModLiveSection] {
        sections
            .filter { !$0.lines.isEmpty }
            .sorted { ($0.order, $0.consumer, $0.key) < ($1.order, $1.consumer, $1.key) }
    }

    /// Newest first, consecutive identical entries folded into `count`, capped at `maxRows`.
    static func collapse(_ entries: [ModStreamEntry], cap: Int = maxRows) -> [ModStreamRow] {
        var rows: [ModStreamRow] = []
        for entry in entries.sorted(by: { $0.at > $1.at }) {
            if let last = rows.last, last.entry.isSameContent(as: entry) {
                rows[rows.count - 1] = ModStreamRow(entry: last.entry, count: last.count + 1)
            } else {
                if rows.count == cap { break }
                rows.append(ModStreamRow(entry: entry, count: 1))
            }
        }
        return rows
    }

    static func snapshot(
        sections: [ModLiveSection], entries: [ModStreamEntry], nowMs: Double,
        answers: [String: ModAnswer] = [:]
    ) -> ActivityModsSnapshot {
        ActivityModsSnapshot(live: liveSections(sections), rows: collapse(entries), answers: answers)
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/status", isDirectory: true)
    }

    /// Blocking file reads; call off the main thread. With no known session ids, falls back to
    /// session folders touched in the last day whose `cwd` equals `cwd`.
    nonisolated static func load(
        sessionIds: [String], cwd: String, root: URL = defaultRoot, now: Date = Date()
    ) -> ActivityModsSnapshot {
        let fm = FileManager.default
        var dirs = sessionIds.map { root.appendingPathComponent($0, isDirectory: true) }
        if dirs.isEmpty, !cwd.isEmpty,
           let children = try? fm.contentsOfDirectory(
               at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            dirs = children.filter { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return modified.map { now.timeIntervalSince($0) < 86400 } ?? false
            }
        }
        var sections: [ModLiveSection] = []
        var entries: [ModStreamEntry] = []
        var answers: [String: ModAnswer] = [:]
        for dir in dirs {
            let sid = dir.lastPathComponent
            let byCwd = sessionIds.isEmpty
            if let data = try? Data(contentsOf: dir.appendingPathComponent("sections.json")) {
                let parsed = parseSections(data, sessionId: sid)
                if !byCwd || parsed.cwd == cwd {
                    sections += parsed.sections
                    if let answer = parsed.answer { answers[sid] = answer }
                } else { continue }
            } else if byCwd {
                continue
            }
            entries += parseStream(tail(dir.appendingPathComponent("stream.jsonl")), sessionId: sid)
        }
        return snapshot(sections: sections, entries: entries, nowMs: now.timeIntervalSince1970 * 1000, answers: answers)
    }

    nonisolated static func tail(_ url: URL) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return Data() }
        let start = size > UInt64(maxTailBytes) ? size - UInt64(maxTailBytes) : 0
        try? handle.seek(toOffset: start)
        return (try? handle.readToEnd()) ?? Data()
    }
}
