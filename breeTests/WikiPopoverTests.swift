import Foundation
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class WikiPopoverTests: XCTestCase {
    // MARK: Memory chip pages

    func testMemoryHeaderParsesAgentReplyWithDate() throws {
        let text = "4504+1|agent (2026-10-05T16:13:43+03:00)\nagent: payments-api'in ölçümü geldi.\n\n| a | b |\n|---|---|"
        let header = try XCTUnwrap(WikiMemory.parse(text))
        XCTAssertEqual(header.id, "4504")
        XCTAssertEqual(header.kind, .agent)
        XCTAssertEqual(header.body, "payments-api'in ölçümü geldi.\n\n| a | b |\n|---|---|", "header line and `kind:` label are dropped")
        let date = try XCTUnwrap(header.date)
        let tz = try XCTUnwrap(TimeZone(secondsFromGMT: 3 * 3600))
        XCTAssertEqual(WikiMemory.dateText(date, locale: Locale(identifier: "tr_TR"), timeZone: tz), "5 Eki 2026 16:13")
    }

    func testMemoryHeaderKinds() throws {
        XCTAssertEqual(try XCTUnwrap(WikiMemory.parse("1+1|user (2026-04-10T19:29:11+03:00)\nuser: merhaba")).kind, .user)
        XCTAssertEqual(try XCTUnwrap(WikiMemory.parse("1+1|system (2026-04-10T19:29:11+03:00)\nsystem: x")).kind, .note, "unknown kinds are a neutral note")
    }

    func testDeclaredAgentKindMapsToAgent() throws {
        XCTAssertEqual(try XCTUnwrap(WikiMemory.parse("1+1|bot\nbot: x")).kind, .note, "undeclared")
        XCTAssertEqual(try XCTUnwrap(WikiMemory.parse("1+1|assistant\nassistant: x")).kind, .agent, "built-in")
        let config = WikiConfig.parse(Data(#"{"agentKinds":["bot"]}"#.utf8))
        XCTAssertEqual(try XCTUnwrap(WikiMemory.parse("1+1|bot\nbot: x", agentKinds: config.agentKinds)).kind, .agent)
    }

    func testMemoryHeaderWithoutDateOrBody() throws {
        let header = try XCTUnwrap(WikiMemory.parse("7+1|user"))
        XCTAssertNil(header.date)
        XCTAssertEqual(header.body, "")
        XCTAssertEqual(WikiMemory.title(kind: .user, date: nil), WikiMemory.label(.user), "no date: the label alone")
    }

    func testMalformedMemoryHeaderIsNotParsedAndNeverShownRaw() {
        XCTAssertNil(WikiMemory.parse("just some text\nmore"))
        XCTAssertNil(WikiMemory.parse("4504+1|agent (not a date"))
        XCTAssertNil(WikiMemory.parse(""))
        let page = WikiMemory.page(kind: "m", value: "1", text: "plain text", config: WikiSupportTests.ownerConfig)
        XCTAssertEqual(page.title, "Note", "a memory chip without a header keeps the title its config declares")
        XCTAssertEqual(page.markdown, "plain text")
        let bad = WikiMemory.parse("4504+1|agent (nope)\nagent: x")
        XCTAssertNil(bad?.date, "an unreadable date is dropped, the header is still consumed")
    }

    func testMemoryPagePathRoundTripAndFailure() {
        let path = WikiMemory.pseudoPath(kind: "m", value: "4504")
        let chip = WikiMemory.chip(fromPath: path)
        XCTAssertEqual(chip?.kind, "m")
        XCTAssertEqual(chip?.value, "4504")
        XCTAssertNil(WikiMemory.chip(fromPath: "/Users/x/wiki/a.md"))
        XCTAssertFalse(WikiMemory.page(kind: "m", value: "1", text: nil).markdown.isEmpty)
        let commit = WikiMemory.page(kind: "commit", value: "8dfd7ce00abc", text: "8dfd7ce fix\n a | 2 +-")
        XCTAssertTrue(commit.markdown.hasPrefix("```text\n"))
    }

    func testBackStackRetitlesTheTopEntry() {
        var stack = WikiBackStack()
        stack.push(.init(path: "/w/a.md", title: "A"))
        stack.push(.init(path: "memory:m:1", title: "Note"))
        stack.retitleCurrent("Agent reply")
        XCTAssertEqual(stack.current?.title, "Agent reply")
        XCTAssertEqual(stack.previousTitle, "A")
    }

    // MARK: Back stack

    func testBackStackPushPopAndPreviousTitle() {
        var stack = WikiBackStack()
        XCTAssertTrue(stack.isEmpty)
        XCTAssertNil(stack.pop())
        let a = WikiBackStack.Entry(path: "/w/a.md", title: "A")
        let b = WikiBackStack.Entry(path: "/w/b.md", title: "B")
        stack.push(a)
        XCTAssertNil(stack.previousTitle, "first page goes back to the list")
        stack.push(a)
        XCTAssertEqual(stack.depth, 1, "the page already on top is not pushed twice")
        stack.push(b)
        XCTAssertEqual(stack.current, b)
        XCTAssertEqual(stack.previousTitle, "A")
        XCTAssertEqual(stack.pop(), b)
        XCTAssertEqual(stack.current, a)
        XCTAssertEqual(stack.pop(), a)
        XCTAssertTrue(stack.isEmpty)
    }

    func testWikilinkResolvesToStackEntryInPageFolderThenConcepts() throws {
        let wiki = try makeWiki()
        try "x".write(toFile: wiki + "/proj/a.md", atomically: true, encoding: .utf8)
        try "x".write(toFile: wiki + "/_kavramlar/c.md", atomically: true, encoding: .utf8)
        var stack = WikiBackStack()
        for slug in ["a", "c"] {
            let path = try XCTUnwrap(WikiPaths.resolveSlug(slug, pageDir: wiki + "/proj", wikiDir: wiki))
            stack.push(.init(path: path, title: slug))
        }
        XCTAssertEqual(stack.depth, 2)
        XCTAssertTrue(try XCTUnwrap(stack.current).path.hasSuffix("/_kavramlar/c.md"))
        XCTAssertEqual(WikiLink.parse("wiki:c"), .page(slug: "c"))
    }

    // MARK: Scope

    private func index(_ project: String, pages: Int) throws -> WikiIndex {
        let list = (0..<pages).map {
            #"{"slug":"p\#($0)","title":"P","one_liner":"o","updated":"2026-10-10","status":"ok"}"#
        }.joined(separator: ",")
        let json = #"{"project":"\#(project)","root":"/r/\#(project)","generated":"x","groups":[{"title":"G","pages":[\#(list)]}]}"#
        return try WikiIndex.decode(Data(json.utf8))
    }

    func testScopesAndDefaultRule() throws {
        let project = try index("payments-api", pages: 2)
        let empty = try index("payments-api", pages: 0)
        let general = try index("_genel", pages: 1)
        XCTAssertEqual(WikiBrowse.scopes(project: project, general: general), [.project, .general])
        XCTAssertEqual(WikiBrowse.scopes(project: nil, general: general), [.general], "no project: only General")
        XCTAssertEqual(WikiBrowse.scopes(project: project, general: nil), [.project], "missing _genel is hidden")
        XCTAssertEqual(WikiBrowse.defaultScope(project: project, general: general), .project)
        XCTAssertEqual(WikiBrowse.defaultScope(project: empty, general: general), .general, "empty project: General")
        XCTAssertEqual(WikiBrowse.defaultScope(project: nil, general: general), .general)
        XCTAssertEqual(WikiBrowse.resolvedScope(.general, project: project, general: general), .general)
        XCTAssertEqual(WikiBrowse.resolvedScope(.general, project: project, general: nil), .project)
        XCTAssertEqual(WikiBrowse.index(for: .general, project: project, general: general)?.project, "_genel")
    }

    func testGeneralIndexHasNullRootAndLoadsFromGenelFolder() throws {
        let wiki = try makeWiki()
        try FileManager.default.createDirectory(atPath: wiki + "/_genel", withIntermediateDirectories: true)
        XCTAssertNil(WikiIndex.loadGeneral(wikiDir: wiki), "missing until it exists")
        let json = #"{"project":"_genel","root":null,"generated":"x","groups":[{"title":"G","pages":[{"slug":"s","title":"S","one_liner":"o","updated":"u","status":"ok"}]}]}"#
        try json.write(toFile: wiki + "/_genel/index.json", atomically: true, encoding: .utf8)
        let general = try XCTUnwrap(WikiIndex.loadGeneral(wikiDir: wiki))
        XCTAssertEqual(general.root, "")
        XCTAssertEqual(general.dir, wiki + "/_genel")
        XCTAssertNil(WikiProject.match([general], path: "/anything"), "a null root never matches a project")
        XCTAssertTrue(WikiIndex.loadAll(wikiDir: wiki).indexes.isEmpty, "_genel is not a project")
        XCTAssertTrue(WikiPaths.isWikiPage(wiki + "/_genel/s.md", wikiDir: wiki))
    }

    // MARK: [src:] chips and GitHub

    func testSourceChipParsesAndRewrites() {
        let md = "see [src:payments-api:src/a_b.rs:42] now"
        let out = WikiMarkdown.preprocess(md)
        XCTAssertEqual(out, "see [src:payments-api:src/a_b.rs:42](src:payments-api:src%2Fa_b.rs:42) now")
        XCTAssertEqual(WikiLink.parse("src:payments-api:src%2Fa_b.rs:42"), .source(slug: "payments-api", path: "src/a_b.rs", line: 42))
        XCTAssertNil(WikiLink.parse("src:payments-api:..%2Fx:1"))
        XCTAssertNil(WikiLink.parse("src:hint%2Fmap:a:1"))
        XCTAssertNil(WikiLink.parse("src:payments-api:a:0"))
        XCTAssertNil(WikiLink.parse("src:payments-api:a"))
        XCTAssertEqual(WikiLink.parse("srcweb:s:a:3"), .sourceWeb(slug: "s", path: "a", line: 3))
        // Inside a code span or fence it stays text.
        XCTAssertEqual(WikiMarkdown.preprocess("`[src:s:a:1]`"), "`[src:s:a:1]`")
    }

    func testGitHubLinkOnlyWithUrlAndSha() {
        let page = """
        ---
        url: https://github.com/o/r
        sha: 0123abc
        ---
        body
        """
        let ctx = WikiPageContext.parse(markdown: page)
        XCTAssertEqual(ctx.githubURL(relpath: "src/m.rs", line: 7)?.absoluteString,
                       "https://github.com/o/r/blob/0123abc/src/m.rs#L7")
        let noSha = WikiPageContext.parse(markdown: "---\nurl: https://github.com/o/r\n---\n")
        XCTAssertNil(noSha.githubURL(relpath: "a", line: 1))
        let noURL = WikiPageContext.parse(markdown: "---\nsha: 0123abc\n---\n")
        XCTAssertNil(noURL.githubURL(relpath: "a", line: 1))
        XCTAssertNil(ctx.githubURL(relpath: "../x", line: 1))
        let http = WikiPageContext.parse(markdown: "---\nurl: javascript:alert(1)\nsha: 0123abc\n---\n")
        XCTAssertNil(http.githubURL(relpath: "a", line: 1))
        XCTAssertNil(WikiPageContext.parse(markdown: "---\nurl: https://x.io/r\nsha: zzzzzzz\n---\n").githubURL(relpath: "a", line: 1))
        // The extra link is emitted only when the page has url + sha.
        XCTAssertTrue(WikiMarkdown.preprocess("[src:s:a:1]", github: true).contains("(srcweb:s:a:1)"))
        XCTAssertFalse(WikiMarkdown.preprocess("[src:s:a:1]", github: false).contains("srcweb"))
    }

    func testSnapFileIsConfinedToItsSlugFolder() throws {
        let wiki = try makeWiki()
        let snap = wiki + "/_kaynaklar/snap/s"
        try FileManager.default.createDirectory(atPath: snap + "/src", withIntermediateDirectories: true)
        try "fn main() {}".write(toFile: snap + "/src/m.rs", atomically: true, encoding: .utf8)
        try "secret".write(toFile: wiki + "/secret.md", atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: snap + "/link.md", withDestinationPath: wiki + "/secret.md")
        let found = try XCTUnwrap(WikiPaths.snapFile(slug: "s", relpath: "src/m.rs", wikiDir: wiki))
        XCTAssertTrue(found.hasSuffix("/_kaynaklar/snap/s/src/m.rs"))
        XCTAssertTrue(WikiPaths.isSnapFile(found, wikiDir: wiki))
        XCTAssertNil(WikiPaths.snapFile(slug: "s", relpath: "link.md", wikiDir: wiki), "symlink escape")
        XCTAssertNil(WikiPaths.snapFile(slug: "s", relpath: "../s/src/m.rs", wikiDir: wiki))
        XCTAssertNil(WikiPaths.snapFile(slug: "s", relpath: "src", wikiDir: wiki), "directory")
        XCTAssertNil(WikiPaths.snapFile(slug: "s", relpath: "nope.rs", wikiDir: wiki))
        XCTAssertFalse(WikiPaths.isWikiPage(wiki + "/_kaynaklar/snap/s/README.md", wikiDir: wiki), "snap is never a page")
        XCTAssertFalse(WikiPaths.isWikiPage(wiki + "/_kaynaklar/s.md", wikiDir: wiki))
    }

    // MARK: Math

    private func math(_ text: String) -> String { WikiMarkdown.mathMarker + text }

    func testInlineAndDisplayMathExtraction() {
        let out = WikiMarkdown.preprocess("Euler $e^{i\\pi}+1=0$ and $a_b$ done")
        XCTAssertEqual(out, "Euler `\(math("i:e%5E%7Bi%5Cpi%7D%2B1%3D0"))` and `\(math("i:a_b"))` done")
        let display = WikiMarkdown.preprocess("before\n$$\n\\begin{aligned}x&=1\\\\y&=2\\end{aligned}\n$$\nafter")
        XCTAssertEqual(display.components(separatedBy: "\n").filter { $0.hasPrefix("`" + WikiMarkdown.mathMarker + "d:") }.count, 1)
        XCTAssertTrue(display.contains("before\n"))
        XCTAssertTrue(display.hasSuffix("after"))
        XCTAssertEqual(WikiMarkdown.preprocess("$$ x^2 $$"), "\n`\(math("d:x%5E2"))`\n")
    }

    func testMathSkipsEscapedDollarsCodeAndFences() {
        XCTAssertEqual(WikiMarkdown.preprocess("costs \\$5 and \\$6 total"), "costs \\$5 and \\$6 total")
        XCTAssertEqual(WikiMarkdown.preprocess("it is $5 and $6 here"), "it is $5 and $6 here", "prices are not math")
        XCTAssertEqual(WikiMarkdown.preprocess("`$a$ and $b$`"), "`$a$ and $b$`")
        XCTAssertEqual(WikiMarkdown.preprocess("```\n$x$\n$$\ny\n$$\n```"), "```\n$x$\n$$\ny\n$$\n```")
        XCTAssertEqual(WikiMarkdown.preprocess("$$\nunclosed"), "$$\nunclosed")
        XCTAssertEqual(WikiMarkdown.preprocess("a `code $x$` then $y$"), "a `code $x$` then `\(math("i:y"))`")
        // A link-looking tag inside a formula is not rewritten.
        XCTAssertFalse(WikiMarkdown.preprocess("$[[a]]$").contains("wiki:"))
    }

    // MARK: Anchor map

    func testAnchorMapUnqualifiedQualifiedOtherRepoAndEmpty() throws {
        let json = #"{"project":"hm","root":"/r/hm","generated":"x","groups":[{"title":"G","pages":[{"slug":"own","title":"Own","one_liner":"o","updated":"u","status":"ok"},{"slug":"fm","title":"FM","one_liner":"o","updated":"u","status":"ok"},{"slug":"q","title":"Q","one_liner":"o","updated":"u","status":"ok"},{"slug":"dup","title":"Dup","one_liner":"o","updated":"u","status":"ok"}]}]}"#
        let index = try WikiIndex.decode(Data(json.utf8))
        let home = NSHomeDirectory()
        let pages = [
            "own": "see [hook](code:hm/jit.py#cmd_jit_hook) and [l](code:hm/x.py:10)\n```\n[no](code:fenced.py#sym)\n```",
            // Front-matter root points at another repo: its unqualified links are excluded.
            "fm": "---\nroot: \(home)/other\n---\n[a](code:o.py#other_sym)",
            "q": "---\nroots: {hm: /r/hm, notes: \(home)/notes}\n---\n[b](code:@hm/hm/q.py#qsym) [c](code:@notes/b.py#bsym) [d](code:@ghost/g.py#gsym)",
            "dup": "[x](code:hm/jit.py#cmd_jit_hook)",
        ]
        let map = WikiAnchors.build(index: index, repoRoot: "/r/hm") { pages[$0.slug] }
        XCTAssertEqual(map["hm/jit.py#cmd_jit_hook"], .init(slug: "own", title: "Own"), "unqualified, first page wins")
        XCTAssertNil(map["o.py#other_sym"], "front-matter root is another repo")
        XCTAssertNil(map["fenced.py#sym"])
        XCTAssertNil(map["hm/x.py:10"], "line links are not symbol anchors")
        // The @project root /r/hm is outside home, so the context drops it: only home-confined roots count.
        XCTAssertNil(map["hm/q.py#qsym"])
        XCTAssertNil(map["b.py#bsym"], "roots[notes] is another repo")
        XCTAssertNil(map["g.py#gsym"], "unknown project")
        let forNotes = WikiAnchors.build(index: index, repoRoot: home + "/notes") { pages[$0.slug] }
        XCTAssertEqual(forNotes["b.py#bsym"], .init(slug: "q", title: "Q"), "@project link whose root is this repo")
        XCTAssertEqual(forNotes.count, 1)
        XCTAssertEqual(WikiAnchors.build(index: index, repoRoot: "/r/hm") { _ in nil }, [:], "no readable pages")
        let emptyIndex = try WikiIndex.decode(Data(#"{"project":"e","root":"/r/e","generated":"x","groups":[]}"#.utf8))
        let emptyMap = WikiAnchors.build(index: emptyIndex, repoRoot: "/r/e") { _ in "[a](code:x#y)" }
        XCTAssertEqual(WikiAnchors.json(emptyMap), "{}")
        XCTAssertEqual(WikiAnchors.json(map), #"{"hm/jit.py#cmd_jit_hook":{"slug":"own","title":"Own"}}"#)
    }

    // MARK: Popover size

    func testClampMinimumMaximumAndSmallScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertEqual(PopoverSizing.clamp(CGSize(width: 100, height: 100), visible: screen), CGSize(width: 480, height: 360))
        XCTAssertEqual(PopoverSizing.clamp(CGSize(width: 5000, height: 5000), visible: screen), CGSize(width: 1408, height: 868))
        XCTAssertEqual(PopoverSizing.clamp(CGSize(width: 700, height: 500), visible: screen), CGSize(width: 700, height: 500))
        XCTAssertEqual(PopoverSizing.clamp(CGSize(width: 700, height: 800), visible: screen, maxHeight: 600).height, 600)
        let tiny = CGRect(x: 0, y: 0, width: 400, height: 300)
        XCTAssertEqual(PopoverSizing.clamp(CGSize(width: 900, height: 900), visible: tiny), CGSize(width: 368, height: 268))
    }

    func testSizeIsPersistedPerPopoverAndClampedOnLoad() throws {
        let suite = "bree.test.popover.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertNil(PopoverSizing.load(name: "wiki", visible: screen, defaults: defaults))
        PopoverSizing.save(CGSize(width: 800, height: 600), name: "wiki", defaults: defaults)
        PopoverSizing.save(CGSize(width: 520, height: 420), name: "architecture", defaults: defaults)
        XCTAssertEqual(PopoverSizing.load(name: "wiki", visible: screen, defaults: defaults), CGSize(width: 800, height: 600))
        XCTAssertEqual(PopoverSizing.load(name: "architecture", visible: screen, defaults: defaults), CGSize(width: 520, height: 420))
        // A smaller screen later (external display gone) clamps the remembered size.
        let small = CGRect(x: 0, y: 0, width: 700, height: 500)
        XCTAssertEqual(PopoverSizing.load(name: "wiki", visible: small, defaults: defaults), CGSize(width: 668, height: 468))
    }

    // MARK: Helpers

    private func makeWiki() throws -> String {
        let root = NSTemporaryDirectory() + "wikitest-\(UUID().uuidString)"
        for sub in ["proj", "_kavramlar"] {
            try FileManager.default.createDirectory(atPath: root + "/" + sub, withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: root) }
        return URL(fileURLWithPath: root).resolvingSymlinksInPath().path
    }

    // MARK: GUI fix 1: chips and wiki type size

    private func tempHome() throws -> String {
        let dir = NSTemporaryDirectory() + "wikichip-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir + "/docs/state", withIntermediateDirectories: true)
        try "x".write(toFile: dir + "/docs/state/a.md", atomically: true, encoding: .utf8)
        return (dir as NSString).resolvingSymlinksInPath
    }

    func testAbsoluteDocPathUnderHomeResolvesToFile() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let file = home + "/docs/state/a.md"
        XCTAssertEqual(WikiChip.docPath(value: file, root: nil, home: home), file)
        XCTAssertEqual(WikiChip.docPath(value: "docs/state/a.md", root: home, home: home), file)
    }

    func testDocPathRejectsOutsideHomeDotDotAndDirectories() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        XCTAssertNil(WikiChip.docPath(value: "/etc/hosts", root: nil, home: home))
        XCTAssertNil(WikiChip.docPath(value: home + "/docs/../docs/state/a.md", root: nil, home: home))
        XCTAssertNil(WikiChip.docPath(value: "../x.md", root: home, home: home))
        XCTAssertNil(WikiChip.docPath(value: home + "/docs", root: nil, home: home))
        XCTAssertNil(WikiChip.docPath(value: "docs", root: home, home: home))
        XCTAssertNil(WikiChip.docPath(value: home + "/missing.md", root: nil, home: home))
        XCTAssertNil(WikiChip.docPath(value: "docs/state/a.md", root: nil, home: home), "relative needs a root")
    }

    func testDocPathRejectsSymlinkEscapingHome() throws {
        let home = try tempHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createSymbolicLink(atPath: home + "/link.md", withDestinationPath: "/etc/hosts")
        XCTAssertNil(WikiChip.docPath(value: home + "/link.md", root: nil, home: home))
    }

    func testChipLabels() {
        XCTAssertEqual(WikiChip.label(kind: "doc", value: "/Users/x/docs/state/2026-10-06-e30-recall.md"), "2026-10-06-e30-recall.md")
        XCTAssertEqual(WikiChip.label(kind: "doc", value: "docs/a.md"), "a.md")
        XCTAssertEqual(WikiChip.label(kind: "m", value: "4504"), "m:4504")
        XCTAssertEqual(WikiChip.label(kind: "notes", value: "obs-1"), "notes:obs-1")
        XCTAssertEqual(WikiChip.label(kind: "commit", value: "932a60981c0ffee"), "932a609")
    }

    func testPreprocessEmitsShortLabels() {
        let out = WikiMarkdown.preprocess("[doc:docs/state/a.md] [m:4504] [commit:932a60981c0ffee]\n", config: WikiSupportTests.ownerConfig)
        XCTAssertTrue(out.contains("[a.md](chip:doc:docs%2Fstate%2Fa.md)"), out)
        XCTAssertTrue(out.contains("[m:4504](chip:m:4504)"), out)
        XCTAssertTrue(out.contains("[932a609](chip:commit:932a60981c0ffee)"), out)
    }

    func testPreviewCommandsAreArgvOnly() {
        let owner = WikiSupportTests.ownerConfig
        XCTAssertEqual(WikiChip.previewCommand(kind: "m", value: "4504", root: nil, config: owner),
                       .init(tool: "notes", arguments: ["zoom", "4504", "1"], directory: nil))
        XCTAssertEqual(WikiChip.previewCommand(kind: "notes", value: "obs-1", root: nil, config: owner),
                       .init(tool: "notes", arguments: ["show", "obs-1"], directory: nil))
        XCTAssertEqual(WikiChip.previewCommand(kind: "commit", value: "932a609", root: "/p"),
                       .init(tool: "git", arguments: ["-C", "/p", "show", "--stat", "--format=%h %s%n%an · %ad", "932a609"], directory: nil))
    }

    func testPreviewCommandRejectsBadValues() {
        let owner = WikiSupportTests.ownerConfig
        XCTAssertNil(WikiChip.previewCommand(kind: "m", value: "12; rm -rf ~", root: nil, config: owner))
        XCTAssertNil(WikiChip.previewCommand(kind: "m", value: "", root: nil, config: owner))
        XCTAssertNil(WikiChip.previewCommand(kind: "notes", value: "--help", root: nil, config: owner))
        XCTAssertNil(WikiChip.previewCommand(kind: "notes", value: "a b", root: nil, config: owner))
        XCTAssertNil(WikiChip.previewCommand(kind: "m", value: "4504", root: nil), "no config: no handler")
        XCTAssertNil(WikiChip.previewCommand(kind: "commit", value: "zzz", root: "/p"))
        XCTAssertNil(WikiChip.previewCommand(kind: "commit", value: "--output=/x", root: "/p"))
        XCTAssertNil(WikiChip.previewCommand(kind: "commit", value: "932a609", root: nil), "commit needs a root")
        XCTAssertNil(WikiChip.previewCommand(kind: "doc", value: "a.md", root: "/p"))
    }

    func testWikiFontSizeClampAndPersistence() {
        let suite = UserDefaults(suiteName: "wiki-font-\(UUID().uuidString)")!
        XCTAssertEqual(WikiFontSize.resolved(defaults: suite), 14)
        XCTAssertEqual(WikiFontSize.clamp(5), 12)
        XCTAssertEqual(WikiFontSize.clamp(99), 18)
        WikiFontSize.set(16, defaults: suite)
        XCTAssertEqual(WikiFontSize.resolved(defaults: suite), 16)
        WikiFontSize.set(40, defaults: suite)
        XCTAssertEqual(WikiFontSize.resolved(defaults: suite), 18)
        XCTAssertEqual(WikiFontSize.rendererSize(14), 15, accuracy: 0.001, "14 px is the shell's 15 px at zoom 1 / (15/14)")
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: WikiFontSize.rendererSize(14)), 1, accuracy: 0.001)
        XCTAssertEqual(MarkdownFontSizeSettings.pageZoom(forPointSize: WikiFontSize.rendererSize(18)), 18.0 / 14.0, accuracy: 0.001)
    }

    // MARK: Links stay in the popover (GUI feedback round 2)

    private struct Routed {
        var pushed: [String] = []
        var quickView: [QuickViewResource] = []
    }

    @MainActor
    private func route(_ href: String, page: String, root: String, quickView: Bool = false, wikiDir: String? = nil) -> Routed {
        WikiOpeners.roots[WikiOpeners.key(page)] = root
        var routed = Routed()
        let actions = WikiRouter.Actions(
            workspace: nil,
            openResource: { routed.quickView.append($0) },
            openPage: { _ in },
            pushFile: { path, line in routed.pushed.append("\(path):\(line.map(String.init) ?? "-")") }
        )
        if let wikiDir {
            WikiRouter.route(href: href, pagePath: page, actions: actions, quickView: quickView, wikiDir: wikiDir)
        } else {
            WikiRouter.route(href: href, pagePath: page, actions: actions, quickView: quickView)
        }
        return routed
    }

    /// A temp folder under home (doc chips only accept files under home).
    private func makeHomeFolder() throws -> String {
        let dir = NSHomeDirectory() + "/Library/Caches/wikifile-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
    }

    @MainActor
    func testDocCodeAndSrcLinksPushAFilePageInsteadOfQuickView() throws {
        let wiki = try makeWiki()
        let home = try makeHomeFolder()
        try "x".write(toFile: home + "/notes.md", atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(atPath: wiki + "/_kaynaklar/snap/demo/src", withIntermediateDirectories: true)
        try "int main() {}".write(toFile: wiki + "/_kaynaklar/snap/demo/src/main.c", atomically: true, encoding: .utf8)
        let page = wiki + "/proj/a.md"

        let code = route("code:Sources/A.swift:12", page: page, root: "/r/proj")
        XCTAssertEqual(code.pushed, ["/r/proj/Sources/A.swift:12"])
        XCTAssertTrue(code.quickView.isEmpty, "a code link no longer opens Quick View")

        let doc = route("chip:doc:notes.md", page: page, root: home)
        XCTAssertEqual(doc.pushed, [home + "/notes.md:-"])
        XCTAssertTrue(doc.quickView.isEmpty)

        let absolute = route("chip:doc:" + home + "/notes.md", page: page, root: "/r/proj")
        XCTAssertEqual(absolute.pushed, [home + "/notes.md:-"], "absolute doc paths push too")

        let src = route("src:demo:src%2Fmain.c:7", page: page, root: "/r/proj", wikiDir: wiki)
        XCTAssertEqual(src.pushed, [wiki + "/_kaynaklar/snap/demo/src/main.c:7"])
        XCTAssertTrue(src.quickView.isEmpty)
    }

    @MainActor
    func testCommandClickOpensQuickViewInstead() throws {
        let wiki = try makeWiki()
        let result = route("code:Sources/A.swift:12", page: wiki + "/proj/a.md", root: "/r/proj", quickView: true)
        XCTAssertTrue(result.pushed.isEmpty)
        XCTAssertEqual(result.quickView, [.file(path: "/r/proj/Sources/A.swift", line: 12)])
    }

    // MARK: Place keeping

    func testBackRestoresTheStoredScrollOffset() {
        var stack = WikiBackStack()
        stack.push(.init(path: "/w/a.md", title: "A"))
        stack.push(.init(path: "/r/x.swift", title: "x.swift", line: 9), leavingScrollY: 1480)
        stack.push(.init(path: "/w/b.md", title: "B"), leavingScrollY: 35)
        stack.pop()
        XCTAssertEqual(stack.current?.path, "/r/x.swift")
        XCTAssertEqual(stack.current?.scrollY, 35)
        stack.pop()
        XCTAssertEqual(stack.current?.path, "/w/a.md")
        XCTAssertEqual(stack.current?.scrollY, 1480, "the first page comes back at the exact offset")
        XCTAssertEqual(stack.depth, 1)
    }

    func testSameFileAtAnotherLineIsANewPage() {
        var stack = WikiBackStack()
        stack.push(.init(path: "/r/x.swift", title: "x", line: 3))
        stack.push(.init(path: "/r/x.swift", title: "x", line: 3), leavingScrollY: 10)
        XCTAssertEqual(stack.depth, 1)
        stack.push(.init(path: "/r/x.swift", title: "x", line: 40), leavingScrollY: 10)
        XCTAssertEqual(stack.depth, 2)
    }

    func testStackAndOffsetSurviveCloseAndReopenPerWorkspace() {
        let memory = WikiPopoverMemory()
        let one = UUID(), two = UUID()
        var stack = WikiBackStack()
        stack.push(.init(path: "/w/a.md", title: "A"))
        stack.push(.init(path: "/r/x.swift", title: "x", line: 9), leavingScrollY: 700)
        stack.recordScroll(250)
        memory.save(stack, for: one)

        let restored = memory.stack(for: one)
        XCTAssertEqual(restored?.depth, 2)
        XCTAssertEqual(restored?.current?.path, "/r/x.swift")
        XCTAssertEqual(restored?.current?.scrollY, 250, "the page on top keeps its live offset")
        XCTAssertEqual(restored?.previousTitle, "A")
        var back = try! XCTUnwrap(restored)
        back.pop()
        XCTAssertEqual(back.current?.scrollY, 700)
        XCTAssertNil(memory.stack(for: two), "another workspace starts at the list")

        memory.save(WikiBackStack(), for: one)
        XCTAssertNil(memory.stack(for: one), "going home forgets the place")
    }

    // MARK: File pages

    func testFilePageSizeCapAndBinaryFallback() throws {
        let dir = try makeWiki()
        let big = dir + "/big.swift"
        FileManager.default.createFile(atPath: big, contents: Data(repeating: 0x61, count: WikiFilePage.maxBytes + 1))
        XCTAssertEqual(WikiFilePage.load(path: big, line: nil, wikiDir: dir), .unsupported(.tooLarge))
        let edge = dir + "/edge.txt"
        FileManager.default.createFile(atPath: edge, contents: Data(repeating: 0x61, count: WikiFilePage.maxBytes))
        if case .unsupported = WikiFilePage.load(path: edge, line: nil, wikiDir: dir) { XCTFail("exactly 2 MB is still shown") }
        let nul = dir + "/blob.bin"
        FileManager.default.createFile(atPath: nul, contents: Data([0x41, 0x00, 0x42]))
        XCTAssertEqual(WikiFilePage.load(path: nul, line: nil, wikiDir: dir), .unsupported(.binary))
        let latin = dir + "/latin.txt"
        FileManager.default.createFile(atPath: latin, contents: Data([0xff, 0xfe, 0x80]))
        XCTAssertEqual(WikiFilePage.load(path: latin, line: nil, wikiDir: dir), .unsupported(.binary), "not UTF-8")
        XCTAssertEqual(WikiFilePage.load(path: dir + "/nope.swift", line: nil, wikiDir: dir), .unsupported(.unreadable))
    }

    func testMarkdownFileRendersAsMarkdownAndCodeAsFencedSource() throws {
        let dir = try makeWiki()
        try "# T\n\ntext".write(toFile: dir + "/n.md", atomically: true, encoding: .utf8)
        XCTAssertEqual(WikiFilePage.load(path: dir + "/n.md", line: nil, wikiDir: dir), .markdown("# T\n\ntext"))
        try "let a = 1\n```\nlet b = 2\n".write(toFile: dir + "/c.swift", atomically: true, encoding: .utf8)
        let content = WikiFilePage.load(path: dir + "/c.swift", line: 2, wikiDir: dir)
        guard case .source(let markdown, let line) = content else { return XCTFail("code shows as source, got \(content)") }
        XCTAssertEqual(line, 2)
        XCTAssertTrue(markdown.hasPrefix("````swift\n"), "the fence is longer than any backtick run in the file: \(markdown)")
        XCTAssertTrue(markdown.contains("let b = 2"))
    }

    func testSnapFilesAreAlwaysPlainText() throws {
        let wiki = try makeWiki()
        try FileManager.default.createDirectory(atPath: wiki + "/_kaynaklar/snap/demo", withIntermediateDirectories: true)
        try "# not rendered".write(toFile: wiki + "/_kaynaklar/snap/demo/README.md", atomically: true, encoding: .utf8)
        let content = WikiFilePage.load(path: wiki + "/_kaynaklar/snap/demo/README.md", line: 1, wikiDir: wiki)
        guard case .source(let markdown, _) = content else { return XCTFail("snap markdown must not render, got \(content)") }
        XCTAssertTrue(markdown.hasPrefix("```text\n"), markdown)
    }

    func testSourcePageTargetsTheRightLine() {
        let withLine = WikiPageScript.afterRender(source: true, line: 12, scrollY: nil)
        XCTAssertTrue(withLine.contains("bree-ln"), "numbers the lines")
        XCTAssertTrue(withLine.contains("(12)"), "marks line 12")
        XCTAssertTrue(withLine.contains("bree_go('target')"), "and scrolls to it")
        let restored = WikiPageScript.afterRender(source: true, line: 12, scrollY: 480)
        XCTAssertTrue(restored.contains("bree_go(480)"), "a restored offset wins over the target line")
        XCTAssertTrue(restored.contains("(12)"), "the mark stays on return")
        XCTAssertFalse(restored.contains("bree_go('target')"))
        XCTAssertTrue(WikiPageScript.afterRender(source: false, line: nil, scrollY: nil).contains("bree_go(0)"),
                      "a fresh page starts at the top, not at the previous page's offset")
        XCTAssertFalse(WikiPageScript.afterRender(source: false, line: nil, scrollY: nil).contains(#"<span class="bree-ln"#), "no line numbering outside source pages")
    }

    func testRestoredScrollIsRetriedUntilTheLayoutSettles() {
        // A reopened popover renders into a fresh web view: one scrollTo lands on a short document (or is
        // smoothed away). The script must keep applying the offset and let the reader's own input stop it.
        let js = WikiPageScript.afterRender(source: false, line: nil, scrollY: 600)
        XCTAssertTrue(js.contains("bree_go(600)"))
        XCTAssertTrue(js.contains("requestAnimationFrame"), "retries across frames")
        XCTAssertTrue(js.contains("scrollBehavior='auto'"), "smooth scrolling must not eat the jump")
        XCTAssertTrue(js.contains("'wheel'"), "reader input stops the retry")
    }

    // MARK: #symbol

    func testSymbolLineFindsTheDefinitionNotAMention() {
        let py = """
        \"\"\"payments-api.retrieve\"\"\"
        import os
        def retrieve_all(root):
            return retrieve(root)

        def retrieve(root, qs, log=None):
            pass
        """
        XCTAssertEqual(SymbolLine.find("retrieve", in: py), 6, "the def of `retrieve`, not retrieve_all or the call")
        XCTAssertEqual(SymbolLine.find("retrieve_all", in: py), 3)
        XCTAssertNil(SymbolLine.find("missing", in: py))
        let swift = "struct A {\n    @MainActor\n    public static func make(_ x: Int) {}\n    final class Box {}\n}\n"
        XCTAssertEqual(SymbolLine.find("make", in: swift), 3)
        XCTAssertEqual(SymbolLine.find("Box", in: swift), 4)
        XCTAssertNil(SymbolLine.find("", in: swift))
    }

    // MARK: Capture cards (_kaynaklar/yakala)

    private let cardId = "2026-10-10-ilginc-makale"

    private func makeCard(_ wiki: String, text: String = "---\nneden: x\n---\n# Kart") throws -> String {
        try FileManager.default.createDirectory(atPath: wiki + "/_kaynaklar/yakala/.ham", withIntermediateDirectories: true)
        let card = wiki + "/_kaynaklar/yakala/\(cardId).md"
        try text.write(toFile: card, atomically: true, encoding: .utf8)
        try "raw".write(toFile: wiki + "/_kaynaklar/yakala/.ham/\(cardId).txt", atomically: true, encoding: .utf8)
        return card
    }

    func testIndexAndSearchSkipTheWholeSourcesFolder() throws {
        let wiki = try makeWiki()
        _ = try makeCard(wiki)
        try "# P\nbody".write(toFile: wiki + "/proj/p.md", atomically: true, encoding: .utf8)
        let page = #"{"slug":"p","title":"P","one_liner":"o","updated":"u","status":"ok"}"#
        let card = #"{"slug":"k","title":"K","one_liner":"o","updated":"u","status":"ok","file":"../_kaynaklar/yakala/\#(cardId).md"}"#
        let ham = #"{"slug":"h","title":"H","one_liner":"o","updated":"u","status":"ok","file":"../_kaynaklar/yakala/.ham/\#(cardId).txt"}"#
        let json = #"{"project":"proj","root":"/r","generated":"x","groups":[{"title":"G","pages":[\#(page),\#(card),\#(ham)]}]}"#
        try json.write(toFile: wiki + "/proj/index.json", atomically: true, encoding: .utf8)
        let loaded = try XCTUnwrap(WikiIndex.loadAll(wikiDir: wiki).indexes.first)
        XCTAssertEqual(loaded.pages.map(\.slug), ["p"], "capture cards and raw text never show in topic lists")
        // Search skips them on its own as well, even for an index that was not filtered.
        let raw = try WikiIndex.decode(Data(json.utf8))
        var unfiltered = raw
        unfiltered.dir = wiki + "/proj"
        let built = WikiSearchIndex.build(indexes: [unfiltered], wikiDir: wiki)
        XCTAssertEqual(built.entries.map(\.slug), ["p"])
    }

    func testYakalaChipParsesAndRewrites() {
        XCTAssertEqual(WikiLink.parse("chip:yakala:\(cardId)"), .chip(kind: "yakala", value: cardId))
        XCTAssertEqual(WikiChip.label(kind: "yakala", value: cardId), "yakala:\(cardId)")
        let out = WikiMarkdown.preprocess("owner: [yakala:\(cardId)]")
        XCTAssertTrue(out.contains("(chip:yakala:\(cardId))"), out)
    }

    func testYakalaCardResolvesOnlyInsideItsFolder() throws {
        let wiki = try makeWiki()
        let card = try makeCard(wiki)
        XCTAssertEqual(WikiPaths.yakalaCard(id: cardId, wikiDir: wiki), card)
        for bad in ["../proj/p", ".ham/\(cardId)", "2026-10-10-", "2026-10-10-A", "2026-10-1-x", "x", "2026-10-10-a/b", "2026-10-10-missing", ""] {
            XCTAssertNil(WikiPaths.yakalaCard(id: bad, wikiDir: wiki), bad)
        }
        let outside = try makeWiki() + "/proj/secret.md"
        try "s".write(toFile: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: wiki + "/_kaynaklar/yakala/2026-10-10-link.md", withDestinationPath: outside)
        XCTAssertNil(WikiPaths.yakalaCard(id: "2026-10-10-link", wikiDir: wiki), "a symlink out of yakala/ is refused")
        XCTAssertTrue(WikiPaths.isBlockedSource(wiki + "/_kaynaklar/yakala/.ham/\(cardId).txt", wikiDir: wiki))
        XCTAssertFalse(WikiPaths.isBlockedSource(card, wikiDir: wiki))
    }

    @MainActor
    func testYakalaChipPushesTheCardAndCommandClickOpensQuickView() throws {
        let wiki = try makeWiki()
        let card = try makeCard(wiki)
        let page = wiki + "/proj/a.md"
        let plain = route("chip:yakala:\(cardId)", page: page, root: "/r/proj", wikiDir: wiki)
        XCTAssertEqual(plain.pushed, [card + ":-"])
        XCTAssertTrue(plain.quickView.isEmpty)
        let modified = route("chip:yakala:\(cardId)", page: page, root: "/r/proj", quickView: true, wikiDir: wiki)
        XCTAssertTrue(modified.pushed.isEmpty)
        XCTAssertEqual(modified.quickView, [.file(path: card)])
        let bad = route("chip:yakala:..%2Fproj%2Fa", page: page, root: "/r/proj", wikiDir: wiki)
        XCTAssertTrue(bad.pushed.isEmpty && bad.quickView.isEmpty)
    }

    @MainActor
    func testRawCaptureTextNeverOpensFromALink() throws {
        let home = try makeHomeFolder()
        try FileManager.default.createDirectory(atPath: home + "/_kaynaklar/yakala/.ham", withIntermediateDirectories: true)
        let ham = home + "/_kaynaklar/yakala/.ham/\(cardId).txt"
        try "raw".write(toFile: ham, atomically: true, encoding: .utf8)
        for modifier in [false, true] {
            let r = route("chip:doc:" + ham, page: home + "/p.md", root: "/r", quickView: modifier, wikiDir: home)
            XCTAssertTrue(r.pushed.isEmpty && r.quickView.isEmpty, "never under .ham/")
        }
        XCTAssertEqual(WikiFilePage.load(path: ham, line: nil, wikiDir: home), .unsupported(.forbidden))
    }

    func testCaptureCardIsLoadedAsAnInertCard() throws {
        let wiki = try makeWiki()
        let card = try makeCard(wiki)
        XCTAssertEqual(WikiFilePage.load(path: card, line: nil, wikiDir: wiki), .card("---\nneden: x\n---\n# Kart"))
        let script = WikiPageScript.afterRender(source: false, line: nil, scrollY: nil, inert: true)
        XCTAssertTrue(script.contains("removeAttribute('href')"), "links are inert")
        XCTAssertTrue(script.contains("img"), "no images")
        XCTAssertFalse(WikiPageScript.afterRender(source: false, line: nil, scrollY: nil).contains("removeAttribute('href')"))
    }

    func testShellBaseURLOfAMemoryPagePathIsAbsoluteAndStable() {
        let url = MarkdownWebRenderer.shellBaseURL(forFilePath: WikiMemory.pseudoPath(kind: "m", value: "5596"))
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasPrefix("/"))
        XCTAssertFalse(url.absoluteString.contains("%3A"), "a cwd-relative, escaped URL never matches the shell load request")
        XCTAssertEqual(MarkdownWebRenderer.shellBaseURL(forFilePath: "/a/b.md").path, "/a/b.md")
    }

    // MARK: UI polish (chip labels, titles, dates, sizing)

    func testTableChipLabelDropsTheDatePrefixOnly() {
        XCTAssertEqual(WikiChip.tableLabel(kind: "doc", value: "docs/2026-10-05-7aa2469-swe-loc.md"), "7aa2469-swe-loc.md")
        XCTAssertEqual(WikiChip.tableLabel(kind: "doc", value: "docs/README.md"), "README.md")
        XCTAssertEqual(WikiChip.tableLabel(kind: "doc", value: "2026-10-05-"), "2026-10-05-", "nothing left: keep the name")
        XCTAssertEqual(WikiChip.tableLabel(kind: "commit", value: "abcdef123456"), "abcdef1")
    }

    func testPreprocessShortensDocChipsInTablesOnly() {
        let md = "| a | [doc:docs/2026-10-05-x.md] |\nText [doc:docs/2026-10-05-x.md]\n"
        let out = WikiMarkdown.preprocess(md)
        XCTAssertTrue(out.contains("[x.md](chip:doc:docs%2F2026-10-05-x.md)"))
        XCTAssertTrue(out.contains("[2026-10-05-x.md](chip:doc:docs%2F2026-10-05-x.md)"))
    }

    func testFileTitleComposition() {
        XCTAssertEqual(WikiTitle.file(path: "/r/semble/README.md", repo: "semble"), "semble · README.md")
        XCTAssertEqual(WikiTitle.file(path: "/r/README.md", repo: nil), "README.md")
        XCTAssertEqual(WikiTitle.file(path: "/r/semble", repo: "semble"), "semble")
    }

    func testRepoNameFindsTheNearestGitFolderBelowHome() throws {
        let home = NSTemporaryDirectory() + "wiki-home-\(UUID().uuidString)"
        let fm = FileManager.default
        try fm.createDirectory(atPath: home + "/semble/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: home + "/semble/.git", withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: home) }
        XCTAssertEqual(WikiTitle.repoName(forFile: home + "/semble/src/a.py", home: home), "semble")
        XCTAssertNil(WikiTitle.repoName(forFile: home + "/loose.txt", home: home))
        XCTAssertEqual(WikiTitle.repoName(forFile: home + "/Vault/wiki/_kaynaklar/snap/semble/README.md", home: home), "semble")
    }

    func testHeaderTitleIsEmptyWhileTheHeadingShows() {
        XCTAssertEqual(WikiTitle.header(title: "Hybrid search", pageHeadingVisible: true), "")
        XCTAssertEqual(WikiTitle.header(title: "Hybrid search", pageHeadingVisible: false), "Hybrid search")
    }

    func testShortDateIsLocalizedAndAddsTheYearForOtherYears() {
        let utc = TimeZone(identifier: "UTC")!
        let now = ISO8601DateFormatter().date(from: "2026-10-12T00:00:00Z")!
        XCTAssertEqual(WikiTitle.shortDate("2026-10-10", locale: Locale(identifier: "tr_TR"), now: now, timeZone: utc), "10 Eki")
        XCTAssertEqual(WikiTitle.shortDate("2026-10-10", locale: Locale(identifier: "en_US"), now: now, timeZone: utc), "Oct 10")
        XCTAssertEqual(WikiTitle.shortDate("2025-03-04", locale: Locale(identifier: "en_US"), now: now, timeZone: utc), "Mar 4, 2025")
        XCTAssertEqual(WikiTitle.shortDate("soon", locale: Locale(identifier: "en_US"), now: now, timeZone: utc), "soon")
    }

    func testHomeHeightFollowsContentBetweenTheLimits() {
        XCTAssertEqual(WikiPopoverSizing.homeHeight(content: 50), 280)
        XCTAssertEqual(WikiPopoverSizing.homeHeight(content: 300), 337)
        XCTAssertEqual(WikiPopoverSizing.homeHeight(content: 2000), 520)
    }

    func testTopicsTitleComesFromTheIndexGroups() throws {
        let json = #"{"project":"p","root":"/r","generated":"","groups":[{"title":"Kavramlar","pages":[]}]}"#
        let index = try WikiIndex.decode(Data(json.utf8))
        XCTAssertEqual(WikiBrowse.topicsTitle(project: index, general: nil), "Kavramlar")
        XCTAssertNil(WikiBrowse.topicsTitle(project: nil, general: nil))
    }
}
