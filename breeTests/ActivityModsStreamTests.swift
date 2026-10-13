import Foundation
import Testing
@testable import Bree_Dev

@Suite("ActivityModsStream")
struct ActivityModsStreamTests {
    private func entry(_ at: Double, _ text: String, consumer: String = "wall") -> ModStreamEntry {
        ModStreamEntry(at: at, consumer: consumer, key: "k", title: "t", lines: [ModLine(text: text, kind: "warn")])
    }

    @Test func collapsesConsecutiveIdenticalEntriesNewestFirst() {
        let rows = ActivityModsStream.collapse([entry(1, "a"), entry(2, "a"), entry(3, "b"), entry(4, "a")])
        #expect(rows.map(\.count) == [1, 1, 2])
        #expect(rows.map(\.entry.at) == [4, 3, 2])
    }

    @Test func showsTitleOnlyWhenItDiffersFromConsumer() {
        func e(_ consumer: String, _ title: String) -> ModStreamEntry {
            ModStreamEntry(at: 1, consumer: consumer, key: "k", title: title, lines: [])
        }
        #expect(!e("wall", "wall").showsTitle)
        #expect(!e("wall", "Wall").showsTitle)
        #expect(!e("wall", "").showsTitle)
        #expect(e("bg-tasks", "task finished").showsTitle)
    }

    @Test func capsRows() {
        let entries = (0..<300).map { entry(Double($0), "line \($0)") }
        #expect(ActivityModsStream.collapse(entries).count == 200)
    }

    @Test func parsesStreamAndSkipsTornLines() {
        let jsonl = """
        {"at":1,"consumer":"wall","tr
        {"at":5,"consumer":"wall","key":"k","title":"t","lines":[{"text":"x","kind":"error"},{"text":"y"}]}
        """
        let entries = ActivityModsStream.parseStream(Data(jsonl.utf8))
        #expect(entries.count == 1)
        #expect(entries[0].lines == [ModLine(text: "x", kind: "error"), ModLine(text: "y", kind: nil)])
    }

    @Test func parsesSectionsAndDropsEmpty() {
        let json = """
        {"updatedAt":1,"cwd":"/w","sections":[
          {"consumer":"b","key":"k","title":"B","order":2,"until":"session","lines":[{"text":"two"}]},
          {"consumer":"a","key":"k","title":"A","order":1,"until":"turn","lines":[{"text":"one"}]},
          {"consumer":"empty","key":"k","title":"E","order":0,"lines":[]}]}
        """
        let parsed = ActivityModsStream.parseSections(Data(json.utf8))
        #expect(parsed.cwd == "/w")
        let live = ActivityModsStream.liveSections(parsed.sections)
        #expect(live.map(\.consumer) == ["a", "b"])
    }

    @Test func malformedSectionsFileIsEmpty() {
        #expect(ActivityModsStream.parseSections(Data("nope".utf8)).sections.isEmpty)
    }

    @Test func parsesButtonsPartsAndAnswer() {
        let json = """
        {"updatedAt":1,"cwd":"/w","sections":[
          {"consumer":"bg-tasks","key":"tasks","title":"1 running","order":1,
           "lines":[{"text":"10h model","kind":"warn","parts":[{"text":"10h","kind":"dim"},{"text":" model"}]}],
           "buttons":[{"label":"stop model","command":"bg-tasks","args":"stop 3"},
                      {"label":"","command":"x"},{"label":"bad","command":"has space"}]}],
         "answer":{"id":"A1","label":"stop model","command":"bg-tasks","text":"stopped 3","failed":false,"at":5}}
        """
        let parsed = ActivityModsStream.parseSections(Data(json.utf8), sessionId: "s1")
        let section = parsed.sections[0]
        #expect(section.sessionId == "s1")
        #expect(section.buttons == [ModButton(label: "stop model", command: "bg-tasks", args: "stop 3")])
        #expect(section.lines[0].parts == [ModLinePart(text: "10h", kind: "dim"), ModLinePart(text: " model", kind: nil)])
        #expect(parsed.answer == ModAnswer(id: "A1", label: "stop model", command: "bg-tasks", text: "stopped 3", failed: false, at: 5))
    }

    @Test func parsesStreamButtonsAndCapsAtSix() {
        let buttons = (0..<8).map { #"{"label":"b\#($0)","command":"c"}"# }.joined(separator: ",")
        let jsonl = #"{"at":1,"consumer":"w","key":"k","title":"t","lines":[],"buttons":["# + buttons + "]}"
        let entries = ActivityModsStream.parseStream(Data(jsonl.utf8), sessionId: "s")
        #expect(entries[0].buttons.count == 6)
        #expect(entries[0].sessionId == "s")
    }

    @Test func missingAnswerIsNil() {
        #expect(ActivityModsStream.parseSections(Data(#"{"sections":[]}"#.utf8)).answer == nil)
    }

    @Test func pressEncodesTheContractFields() throws {
        let press = ModPress(id: "ID1", consumer: "bg-tasks", key: "tasks", label: "stop model", at: 1791436594900)
        let object = try #require(JSONSerialization.jsonObject(with: press.encoded()) as? [String: Any])
        #expect(object["id"] as? String == "ID1")
        #expect(object["consumer"] as? String == "bg-tasks")
        #expect(object["key"] as? String == "tasks")
        #expect(object["label"] as? String == "stop model")
        #expect((object["at"] as? NSNumber)?.int64Value == 1791436594900)
        #expect(object.count == 5)
    }

    @Test func detectsUrlsAndPathsInALine() {
        let segments = ModLinkDetector.segments(in: "see ~/notes/a.md:12:3, (/tmp/x.log) and https://example.com/a?b=1.")
        let links = segments.compactMap(\.link)
        #expect(links == [
            .path(path: ("~/notes/a.md" as NSString).expandingTildeInPath, line: 12, column: 3),
            .path(path: "/tmp/x.log", line: nil, column: nil),
            .url("https://example.com/a?b=1"),
        ])
        #expect(segments.map(\.text).joined() == "see ~/notes/a.md:12:3, (/tmp/x.log) and https://example.com/a?b=1.")
    }

    @Test func relativeAndWordSlashesAreNotLinks() {
        #expect(ModLinkDetector.segments(in: "and/or src/main.swift 50%").allSatisfy { $0.link == nil })
    }

    @Test func existenceCheckSeesRealPaths() {
        let result = ModLinkDetector.existing(["/tmp", "/definitely/not/here"])
        #expect(result["/tmp"] == true)
        #expect(result["/definitely/not/here"] == false)
    }

    @Test func warningsFilterKeepsOnlyWarnAndError() {
        let mixed = ModStreamEntry(at: 1, consumer: "wall", key: "k", title: "t", lines: [
            ModLine(text: "fine", kind: "ok"), ModLine(text: "careful", kind: "warn"), ModLine(text: "boom", kind: "error"),
        ])
        let quiet = ModStreamEntry(at: 2, consumer: "journal", key: "k", title: "t", lines: [ModLine(text: "x", kind: "dim")])
        let snapshot = ActivityModsSnapshot(live: [], rows: ActivityModsStream.collapse([mixed, quiet]))
        let filtered = ModFilterRules.apply(snapshot, warningsOnly: true, hidden: [])
        #expect(filtered.rows.count == 1)
        #expect(filtered.rows[0].entry.lines.map(\.text) == ["careful", "boom"])
        #expect(ModFilterRules.apply(snapshot, warningsOnly: false, hidden: ["wall"]).rows.map(\.entry.consumer) == ["journal"])
        #expect(ModFilterRules.hiddenList(["wall", "bash-diet"]) == "bash-diet, wall")
    }

    @Test func attentionTakesStrongestKindAndSkipsHidden() {
        func e(_ consumer: String, _ kind: String) -> ModStreamEntry {
            ModStreamEntry(at: 1, consumer: consumer, key: "k", title: "t", lines: [ModLine(text: "x", kind: kind)])
        }
        #expect(ModAttentionRules.severity(in: [e("a", "ok"), e("b", "dim")], hidden: []) == nil)
        #expect(ModAttentionRules.severity(in: [e("a", "warn")], hidden: []) == .warn)
        #expect(ModAttentionRules.severity(in: [e("a", "warn"), e("b", "error")], hidden: []) == .error)
        #expect(ModAttentionRules.severity(in: [e("a", "warn"), e("b", "error")], hidden: ["b"]) == .warn)
        #expect(ModAttentionRules.severity(in: [], hidden: []) == nil)
    }

    @Test func answerOwnerPrefersLiveSectionAndExpires() {
        let live = ModLiveSection(consumer: "bg-tasks", key: "tasks", title: "", order: 0, until: nil, lines: [ModLine(text: "x", kind: nil)],
                                  buttons: [ModButton(label: "stop", command: "bg-tasks", args: nil)], sessionId: "s1")
        let answer = ModAnswer(id: "1", label: "stop", command: "bg-tasks", text: "ok", failed: false, at: 1000)
        #expect(ModAnswerRules.ownerId(answer: answer, sessionId: "s1", live: [live], rows: []) == ModAnswerRules.liveId(live))
        #expect(ModAnswerRules.ownerId(answer: answer, sessionId: "other", live: [live], rows: []) == nil)
        #expect(ModAnswerRules.isVisible(answer, nowMs: 1000 + 29_000))
        #expect(!ModAnswerRules.isVisible(answer, nowMs: 1000 + 31_000))
    }

    @Test func attentionReaderSkipsHistoryThenReadsAppendedLines() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mods-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("stream.jsonl")
        let old = #"{"at":1,"consumer":"w","key":"k","title":"t","lines":[{"text":"old","kind":"error"}]}"# + "\n"
        try Data(old.utf8).write(to: url)
        var cursor: ModStreamCursor?
        #expect(ModAttentionRules.readNew(url: url, cursor: &cursor).isEmpty)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        let fresh = #"{"at":2,"consumer":"w","key":"k","title":"t","lines":[{"text":"new","kind":"warn"}]}"# + "\n"
        try handle.write(contentsOf: Data(fresh.utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        let entries = ModAttentionRules.readNew(url: url, cursor: &cursor)
        #expect(entries.map { $0.lines[0].text } == ["new"])
        #expect(ModAttentionRules.readNew(url: url, cursor: &cursor).isEmpty)
    }

    @Test func footnotePlacementSplitsOwnedAndOrphans() {
        typealias N = ModAnswerRules.Footnote
        let now = 100_000.0
        func note(_ owner: String?, at: Double?) -> N {
            N(ownerId: owner, title: "t", text: "x", failed: false, at: at)
        }
        let placed = ModAnswerRules.placeFootnotes(
            [note("a", at: now - 1000), note("gone", at: now - 1000), note(nil, at: now - 1000), note("a", at: now - 40_000)],
            renderedOwners: ["a"], nowMs: now)
        #expect(Array(placed.byOwner.keys) == ["a"])
        #expect(placed.orphans.map(\.ownerId) == ["gone", nil])
        let expired = ModAnswerRules.placeFootnotes([note(nil, at: now - 31_000)], renderedOwners: [], nowMs: now)
        #expect(expired.byOwner.isEmpty && expired.orphans.isEmpty)
    }
}
