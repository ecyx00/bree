import BreeFoundation
import Foundation
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class WikiSupportTests: XCTestCase {
    // MARK: Root matching

    func testRootMatchingEqualInsideOutsideAndPrefixTrap() {
        XCTAssertTrue(WikiProject.contains(root: "/a/payments-api", path: "/a/payments-api"))
        XCTAssertTrue(WikiProject.contains(root: "/a/payments-api", path: "/a/payments-api/src/x"))
        XCTAssertTrue(WikiProject.contains(root: "/a/payments-api/", path: "/a/payments-api/src"))
        XCTAssertFalse(WikiProject.contains(root: "/a/payments-api", path: "/a/other"))
        XCTAssertFalse(WikiProject.contains(root: "/a/payments-api", path: "/a/pay"))
        XCTAssertFalse(WikiProject.contains(root: "/a/pay", path: "/a/payments-api"))
        XCTAssertFalse(WikiProject.contains(root: "", path: "/a"))
    }

    func testMatchPrefersLongestRoot() throws {
        let outer = try WikiIndex.decode(Data(#"{"project":"o","root":"/a","generated":"x","groups":[]}"#.utf8))
        let inner = try WikiIndex.decode(Data(#"{"project":"i","root":"/a/b","generated":"x","groups":[]}"#.utf8))
        XCTAssertEqual(WikiProject.match([outer, inner], path: "/a/b/c")?.project, "i")
        XCTAssertEqual(WikiProject.match([outer, inner], path: "/a/z")?.project, "o")
        XCTAssertNil(WikiProject.match([outer, inner], path: "/q"))
    }

    // MARK: Link parsing

    func testCodeLinks() {
        XCTAssertEqual(WikiLink.parse("code:hm/jit.py:189"), .code(path: "hm/jit.py", line: 189))
        XCTAssertEqual(WikiLink.parse("code:hm/jit.py#jit_decide"), .codeSymbol(path: "hm/jit.py", symbol: "jit_decide"))
        XCTAssertEqual(WikiLink.parse("code:hm/jit.py"), .code(path: "hm/jit.py", line: nil))
        XCTAssertNil(WikiLink.parse("code:../etc/passwd:1"))
        XCTAssertNil(WikiLink.parse("code:/etc/passwd"))
        XCTAssertNil(WikiLink.parse("code:"))
    }

    func testBoardPageAndChipLinks() {
        XCTAssertEqual(WikiLink.parse("board:Spawn%20flow"), .board("Spawn flow"))
        XCTAssertEqual(WikiLink.parse("wiki:jit-hook"), .page(slug: "jit-hook"))
        XCTAssertNil(WikiLink.parse("wiki:../x"))
        XCTAssertNil(WikiLink.parse("wiki:a/b"))
        XCTAssertEqual(WikiLink.parse("chip:doc:docs%2Fstate%2Fa.md"), .chip(kind: "doc", value: "docs/state/a.md"))
        XCTAssertEqual(WikiLink.parse("chip:m:5572"), .chip(kind: "m", value: "5572"))
        XCTAssertNil(WikiLink.parse("https://example.com"))
    }

    /// The `.bree-wiki.json` that restores the owner's original behaviour.
    static let ownerConfig = WikiConfig.parse(Data(#"""
    {"chips":{"m":{"argv":["notes","zoom","{value}","1"],"title":"Note","valuePattern":"^[0-9]{1,12}$","output":"memory"},
              "notes":{"argv":["notes","show","{value}"],"title":"Note","output":"markdown"}},
     "hiddenTags":["genel"],"symbolCommand":["my-index","def","{symbol}"]}
    """#.utf8))

    func testPreprocessRewritesWikilinksAndChips() {
        let md = "See [[jit-hook]] and [[agent-spawn-hook|spawn]]. [doc:docs/a.md] [commit:abc123] [notes:obs-1] [m:5572]\n"
        let out = WikiMarkdown.preprocess(md, config: Self.ownerConfig)
        XCTAssertTrue(out.contains("[jit-hook](wiki:jit-hook)"))
        XCTAssertTrue(out.contains("[spawn](wiki:agent-spawn-hook)"))
        XCTAssertTrue(out.contains("[a.md](chip:doc:docs%2Fa.md)"))
        XCTAssertTrue(out.contains("[abc123](chip:commit:abc123)"))
        XCTAssertTrue(out.contains("[notes:obs-1](chip:notes:obs-1)"))
        XCTAssertTrue(out.contains("[m:5572](chip:m:5572)"))
    }

    func testPreprocessLeavesCodeAndRealLinksAlone() {
        let md = "`[[x]]` and [lbl](code:a.py:1)\n```\n[doc:a.md] [[y]]\n```\n[doc:b](http://x)"
        XCTAssertEqual(WikiMarkdown.preprocess(md), md)
    }

    func testWikiPagePathDetection() {
        let w = "/Users/u/Vault/wiki"
        XCTAssertTrue(WikiPaths.isWikiPage("/Users/u/Vault/wiki/payments-api/jit-hook.md", wikiDir: w))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/wiki/payments-api/index.json", wikiDir: w))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/notes/a.md", wikiDir: w))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/wiki/a.md", wikiDir: w))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/wiki/../x/a.md", wikiDir: w))
    }

    // MARK: Concept pages (shared _kavramlar)

    private func makeWiki() throws -> (wiki: String, project: String) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        let wiki = base.appendingPathComponent("wiki")
        for d in ["proj", "_kavramlar", "_attic"] {
            try FileManager.default.createDirectory(at: wiki.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return (wiki.path, wiki.appendingPathComponent("proj").path)
    }

    private func page(slug: String, file: String?) throws -> WikiPage {
        let f = file.map { #","file":"\#($0)""# } ?? ""
        let json = #"{"slug":"\#(slug)","title":"t","one_liner":"o","updated":"2026-10-10","status":"ok"\#(f)}"#
        let index = try WikiIndex.decode(Data(#"{"project":"p","groups":[{"title":"g","pages":[\#(json)]}]}"#.utf8))
        return try XCTUnwrap(index.pages.first)
    }

    private func index(dir: String) throws -> WikiIndex {
        var i = try WikiIndex.decode(Data(#"{"project":"proj","root":"/r","generated":"x","groups":[]}"#.utf8))
        i.dir = dir
        return i
    }

    private func touch(_ path: String) throws {
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
    }

    func testFileEntryResolvesRelativeToIndex() throws {
        let w = try makeWiki()
        try touch(w.wiki + "/_kavramlar/jit.md")
        let p = try page(slug: "jit", file: "../_kavramlar/jit.md")
        XCTAssertEqual(p.file, "../_kavramlar/jit.md")
        let got = try index(dir: w.project).pagePath(for: p, wikiDir: w.wiki)
        XCTAssertEqual(got.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       URL(fileURLWithPath: w.wiki + "/_kavramlar/jit.md").resolvingSymlinksInPath().path)
    }

    func testMissingFileEntryStillResolvesToInsidePath() throws {
        let w = try makeWiki()
        let p = try page(slug: "gone", file: "../_kavramlar/gone.md")
        let got = try index(dir: w.project).pagePath(for: p, wikiDir: w.wiki)
        XCTAssertNotNil(got)
        XCTAssertFalse(FileManager.default.fileExists(atPath: got ?? ""))
    }

    func testFallsBackToSlugNextToIndex() throws {
        let w = try makeWiki()
        let p = try page(slug: "local", file: nil)
        let got = try index(dir: w.project).pagePath(for: p, wikiDir: w.wiki)
        XCTAssertEqual(got.map { ($0 as NSString).lastPathComponent }, "local.md")
        XCTAssertTrue(got?.contains("/proj/") ?? false)
    }

    func testTraversalAndSymlinkEscapeAreRejected() throws {
        let w = try makeWiki()
        let index = try index(dir: w.project)
        XCTAssertNil(index.pagePath(for: try page(slug: "x", file: "../../etc/passwd"), wikiDir: w.wiki))
        XCTAssertNil(index.pagePath(for: try page(slug: "x", file: "/etc/passwd"), wikiDir: w.wiki))
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: outside) }
        try touch(outside.path + "/secret.md")
        try FileManager.default.createSymbolicLink(atPath: w.project + "/link", withDestinationPath: outside.path)
        XCTAssertNil(index.pagePath(for: try page(slug: "x", file: "link/secret.md"), wikiDir: w.wiki))
        XCTAssertNil(WikiPaths.resolveSlug("x", pageDir: w.project, wikiDir: w.wiki))
    }

    func testSymlinkedProjectFolderPagesAreNotMissing() throws {
        let w = try makeWiki()
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("real-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: target) }
        try touch(target.path + "/a.md")
        try FileManager.default.createSymbolicLink(atPath: w.wiki + "/linked", withDestinationPath: target.path)
        var idx = try index(dir: w.wiki + "/linked")
        idx.wikiRoot = w.wiki
        let p = try page(slug: "a", file: nil)
        XCTAssertNotNil(idx.pagePath(for: p))
        XCTAssertFalse(idx.isMissing(p))
        XCTAssertNil(idx.pagePath(for: try page(slug: "x", file: "../../etc/passwd")))
    }

    func testSlugResolvesOwnFolderFirstThenConcepts() throws {
        let w = try makeWiki()
        try touch(w.wiki + "/_kavramlar/shared.md")
        try touch(w.wiki + "/_kavramlar/both.md")
        try touch(w.project + "/both.md")
        func name(_ p: String?) -> String? { p.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } }
        let real = { (s: String) in URL(fileURLWithPath: s).resolvingSymlinksInPath().path }
        XCTAssertEqual(name(WikiPaths.resolveSlug("shared", pageDir: w.project, wikiDir: w.wiki)), real(w.wiki + "/_kavramlar/shared.md"))
        XCTAssertEqual(name(WikiPaths.resolveSlug("both", pageDir: w.project, wikiDir: w.wiki)), real(w.project + "/both.md"))
        XCTAssertNil(WikiPaths.resolveSlug("nope", pageDir: w.project, wikiDir: w.wiki))
        XCTAssertNil(WikiPaths.resolveSlug("../proj/both", pageDir: w.project, wikiDir: w.wiki))
    }

    func testHiddenTagsComeFromTheConfigOnly() {
        let md = "Genel bilgi [genel] ve `[genel]` ve [genel](x)."
        XCTAssertEqual(WikiMarkdown.preprocess(md), md, "no config: nothing is hidden")
        let out = WikiMarkdown.preprocess(md, config: Self.ownerConfig)
        XCTAssertEqual(out, "Genel bilgi ve `[genel]` ve [genel](x).")
        XCTAssertNil(WikiLink.parse("chip:genel:"), "an empty chip value is not a chip")
    }

    func testAtticIsNotAProjectAndConceptsArePages() throws {
        let w = try makeWiki()
        let json = #"{"project":"p","root":"/r","generated":"x","groups":[]}"#
        try Data(json.utf8).write(to: URL(fileURLWithPath: w.wiki + "/_attic/index.json"))
        try Data(json.utf8).write(to: URL(fileURLWithPath: w.project + "/index.json"))
        XCTAssertEqual(WikiIndex.loadAll(wikiDir: w.wiki).indexes.map { ($0.dir as NSString).lastPathComponent }, ["proj"])
        let v = "/Users/u/Vault/wiki"
        XCTAssertTrue(WikiPaths.isWikiPage("/Users/u/Vault/wiki/_kavramlar/jit.md", wikiDir: v))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/wiki/_attic/old.md", wikiDir: v))
        XCTAssertFalse(WikiPaths.isWikiPage("/Users/u/Vault/wiki/_attic/sub/old.md", wikiDir: v))
    }

    // MARK: Front-matter roots and qualified links

    private let home = "/Users/u"

    func testFrontMatterRootsParseBlockAndFlowForms() {
        let md = """
        ---
        title: T
        root: /Users/u/Desktop/payments-api
        roots:
          payments-api: /Users/u/Desktop/payments-api
          bree: "/Users/u/Projects/bree"
        ---
        body
        """
        let c = WikiPageContext.parse(markdown: md, home: home)
        XCTAssertEqual(c.root, "/Users/u/Desktop/payments-api")
        XCTAssertEqual(c.roots, ["payments-api": "/Users/u/Desktop/payments-api", "bree": "/Users/u/Projects/bree"])
        let flow = WikiPageContext.parse(markdown: "---\nroots: {a: /Users/u/a, b: /Users/u/b}\n---\n", home: home)
        XCTAssertEqual(flow.roots, ["a": "/Users/u/a", "b": "/Users/u/b"])
        XCTAssertNil(flow.root)
        XCTAssertEqual(WikiPageContext.parse(markdown: "no front matter", home: home), WikiPageContext(root: nil, roots: [:]))
    }

    func testRealHybridPageFrontMatterWithJSONRoots() {
        // Copy of a global-wiki concepts page: hibrit-arama-bm25-embedding-rrf.md front matter.
        let md = """
        ---
        project: payments-api
        root: /Users/me/Desktop/payments-api
        roots: {"payments-api": "/Users/me/Desktop/payments-api", "notes": "/Users/me/.local/share/notes/src"}
        title: Hibrit arama: BM25 + embedding + RRF
        group: Kavramlar
        updated: 2026-10-10
        ---
        # Hibrit
        """
        let c = WikiPageContext.parse(markdown: md, home: "/Users/me")
        XCTAssertEqual(c.root, "/Users/me/Desktop/payments-api")
        XCTAssertEqual(c.roots, ["payments-api": "/Users/me/Desktop/payments-api", "notes": "/Users/me/.local/share/notes/src"])
        XCTAssertEqual(c.codeRoot(project: "notes", openerRoot: "/x"), "/Users/me/.local/share/notes/src")
    }

    func testRootsOutsideHomeOrUnsafeAreRejected() {
        let md = "---\nroot: /etc\nroots:\n  x: /Users/u/../../etc\n  y: relative/dir\n  z: /Users/other/p\n  ok: /Users/u/p\n---\n"
        let c = WikiPageContext.parse(markdown: md, home: home)
        XCTAssertNil(c.root)
        XCTAssertEqual(c.roots, ["ok": "/Users/u/p"])
    }

    func testFrontMatterRootBeatsOpenerRoot() {
        let c = WikiPageContext(root: "/Users/u/fm", roots: [:])
        XCTAssertEqual(c.codeRoot(project: nil, openerRoot: "/Users/u/opener"), "/Users/u/fm")
        let none = WikiPageContext(root: nil, roots: [:])
        XCTAssertEqual(none.codeRoot(project: nil, openerRoot: "/Users/u/opener"), "/Users/u/opener")
        XCTAssertNil(none.codeRoot(project: nil, openerRoot: nil))
    }

    func testQualifiedProjectResolvesOnlyFromRoots() {
        let c = WikiPageContext(root: "/Users/u/fm", roots: ["bree": "/Users/u/Projects/bree"])
        XCTAssertEqual(c.codeRoot(project: "bree", openerRoot: "/Users/u/opener"), "/Users/u/Projects/bree")
        XCTAssertNil(c.codeRoot(project: "unknown", openerRoot: "/Users/u/opener"))
    }

    func testQualifiedLinksParse() {
        XCTAssertEqual(WikiLink.parse("code:@bree/Sources/a.swift#Foo"),
                       .qualifiedCode(project: "bree", path: "Sources/a.swift", line: nil, symbol: "Foo"))
        XCTAssertEqual(WikiLink.parse("code:@bree/Sources/a.swift:12"),
                       .qualifiedCode(project: "bree", path: "Sources/a.swift", line: 12, symbol: nil))
        XCTAssertNil(WikiLink.parse("code:@bree/../x.swift:1"))
        XCTAssertNil(WikiLink.parse("code:@/a.swift"))
    }

    func testUnknownProjectLinkBecomesBrokenChip() {
        let md = "[a](code:@bree/f.swift#S) [b](code:@nope/f.swift:3) [c](code:f.swift:1)"
        let out = WikiMarkdown.preprocess(md, roots: ["bree"])
        XCTAssertTrue(out.contains("[a](code:@bree/f.swift#S)"), out)
        XCTAssertTrue(out.contains("](chip:broken:"), out)
        XCTAssertFalse(out.contains("code:@nope"), out)
        XCTAssertTrue(out.contains("[c](code:f.swift:1)"), out)
    }

    // MARK: Index decoding (copy of a global-wiki project index.json)

    func testDecodesRealIndexSample() throws {
        let index = try WikiIndex.decode(Data(Self.sampleIndex.utf8))
        XCTAssertEqual(index.project, "payments-api")
        XCTAssertEqual(index.root, "/Users/me/Desktop/payments-api")
        XCTAssertEqual(index.groups.count, 1)
        XCTAssertEqual(index.groups[0].title, "Hook'lar")
        XCTAssertEqual(index.groups[0].pages.map(\.slug), ["agent-spawn-hook", "jit-hook"])
        XCTAssertEqual(index.groups[0].pages[1].updated, "2026-10-09")
        XCTAssertFalse(index.groups[0].pages[1].isStale)
        XCTAssertTrue(index.groups[0].pages[1].oneLiner.hasPrefix("payments-api'in `jit_decide`"))
    }

    func testUnknownStatusDoesNotBreakDecoding() throws {
        let json = #"{"project":"p","root":"/p","generated":"x","groups":[{"title":"g","pages":[{"slug":"s","title":"t","one_liner":"o","updated":"2026-01-01","status":"stale"},{"slug":"u","title":"t","one_liner":"o","updated":"2026-01-01","status":"weird"}]}]}"#
        let index = try WikiIndex.decode(Data(json.utf8))
        XCTAssertTrue(index.groups[0].pages[0].isStale)
        XCTAssertFalse(index.groups[0].pages[1].isStale)
    }

    private static let sampleIndex = """
{
  "project": "payments-api",
  "root": "/Users/me/Desktop/payments-api",
  "generated": "2026-10-09",
  "groups": [
    {
      "title": "Hook'lar",
      "pages": [
        {
          "slug": "agent-spawn-hook",
          "title": "Agent spawn hook",
          "one_liner": "payments-api, `coder`/`deep`/`worker` alt-ajanları başlatılırken brief'e kod konumu listesi ekler; amaç ajanın gereksiz arama yapmadan doğru dosyalara gitmesi ve token tasarrufu.",
          "updated": "2026-10-09",
          "status": "ok"
        },
        {
          "slug": "jit-hook",
          "title": "JIT hook",
          "one_liner": "payments-api'in `jit_decide` hook'u, ajan bir identifier'ı grep'lediğinde veya büyük bir kod dosyasını bütün okumaya çalıştığında, çağrı anında index'ten bilgi ekler; bunu ajanın daha az tur harcaması için yaptık.",
          "updated": "2026-10-09",
          "status": "ok"
        }
      ]
    }
  ]
}

"""

    // MARK: bree-wiki/1 contract

    func testIndexIsLenientAndNamesTheMissingField() throws {
        let minimal = try WikiIndex.decode(Data(#"{"project":"p","groups":[{"title":"G","pages":[{"slug":"a","title":"A"}]}]}"#.utf8))
        XCTAssertEqual(minimal.pages.first?.oneLiner, "")
        XCTAssertEqual(minimal.pages.first?.status, "ok")
        XCTAssertEqual(minimal.root, "")
        XCTAssertEqual(try WikiIndex.decode(Data(#"{"schema":"bree-wiki/1","project":"p","lang":"tr"}"#.utf8)).lang, "tr")
        func message(_ json: String) -> String? {
            do { _ = try WikiIndex.decode(Data(json.utf8)); return nil } catch { return (error as? WikiIndexError)?.message }
        }
        XCTAssertEqual(message(#"{"groups":[]}"#), "\"project\" is missing")
        XCTAssertEqual(message(#"{"project":"p","groups":[{"pages":[]}]}"#), "groups[0]: \"title\" is missing")
        XCTAssertEqual(message(#"{"project":"p","groups":[{"title":"G","pages":[{"slug":"a"}]}]}"#), "groups[0].pages[0]: \"title\" is missing")
        XCTAssertEqual(message(#"{"project":"p","groups":[{"title":"G","pages":[{"title":"A"}]}]}"#), "groups[0].pages[0]: \"slug\" is missing")
        XCTAssertEqual(message("{nope"), "it is not valid JSON")
    }

    func testLookupPrefersTheRepoLocalWikiAndKeepsBrokenIndexesVisible() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("wiki-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let repo = base.appendingPathComponent("repo").path
        let global = base.appendingPathComponent("global").path
        for d in [repo + "/.bree/wiki", global + "/p", global + "/broken"] {
            try FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        let pages = #"{"title":"G","pages":[{"slug":"a","title":"A"}]}"#
        try #"{"project":"global-p","root":"\#(repo)","groups":[\#(pages)]}"#.write(toFile: global + "/p/index.json", atomically: true, encoding: .utf8)
        try #"{"project":"x","root":"\#(repo)","groups":[{"pages":[]}]}"#.write(toFile: global + "/broken/index.json", atomically: true, encoding: .utf8)
        var load = WikiLibrary.load(repoRoot: repo, globalDir: global)
        XCTAssertNil(load.local)
        XCTAssertEqual(load.project(for: repo)?.project, "global-p", "no local wiki: the global one")
        XCTAssertEqual(load.issues.map(\.message), ["groups[0]: \"title\" is missing"], "a broken index is an error row, not dropped")
        try #"{"project":"local-p","groups":[\#(pages)]}"#.write(toFile: repo + "/.bree/wiki/index.json", atomically: true, encoding: .utf8)
        load = WikiLibrary.load(repoRoot: repo, globalDir: global)
        XCTAssertEqual(load.project(for: repo)?.project, "local-p", "repo-local first")
        XCTAssertEqual(load.local?.root, repo, "a local index without root belongs to its repo")
        XCTAssertTrue(WikiPaths.isWikiPage(repo + "/.bree/wiki/a.md", wikiDir: global))
        XCTAssertTrue(WikiPaths.isWikiPage(repo + "/.bree/wiki/sub/b.md", wikiDir: global))
        XCTAssertFalse(WikiPaths.isWikiPage(repo + "/other/a.md", wikiDir: global))
        XCTAssertEqual(WikiPaths.localRoot(containing: repo + "/.bree/wiki/sub/b.md"), repo + "/.bree/wiki")
        // An issue of another project's root stays quiet.
        XCTAssertFalse(WikiIssue(path: "/x", message: "m", root: "/elsewhere").isRelevant(to: repo))
        XCTAssertTrue(WikiIssue(path: "/x", message: "m", root: nil).isRelevant(to: repo))
    }

    func testWikiFolderSettingDefaultsToTheBreeHome() {
        let defaults = UserDefaults(suiteName: "wiki-\(UUID().uuidString)")!
        let home = URL(fileURLWithPath: "/Users/u")
        XCTAssertEqual(WikiFolderSetting.resolved(defaults: defaults, identity: BreeIdentity(bundleIdentifier: "com.bree.app"), homeDirectory: home),
                       "/Users/u/.bree/wiki")
        XCTAssertEqual(WikiFolderSetting.resolved(defaults: defaults, identity: BreeIdentity(bundleIdentifier: "com.bree.app.debug.bree"), homeDirectory: home),
                       "/Users/u/.bree-dev/wiki")
        defaults.set("/Users/u/notes/wiki/", forKey: WikiFolderSetting.defaultsKey)
        XCTAssertEqual(WikiFolderSetting.resolved(defaults: defaults, homeDirectory: home), "/Users/u/notes/wiki")
    }

    func testConfigDeclaresChipsAndDropsInvalidEntries() {
        let config = Self.ownerConfig
        XCTAssertEqual(Set(config.chips.keys), ["m", "notes"])
        XCTAssertEqual(config.hiddenTags, ["genel"])
        XCTAssertEqual(config.symbolArguments(symbol: "Foo"), ["my-index", "def", "Foo"])
        XCTAssertNil(config.symbolArguments(symbol: "--evil"))
        XCTAssertNil(config.symbolArguments(symbol: "a b"))
        let bad = WikiConfig.parse(Data(#"{"chips":{"x":{"argv":["/bin/sh","{value}"]},"y":{"argv":["t"]},"commit":{"argv":["t","{value}"]},"z":{"argv":["t","{value}"],"valuePattern":"("}}}"#.utf8))
        XCTAssertTrue(bad.chips.isEmpty, "absolute tool, no {value}, built-in scheme and a bad regex are all dropped")
        XCTAssertEqual(WikiConfig.parse(Data("nonsense".utf8)), WikiConfig())
    }

    func testChipWithoutHandlerIsInert() {
        let out = WikiMarkdown.preprocess("see [m:12] and [notes:x]")
        XCTAssertTrue(out.contains("[m:12](chip:inert:12 \""), out)
        XCTAssertFalse(out.contains("(chip:m:"))
        XCTAssertEqual(WikiLink.parse("chip:inert:12"), .chip(kind: "inert", value: "12"))
        XCTAssertFalse(WikiChip.hasHandler(kind: "m", config: .empty))
        XCTAssertTrue(WikiChip.hasHandler(kind: "commit", config: .empty))
        XCTAssertTrue(WikiChip.hasHandler(kind: "m", config: Self.ownerConfig))
    }

    func testDeclaredChipArgvAndDefaultValueValidation() throws {
        let config = WikiConfig.parse(Data(#"{"chips":{"jira":{"argv":["jira","view","{value}"],"title":"Issue {value}"}}}"#.utf8))
        XCTAssertEqual(WikiChip.previewCommand(kind: "jira", value: "ABC-12", root: nil, config: config),
                       .init(tool: "jira", arguments: ["view", "ABC-12"], directory: nil))
        XCTAssertNil(WikiChip.previewCommand(kind: "jira", value: "-x", root: nil, config: config))
        XCTAssertNil(WikiChip.previewCommand(kind: "jira", value: "a;b", root: nil, config: config))
        XCTAssertEqual(try XCTUnwrap(config.chips["jira"]).pageTitle(value: "ABC-12"), "Issue ABC-12")
    }

    func testTrustKeyIsPerFolderAndArgvAndStoredOnce() {
        let a = WikiTrust.key(folder: "/r/.bree/wiki", argv: ["t", "{value}"])
        XCTAssertNotEqual(a, WikiTrust.key(folder: "/q/.bree/wiki", argv: ["t", "{value}"]))
        XCTAssertNotEqual(a, WikiTrust.key(folder: "/r/.bree/wiki", argv: ["t", "x", "{value}"]))
        let defaults = UserDefaults(suiteName: "wiki-\(UUID().uuidString)")!
        XCTAssertFalse(WikiTrust.isApproved(folder: "/r/.bree/wiki", argv: ["t", "{value}"], defaults: defaults))
        WikiTrust.approve(folder: "/r/.bree/wiki", argv: ["t", "{value}"], defaults: defaults)
        WikiTrust.approve(folder: "/r/.bree/wiki", argv: ["t", "{value}"], defaults: defaults)
        XCTAssertTrue(WikiTrust.isApproved(folder: "/r/.bree/wiki", argv: ["t", "{value}"], defaults: defaults))
        XCTAssertEqual(defaults.stringArray(forKey: WikiTrust.defaultsKey)?.count, 1)
    }

    @MainActor
    func testAuthorizeAsksOnceForAnUntrustedConfig() {
        let defaults = UserDefaults(suiteName: "wiki-\(UUID().uuidString)")!
        let local = WikiConfig(folder: "/r/.bree/wiki", isTrusted: false)
        var asked = 0
        XCTAssertFalse(WikiTrust.authorize(config: local, argv: ["t", "{value}"], defaults: defaults) { _, _ in asked += 1; return false })
        XCTAssertTrue(WikiTrust.authorize(config: local, argv: ["t", "{value}"], defaults: defaults) { _, _ in asked += 1; return true })
        XCTAssertTrue(WikiTrust.authorize(config: local, argv: ["t", "{value}"], defaults: defaults) { _, _ in asked += 1; return false })
        XCTAssertEqual(asked, 2, "the approval is remembered")
        XCTAssertTrue(WikiTrust.authorize(config: WikiConfig(folder: "/g", isTrusted: true), argv: ["t"], defaults: defaults) { _, _ in asked += 1; return false })
        XCTAssertEqual(asked, 2, "the global folder is never asked")
    }

    func testToolLookupPrefersLoginPathThenFixedFolders() {
        let present: Set<String> = ["/login/bin/notes", "/fixed/bin/notes", "/fixed/bin/git"]
        let exists: (String) -> Bool = { present.contains($0) }
        XCTAssertEqual(WikiToolLookup.resolve("notes", loginPath: ["/login/bin"], fixed: ["/fixed/bin"], isExecutable: exists), "/login/bin/notes")
        XCTAssertEqual(WikiToolLookup.resolve("git", loginPath: ["/login/bin"], fixed: ["/fixed/bin"], isExecutable: exists), "/fixed/bin/git")
        XCTAssertNil(WikiToolLookup.resolve("nope", loginPath: ["/login/bin"], fixed: ["/fixed/bin"], isExecutable: exists))
        XCTAssertNil(WikiToolLookup.resolve("../notes", loginPath: ["/login/bin"], fixed: [], isExecutable: { _ in true }))
    }
}

