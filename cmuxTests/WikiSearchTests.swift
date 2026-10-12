import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class WikiSearchTests: XCTestCase {
    private func entry(
        _ title: String, one: String = "", headings: [String] = [], body: String = "",
        updated: String = "2026-01-01", project: String = "p"
    ) -> WikiSearchEntry {
        WikiSearchEntry(project: project, slug: title, title: title, oneLiner: one, updated: updated,
                        path: "/w/\(project)/\(title).md", headings: headings, body: body)
    }

    private func titles(_ hits: [WikiSearchHit]) -> [String] { hits.map(\.entry.title) }

    // MARK: Folding

    func testTurkishFolding() {
        let f = WikiSearchText.fold
        XCTAssertEqual(f("ISIM"), f("isim"))
        XCTAssertEqual(f("İsim"), f("isim"))
        XCTAssertEqual(f("arastirma"), f("araştırma"))
        XCTAssertEqual(f("ARAŞTIRMA"), f("arastirma"))
        XCTAssertEqual(f("çöğüşı"), "cogusi")
        XCTAssertEqual(f("ŞİŞE").count, 4, "folding keeps the character count so highlight ranges map back")
    }

    func testSearchFoldsBothWays() {
        let index = WikiSearchIndex(entries: [entry("Araştırma notları"), entry("Arastirma plain"), entry("İsim")])
        XCTAssertEqual(Set(titles(index.search("arastirma"))), ["Araştırma notları", "Arastirma plain"])
        XCTAssertEqual(Set(titles(index.search("ARAŞTIRMA"))), ["Araştırma notları", "Arastirma plain"])
        XCTAssertEqual(titles(index.search("ISIM")), ["İsim"])
        XCTAssertEqual(titles(index.search("isim")), ["İsim"])
    }

    // MARK: Tokens

    func testTokensAreAndedWithPrefixMatch() {
        let index = WikiSearchIndex(entries: [
            entry("Prompt caching", body: "kv cache keeps attention values"),
            entry("Prompt design", body: "no relevant words"),
            entry("Other", body: "cache only"),
        ])
        XCTAssertEqual(titles(index.search("prom cach")), ["Prompt caching"], "every token must match, each as a word prefix")
        XCTAssertEqual(titles(index.search("ache")), [], "a token matches at word starts only")
        XCTAssertEqual(titles(index.search("   ")), [])
    }

    // MARK: Ranking

    func testRankingOrder() {
        let index = WikiSearchIndex(entries: [
            entry("E-body", body: "uses cache here"),
            entry("D-heading", headings: ["Cache design"]),
            entry("C-oneliner", one: "about cache"),
            entry("Prompt cache"),
            entry("Cache layers"),
            entry("Cache"),
        ])
        let hits = index.search("cache")
        XCTAssertEqual(titles(hits), ["Cache", "Cache layers", "Prompt cache", "C-oneliner", "D-heading", "E-body"])
        XCTAssertEqual(hits.map(\.kind), [.exactTitle, .titlePrefix, .titleWord, .oneLiner, .heading, .body])
    }

    func testTiesGoToNewestUpdated() {
        let index = WikiSearchIndex(entries: [
            entry("old", body: "cache", updated: "2026-01-01"),
            entry("new", body: "cache", updated: "2026-09-30"),
            entry("mid", body: "cache", updated: "2026-05-05"),
        ])
        XCTAssertEqual(titles(index.search("cache")), ["new", "mid", "old"])
    }

    func testPreferredProjectRanksFirstAndScopeFilters() {
        let index = WikiSearchIndex(entries: [
            entry("Cache", project: "other"),
            entry("Cache notes", body: "", project: "mine"),
        ])
        XCTAssertEqual(titles(index.search("cache", preferredProject: "mine")), ["Cache notes", "Cache"])
        XCTAssertEqual(titles(index.search("cache", scope: .project("mine"))), ["Cache notes"])
    }

    func testTopicSections() {
        XCTAssertTrue(WikiMatchKind.oneLiner.isTopic)
        XCTAssertFalse(WikiMatchKind.heading.isTopic)
    }

    // MARK: Snippet

    func testSnippetWindowAndHighlight() {
        let before = String(repeating: "alpha ", count: 30)
        let after = String(repeating: " omega", count: 30)
        let snippet = WikiSearchIndex.snippet(in: before + "Needle" + after, token: "needle", radius: 60)
        XCTAssertNotNil(snippet.highlight)
        let chars = Array(snippet.text)
        XCTAssertEqual(String(chars[snippet.highlight!]), "Needle", "highlight keeps the original casing")
        XCTAssertLessThanOrEqual(chars.count, 60 + 6 + 60 + 2, "about 60 characters each side plus two ellipses")
        XCTAssertTrue(snippet.text.hasPrefix("…"))
        XCTAssertTrue(snippet.text.hasSuffix("…"))
    }

    func testSnippetShortTextHasNoEllipsisAndMatchesFoldedTurkish() {
        let snippet = WikiSearchIndex.snippet(in: "Bir Araştırma notu", token: "arastirma")
        XCTAssertEqual(snippet.text, "Bir Araştırma notu")
        XCTAssertEqual(String(Array(snippet.text)[snippet.highlight!]), "Araştırma")
    }

    func testHitCarriesSnippetOfBody() {
        let index = WikiSearchIndex(entries: [entry("Topic", body: "intro line\nthe kv cache matters")])
        let hit = index.search("cache").first
        XCTAssertEqual(hit?.kind, .body)
        XCTAssertNotNil(hit?.snippet.highlight)
        XCTAssertFalse(hit?.snippet.text.contains("\n") ?? true, "snippet is one line")
    }

    // MARK: Parsing

    func testFrontMatterStrippedAndHeadingsParsed() {
        let md = "---\nproject: payments-api\ntitle: T\n---\n# Title\nbody text\n```\n# not a heading\n```\n## Second\n"
        let parsed = WikiSearchIndex.parse(markdown: md)
        XCTAssertFalse(parsed.body.contains("project: payments-api"))
        XCTAssertTrue(parsed.body.contains("body text"))
        XCTAssertEqual(parsed.headings, ["Title", "Second"])
    }

    func testSubheadingsIndexedAndDetailsTextIsBody() {
        let md = "## Problem\n### Araştırdıklarımız\n<details><summary>Sıkıştırma</summary>\nkilit ayrım metni\n</details>\n"
        let parsed = WikiSearchIndex.parse(markdown: md)
        XCTAssertEqual(parsed.headings, ["Problem", "Araştırdıklarımız"])
        XCTAssertFalse(parsed.body.contains("<details"))
        XCTAssertTrue(parsed.body.contains("kilit ayrım metni"))
    }

    func testEmptyIndexSearchesToNothing() {
        XCTAssertEqual(WikiSearchIndex.build(indexes: []).search("x"), [])
    }

    // MARK: Build, snap never indexed

    func testBuildIndexesTopicPagesAndNeverSnap() throws {
        let wiki = NSTemporaryDirectory() + "wikisearch-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: wiki + "/proj", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: wiki + "/_kaynaklar/snap/x", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: wiki) }
        try "---\ntitle: A\nsecretfm: zzfront\n---\n# A\nvisible zzbody".write(toFile: wiki + "/proj/a.md", atomically: true, encoding: .utf8)
        try "snapword zzsnap".write(toFile: wiki + "/_kaynaklar/snap/x/readme.md", atomically: true, encoding: .utf8)
        let json = """
        {"project":"proj","root":"/r","groups":[{"title":"G","pages":[
          {"slug":"a","title":"A","one_liner":"one","updated":"2026-01-01","status":"ok"},
          {"slug":"s","title":"S","one_liner":"snap page","updated":"2026-01-01","status":"ok","file":"../_kaynaklar/snap/x/readme.md"}]}]}
        """
        try json.write(toFile: wiki + "/proj/index.json", atomically: true, encoding: .utf8)
        var index = try WikiIndex.decode(Data(json.utf8))
        index.dir = wiki + "/proj"
        let built = WikiSearchIndex.build(indexes: [index], wikiDir: wiki)
        XCTAssertEqual(built.entries.map(\.title), ["A"])
        XCTAssertEqual(titles(built.search("zzbody")), ["A"])
        XCTAssertEqual(titles(built.search("zzfront")), [], "front matter is not indexed")
        XCTAssertEqual(titles(built.search("zzsnap")), [], "snap/ is never indexed")
    }

    // MARK: Recents, Esc

    private func defaults() -> UserDefaults {
        let name = "WikiSearchTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testRecentSearchesCapAtFiveDedupeAndClear() {
        let recents = WikiRecents(defaults: defaults())
        for q in ["a", "b", "c", "d", "e", "f", "g"] { recents.addSearch(q) }
        XCTAssertEqual(recents.searches, ["g", "f", "e", "d", "c"])
        recents.addSearch("  ")
        recents.addSearch("E")
        XCTAssertEqual(recents.searches, ["E", "g", "f", "d", "c"], "a repeat moves to the front, blanks are ignored")
        recents.clearSearches()
        XCTAssertEqual(recents.searches, [])
    }

    func testRecentPagesCapAtFive() {
        let recents = WikiRecents(defaults: defaults())
        for i in 1...6 { recents.addPage(path: "/w/\(i).md", title: "P\(i)") }
        XCTAssertEqual(recents.pages.map(\.title), ["P6", "P5", "P4", "P3", "P2"])
    }

    func testEscapeClearsFirstThenCloses() {
        XCTAssertEqual(WikiSearchEscape.action(query: "abc"), .clearQuery)
        XCTAssertEqual(WikiSearchEscape.action(query: ""), .closeSearch)
    }

    func testRecentRowsListPagesThenSearches() {
        let recents = WikiRecents(defaults: defaults())
        recents.addPage(path: "/w/a.md", title: "A")
        recents.addPage(path: "/w/b.md", title: "B")
        recents.addSearch("one")
        recents.addSearch("two")
        XCTAssertEqual(recents.rows, [
            .page(.init(path: "/w/b.md", title: "B")), .page(.init(path: "/w/a.md", title: "A")),
            .search("two"), .search("one"),
        ])
    }

    func testSelectionMovesAndClamps() {
        XCTAssertEqual(WikiSearchSelection.move(0, by: 1, count: 3), 1)
        XCTAssertEqual(WikiSearchSelection.move(2, by: 1, count: 3), 2)
        XCTAssertEqual(WikiSearchSelection.move(0, by: -1, count: 3), 0)
        XCTAssertEqual(WikiSearchSelection.move(5, by: 0, count: 0), 0)
    }

    func testSearchStateEmptyStates() {
        typealias S = WikiSearchState
        XCTAssertEqual(S.resolve(query: "", resultCount: 0, recentCount: 2, indexIsEmpty: false), .recents)
        XCTAssertEqual(S.resolve(query: "", resultCount: 0, recentCount: 0, indexIsEmpty: false), .noRecentsHint)
        XCTAssertEqual(S.resolve(query: "  ", resultCount: 0, recentCount: 0, indexIsEmpty: false), .noRecentsHint)
        XCTAssertEqual(S.resolve(query: "x", resultCount: 0, recentCount: 0, indexIsEmpty: false), .noMatches)
        XCTAssertEqual(S.resolve(query: "x", resultCount: 3, recentCount: 0, indexIsEmpty: false), .results)
        XCTAssertEqual(S.resolve(query: "x", resultCount: 0, recentCount: 0, indexIsEmpty: true), .noTopics)
        XCTAssertEqual(S.resolve(query: "", resultCount: 0, recentCount: 4, indexIsEmpty: true), .noTopics)
    }
}
