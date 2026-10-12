import AppKit
import CmuxFoundation
import Foundation

// Read-only support for the Wiki popover: the `bree-wiki/1` contract (docs/state/2026-10-10-generic-wiki-architecture-design.md).
// Bree renders a wiki folder and never writes there. Pure helpers only; routing lives in WikiRouter.swift.

struct WikiPage: Equatable, Identifiable {
    let slug: String
    let title: String
    /// Empty when the index has none.
    let oneLiner: String
    let updated: String
    /// "ok" or "stale" today; kept a String so a new value never breaks decoding.
    let status: String
    /// Optional path relative to the index folder (e.g. `../_kavramlar/<slug>.md`).
    let file: String?

    var id: String { slug }
    var isStale: Bool { status == "stale" }
}

struct WikiGroup: Equatable {
    let title: String
    let pages: [WikiPage]
}

/// An index.json that could not be used. The popover shows it as an error row naming the problem,
/// so a broken index never drops its project silently.
struct WikiIssue: Equatable, Identifiable, Error {
    /// The index.json file.
    let path: String
    let message: String
    /// The index's `root` as far as it could be read; nil when unknown (then the row shows everywhere).
    let root: String?

    var id: String { path }

    func isRelevant(to projectPath: String) -> Bool {
        guard let root, !root.isEmpty else { return true }
        return WikiProject.contains(root: root, path: projectPath)
    }
}

struct WikiIndexError: Error, Equatable { let message: String }

struct WikiIndex: Equatable {
    /// `bree-wiki/1`; empty when absent. Not enforced: a newer minor version still renders.
    var schema = ""
    let project: String
    let root: String
    /// Language of the page content, as declared by the producer (informational).
    let lang: String
    var groups: [WikiGroup]
    /// Directory holding index.json and the pages; set by the loader, not decoded.
    var dir = ""
    /// The wiki folder pages must stay inside: the repo-local `<repo>/.bree/wiki` or the global folder.
    var wikiRoot = ""
    /// Found in `<repo>/.bree/wiki` (travels with the repo), not in the global folder.
    var isLocal = false

    /// Lenient decoder: only `project`, group `title`, page `slug` and `title` are required. A problem throws a
    /// `WikiIndexError` that names the field (`groups[1].pages[0]: "title" is missing`).
    static func decode(_ data: Data) throws -> WikiIndex {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw WikiIndexError(message: "it is not valid JSON") }
        guard let dict = object as? [String: Any] else { throw WikiIndexError(message: "the top level must be an object") }
        func text(_ any: Any?) -> String? { (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let project = text(dict["project"]), !project.isEmpty else { throw WikiIndexError(message: "\"project\" is missing") }
        var groups: [WikiGroup] = []
        if let raw = dict["groups"] {
            guard let list = raw as? [Any] else { throw WikiIndexError(message: "\"groups\" must be a list") }
            for (g, item) in list.enumerated() {
                guard let group = item as? [String: Any] else { throw WikiIndexError(message: "groups[\(g)] must be an object") }
                guard let title = text(group["title"]), !title.isEmpty else { throw WikiIndexError(message: "groups[\(g)]: \"title\" is missing") }
                var pages: [WikiPage] = []
                if let rawPages = group["pages"] {
                    guard let pageList = rawPages as? [Any] else { throw WikiIndexError(message: "groups[\(g)].pages must be a list") }
                    for (p, pageItem) in pageList.enumerated() {
                        let at = "groups[\(g)].pages[\(p)]"
                        guard let page = pageItem as? [String: Any] else { throw WikiIndexError(message: "\(at) must be an object") }
                        guard let slug = text(page["slug"]), !slug.isEmpty else { throw WikiIndexError(message: "\(at): \"slug\" is missing") }
                        guard let pageTitle = text(page["title"]), !pageTitle.isEmpty else { throw WikiIndexError(message: "\(at): \"title\" is missing") }
                        let file = text(page["file"]).flatMap { $0.isEmpty ? nil : $0 }
                        guard file != nil || WikiLink.isSafeSlug(slug) else {
                            throw WikiIndexError(message: "\(at): \"slug\" must not contain / \\ or ..")
                        }
                        pages.append(WikiPage(
                            slug: slug, title: pageTitle, oneLiner: text(page["one_liner"]) ?? "",
                            updated: text(page["updated"]) ?? "", status: text(page["status"]) ?? "ok", file: file))
                    }
                }
                groups.append(WikiGroup(title: title, pages: pages))
            }
        }
        // `"root": null` (cross-project index) means no code root: it never matches a project path.
        return WikiIndex(schema: text(dict["schema"]) ?? "", project: project, root: text(dict["root"]) ?? "",
                         lang: text(dict["lang"]) ?? "", groups: groups)
    }

    /// The global wiki folder: Settings > Wiki, else `<Bree home>/wiki` (see `WikiFolderSetting`).
    static func wikiDirectory(defaults: UserDefaults = .standard, home: String = NSHomeDirectory()) -> String {
        WikiFolderSetting.resolved(defaults: defaults, homeDirectory: URL(fileURLWithPath: home))
    }

    /// The `index.json` in `dir`: nil when there is none, an issue when it is unusable.
    static func read(dir: String, wikiRoot: String, isLocal: Bool, fallbackRoot: String? = nil) -> Result<WikiIndex, WikiIssue>? {
        let file = (dir as NSString).appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: file) else { return nil }
        guard let data = FileManager.default.contents(atPath: file) else {
            return .failure(WikiIssue(path: file, message: "it cannot be read", root: fallbackRoot))
        }
        do {
            var index = try decode(data)
            index.dir = dir
            index.wikiRoot = wikiRoot
            index.isLocal = isLocal
            return .success(index.withoutSourcePages())
        } catch {
            let message = (error as? WikiIndexError)?.message ?? "it cannot be decoded"
            return .failure(WikiIssue(path: file, message: message, root: fallbackRoot ?? looseRoot(data)))
        }
    }

    /// `root` of a broken index, read without the schema, so its error row can be limited to the right project.
    static func looseRoot(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["root"] as? String
    }

    /// Every `<wikiDir>/*/index.json` (folder names sorted; names starting with `_` or `.` are not projects).
    /// Never runs a tool. A broken index becomes an issue instead of vanishing.
    static func loadAll(wikiDir: String = wikiDirectory()) -> (indexes: [WikiIndex], issues: [WikiIssue]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: wikiDir)) ?? []
        var indexes: [WikiIndex] = []
        var issues: [WikiIssue] = []
        for name in names.sorted() where !name.hasPrefix("_") && !name.hasPrefix(".") {
            let dir = (wikiDir as NSString).appendingPathComponent(name)
            switch read(dir: dir, wikiRoot: wikiDir, isLocal: false) {
            case .success(let index): indexes.append(index)
            case .failure(let issue): issues.append(issue)
            case nil: break
            }
        }
        return (indexes, issues)
    }

    /// Compatibility alias: `_kaynaklar/` holds snapshots and capture cards, never a topic, whatever an index lists.
    func withoutSourcePages() -> WikiIndex {
        var copy = self
        copy.groups = groups.map { group in
            WikiGroup(title: group.title, pages: group.pages.filter { page in
                if page.file?.contains(WikiPaths.sourcesFolder) == true { return false }
                guard let path = pagePath(for: page) else { return true }
                return !path.contains("/" + WikiPaths.sourcesFolder + "/")
            })
        }
        return copy
    }

    /// Compatibility alias `<wikiDir>/_genel/index.json`: the cross-project pages. nil while missing or broken.
    static func loadGeneral(wikiDir: String = wikiDirectory()) -> WikiIndex? {
        let dir = (wikiDir as NSString).appendingPathComponent(WikiPaths.generalFolder)
        if case .success(let index)? = read(dir: dir, wikiRoot: wikiDir, isLocal: false) { return index }
        return nil
    }

    var pages: [WikiPage] { groups.flatMap(\.pages) }

    /// The folder pages must stay inside.
    var base: String { wikiRoot.isEmpty ? Self.wikiDirectory() : wikiRoot }

    func isMissing(_ page: WikiPage) -> Bool {
        guard let path = pagePath(for: page) else { return true }
        return !FileManager.default.fileExists(atPath: path)
    }

    /// Where the page lives: `file` (relative to this index folder) when present, else `<slug>.md`
    /// next to the index. nil when the result, with symlinks resolved, is not inside the wiki folder.
    /// A path that is inside but does not exist is returned: the caller shows the card as missing.
    func pagePath(for page: WikiPage, wikiDir: String? = nil) -> String? {
        guard !dir.isEmpty else { return nil }
        let rel: String
        if let file = page.file {
            guard !file.isEmpty, !file.hasPrefix("/"), file.lowercased().hasSuffix(".md") else { return nil }
            rel = file
        } else {
            guard WikiLink.isSafeSlug(page.slug) else { return nil }
            rel = page.slug + ".md"
        }
        return WikiPaths.confined((dir as NSString).appendingPathComponent(rel), wikiDir: wikiDir ?? base)
    }
}

/// Everything one popover load found.
struct WikiLoad: Equatable {
    /// The repo-local wiki of the project (`<repo>/.bree/wiki/index.json`), when it is usable.
    var local: WikiIndex?
    /// Global projects, folder order.
    var all: [WikiIndex] = []
    var general: WikiIndex?
    var issues: [WikiIssue] = []

    /// The project's wiki: the repo-local one first, else the global index whose root contains `path`.
    func project(for path: String) -> WikiIndex? { local ?? WikiProject.match(all, path: path) }
    /// Search order: the local wiki, then the global projects.
    var searchable: [WikiIndex] { (local.map { [$0] } ?? []) + all }
}

enum WikiLibrary {
    static func localDirectory(repoRoot: String) -> String { (repoRoot as NSString).appendingPathComponent(".bree/wiki") }

    /// Lookup order of the contract: `<repo>/.bree/wiki/index.json`, then the global wiki folder.
    /// Issues are only those that concern `repoRoot` (a broken index of another project stays quiet).
    static func load(repoRoot: String, globalDir: String = WikiIndex.wikiDirectory()) -> WikiLoad {
        var result = WikiLoad()
        let localDir = localDirectory(repoRoot: repoRoot)
        switch WikiIndex.read(dir: localDir, wikiRoot: localDir, isLocal: true, fallbackRoot: repoRoot) {
        case .success(let index):
            var index = index
            if index.root.isEmpty { index = index.withRoot(repoRoot) }
            result.local = index
        case .failure(let issue): result.issues.append(issue)
        case nil: break
        }
        let global = WikiIndex.loadAll(wikiDir: globalDir)
        result.all = global.indexes
        result.general = WikiIndex.loadGeneral(wikiDir: globalDir)
        result.issues += global.issues.filter { $0.isRelevant(to: repoRoot) }
        return result
    }
}

extension WikiIndex {
    func withRoot(_ root: String) -> WikiIndex {
        var copy = WikiIndex(schema: schema, project: project, root: root, lang: lang, groups: groups)
        copy.dir = dir
        copy.wikiRoot = wikiRoot
        copy.isLocal = isLocal
        return copy
    }
}

enum WikiProject {
    /// `path` equals `root` or is inside it. Component-wise, so `/a/pay` is not inside `/a/payments-api`.
    static func contains(root: String, path: String) -> Bool {
        let r = normalized(root)
        let p = normalized(path)
        guard !r.isEmpty else { return false }
        return p == r || p.hasPrefix(r == "/" ? "/" : r + "/")
    }

    /// The index whose root contains `path`; the longest (most specific) root wins.
    static func match(_ indexes: [WikiIndex], path: String) -> WikiIndex? {
        indexes.filter { contains(root: $0.root, path: path) }
            .max { normalized($0.root).count < normalized($1.root).count }
    }

    /// Same directory after normalisation (no symlink resolution).
    static func same(_ a: String, _ b: String) -> Bool {
        let x = normalized(a)
        return !x.isEmpty && x == normalized(b)
    }

    private static func normalized(_ path: String) -> String {
        guard !path.isEmpty else { return "" }
        var s = (path as NSString).standardizingPath
        while s.count > 1, s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

enum WikiPaths {
    // Compatibility aliases: the folder names of the owner's original wiki. The contract itself has no magic
    // folder names (pages come from `file` or `<slug>.md`); these only keep that wiki working unchanged.
    /// The folder shared concept pages live in, next to the project folders (`[[slug]]` fallback).
    static let conceptsFolder = "_kavramlar"
    /// Cross-project pages with their own `index.json` (`"project": "_genel"`).
    static let generalFolder = "_genel"
    /// Holds `snap/<slug>/...`: untrusted downloaded source snapshots. Never pages, never listed.
    static let sourcesFolder = "_kaynaklar"

    /// `path` with symlinks resolved, only when it stays inside `wikiDir` (also resolved).
    static func confined(_ path: String, wikiDir: String) -> String? {
        let root = URL(fileURLWithPath: wikiDir).resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard !resolved.split(separator: "/").contains(".."), resolved.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    /// The repo-local wiki folder (`.../.bree/wiki` holding an index.json) that contains `path`, nil for any other path.
    static func localRoot(containing path: String) -> String? {
        guard !path.contains("/../") else { return nil }
        var dir = (path as NSString).standardizingPath
        while dir.count > 1 {
            dir = (dir as NSString).deletingLastPathComponent
            if dir.hasSuffix("/.bree/wiki") {
                return FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent("index.json")) ? dir : nil
            }
        }
        return nil
    }

    /// The wiki folder `path` belongs to: a repo-local one, else the global folder.
    static func wikiRoot(containing path: String, global: String = WikiIndex.wikiDirectory()) -> String {
        localRoot(containing: path) ?? global
    }

    /// The snapshot file `_kaynaklar/snap/<slug>/<relpath>`: an existing regular file that, with symlinks
    /// resolved, stays inside `snap/<slug>/`. nil otherwise. Snapshots are untrusted downloaded data.
    static func snapFile(slug: String, relpath: String, wikiDir: String = WikiIndex.wikiDirectory()) -> String? {
        guard WikiLink.isSafeSlug(slug), WikiLink.isSafeRelativePath(relpath) else { return nil }
        let base = ((wikiDir as NSString).appendingPathComponent(sourcesFolder) as NSString)
            .appendingPathComponent("snap/" + slug)
        let folder = URL(fileURLWithPath: base).resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: (base as NSString).appendingPathComponent(relpath)).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard resolved.hasPrefix(folder + "/"),
              FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return resolved
    }

    /// A file under `<wikiDir>/_kaynaklar/snap/` (checked on the symlink-resolved path). Quick View shows these
    /// as plain text only, never as rendered markdown or HTML.
    static func isSnapFile(_ path: String, wikiDir: String = WikiIndex.wikiDirectory()) -> Bool {
        let snap = URL(fileURLWithPath: (wikiDir as NSString).appendingPathComponent(sourcesFolder + "/snap"))
            .resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(snap + "/")
    }

    /// The capture card `_kaynaklar/yakala/<id>.md` of `[yakala:<id>]`: an existing regular file that, with
    /// symlinks resolved, stays inside `yakala/`. nil for any other id (and always for `.ham/`).
    static func yakalaCard(id: String, wikiDir: String = WikiIndex.wikiDirectory()) -> String? {
        guard id.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}-[a-z0-9-]+$"#, options: .regularExpression) != nil else { return nil }
        let folder = yakalaFolder(wikiDir: wikiDir)
        let resolved = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(id + ".md")).resolvingSymlinksInPath().path
        var isDirectory: ObjCBool = false
        guard resolved.hasPrefix(folder + "/"), !resolved.dropFirst(folder.count + 1).contains("/"),
              FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue
        else { return nil }
        return resolved
    }

    /// `_kaynaklar/yakala`, symlinks resolved.
    static func yakalaFolder(wikiDir: String = WikiIndex.wikiDirectory()) -> String {
        URL(fileURLWithPath: (wikiDir as NSString).appendingPathComponent(sourcesFolder + "/yakala")).resolvingSymlinksInPath().path
    }

    /// A capture card (outside content), as opposed to a page the wiki's author made.
    static func isYakalaCard(_ path: String, wikiDir: String = WikiIndex.wikiDirectory()) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(yakalaFolder(wikiDir: wikiDir) + "/")
    }

    /// Raw captured text (`_kaynaklar/yakala/.ham/`): never shown, never opened.
    static func isBlockedSource(_ path: String, wikiDir: String = WikiIndex.wikiDirectory()) -> Bool {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(yakalaFolder(wikiDir: wikiDir) + "/.ham/")
    }

    /// `[[slug]]`: the page's own folder first, then the `_kavramlar/` alias. Only existing files inside the wiki.
    static func resolveSlug(_ slug: String, pageDir: String, wikiDir: String? = nil) -> String? {
        guard WikiLink.isSafeSlug(slug) else { return nil }
        let wikiDir = wikiDir ?? wikiRoot(containing: (pageDir as NSString).appendingPathComponent("x.md"))
        let candidates = [pageDir, (wikiDir as NSString).appendingPathComponent(conceptsFolder)]
        for folder in candidates {
            if let path = confined((folder as NSString).appendingPathComponent(slug + ".md"), wikiDir: wikiDir),
               FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    /// The pages Bree opens read-only in wiki mode (chips, `[[links]]`, math): in the global folder
    /// `<wikiDir>/<project>/<page>.md` (the `_kavramlar` and `_genel` aliases included), in a repo-local wiki any `.md`
    /// under `.bree/wiki/` that has an index.json.
    static func isWikiPage(_ path: String, home: String = NSHomeDirectory(), wikiDir: String? = nil) -> Bool {
        guard !path.contains("/../"), path.lowercased().hasSuffix(".md") else { return false }
        let prefix = (wikiDir ?? WikiIndex.wikiDirectory(home: home)) + "/"
        if path.hasPrefix(prefix) {
            let parts = path.dropFirst(prefix.count).split(separator: "/")
            // Other underscore folders (`_attic`, `_kaynaklar`) are not pages.
            return parts.count == 2
                && (parts[0] == Substring(conceptsFolder) || parts[0] == Substring(generalFolder) || !parts[0].hasPrefix("_"))
        }
        guard let root = localRoot(containing: path) else { return false }
        let first = path.dropFirst(root.count + 1).split(separator: "/").first.map(String.init) ?? ""
        return first.isEmpty ? false : (!first.hasPrefix("_") || first == conceptsFolder || first == generalFolder)
    }
}


/// A link inside a wiki page. The markdown source is rewritten by `WikiMarkdown.preprocess` into
/// `code:`, `board:`, `wiki:` and `chip:` hrefs; the web view forwards a clicked href here.
enum WikiLink: Equatable {
    case code(path: String, line: Int?)
    case codeSymbol(path: String, symbol: String)
    case board(String)
    case page(slug: String)
    case chip(kind: String, value: String)
    case qualifiedCode(project: String, path: String, line: Int?, symbol: String?)
    /// `[src:<slug>:<relpath>:<line>]`: a line of the snapshot `_kaynaklar/snap/<slug>/<relpath>`.
    case source(slug: String, path: String, line: Int)
    /// The secondary "Open on GitHub" action of a source chip (the URL is rebuilt from the page front matter).
    case sourceWeb(slug: String, path: String, line: Int)

    /// A chip scheme: lowercase letters only (`doc`, `commit`, `m`, a declared one, or the internal `inert`/`broken`).
    static func isChipKind(_ kind: String) -> Bool {
        !kind.isEmpty && kind.count <= 16 && kind.allSatisfy { $0 >= "a" && $0 <= "z" }
    }

    static func isSafeSlug(_ slug: String) -> Bool {
        !slug.isEmpty && !slug.contains("/") && !slug.contains("\\") && !slug.contains("..")
    }

    static func parse(_ href: String) -> WikiLink? {
        guard let colon = href.firstIndex(of: ":") else { return nil }
        let scheme = href[..<colon].lowercased()
        let rest = String(href[href.index(after: colon)...])
        switch scheme {
        case "code": return rest.hasPrefix("@") ? parseQualified(rest) : parseCode(rest)
        case "board":
            let name = rest.removingPercentEncoding ?? rest
            return name.isEmpty ? nil : .board(name)
        case "wiki":
            let slug = rest.removingPercentEncoding ?? rest
            return isSafeSlug(slug) ? .page(slug: slug) : nil
        case "src", "srcweb":
            // `<slug>:<relpath>:<line>`, each part percent-encoded (so it contains no other colon).
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, let line = Int(parts[2]), line > 0,
                  let slug = parts[0].removingPercentEncoding, let path = parts[1].removingPercentEncoding,
                  isSafeSlug(slug), isSafeRelativePath(path) else { return nil }
            return scheme == "src" ? .source(slug: slug, path: path, line: line) : .sourceWeb(slug: slug, path: path, line: line)
        case "chip":
            guard let inner = rest.firstIndex(of: ":") else { return nil }
            let kind = String(rest[..<inner])
            let raw = String(rest[rest.index(after: inner)...])
            guard isChipKind(kind), !raw.isEmpty else { return nil }
            return .chip(kind: kind, value: raw.removingPercentEncoding ?? raw)
        default: return nil
        }
    }

    /// `@project/relpath[#symbol|:line]`.
    private static func parseQualified(_ raw: String) -> WikiLink? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard let slash = decoded.firstIndex(of: "/") else { return nil }
        let project = String(decoded[decoded.index(after: decoded.startIndex)..<slash])
        guard isSafeSlug(project) else { return nil }
        switch parseCode(String(decoded[decoded.index(after: slash)...])) {
        case .code(let path, let line): return .qualifiedCode(project: project, path: path, line: line, symbol: nil)
        case .codeSymbol(let path, let symbol): return .qualifiedCode(project: project, path: path, line: nil, symbol: symbol)
        default: return nil
        }
    }

    private static func parseCode(_ raw: String) -> WikiLink? {
        var rest = raw.removingPercentEncoding ?? raw
        var symbol: String?
        if let hash = rest.firstIndex(of: "#") {
            symbol = String(rest[rest.index(after: hash)...])
            rest = String(rest[..<hash])
        }
        var line: Int?
        if symbol == nil, let colon = rest.lastIndex(of: ":"), let n = Int(rest[rest.index(after: colon)...]), n > 0 {
            line = n
            rest = String(rest[..<colon])
        }
        guard isSafeRelativePath(rest) else { return nil }
        if let symbol, !symbol.isEmpty { return .codeSymbol(path: rest, symbol: symbol) }
        return .code(path: rest, line: line)
    }

    /// Relative to the project root, never leaving it.
    static func isSafeRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.hasPrefix("~")
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }
}

enum WikiMarkdown {
    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\]\|\n]+)(?:\|([^\]\n]+))?\]\]"#)
    private static let source = try! NSRegularExpression(pattern: #"\[src:([^:\]\s]+):([^\]\n]+?):(\d+)\](?!\()"#)
    private static let qualified = try! NSRegularExpression(pattern: #"\[([^\]\n]*)\]\(code:@([^/)\s]+)/[^)\n]*\)"#)
    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~")
        return set
    }()

    /// Rewrites `[[slug]]` and `[doc:..]`-style source tags into plain markdown links with internal
    /// schemes, outside fenced blocks and inline code. Already-linked text is left alone.
    ///
    /// Math (`$..$`, `$$..$$`) becomes an inline code span that starts with `mathMarker`; the viewer swaps
    /// it for KaTeX output. This keeps markdown from touching `_`, `*` or `\\` inside a formula.
    /// `github`: source chips get a second "open on GitHub" link (the page front matter has url + sha).
    /// `config`: the wiki folder's `.bree-wiki.json` (declared chips, hidden tags). Without it only the built-in chips
    /// (`doc`, `commit`, the `yakala` alias) have a handler; any other `[scheme:value]` of a known scheme is inert.
    static func preprocess(_ markdown: String, roots: Set<String>? = nil, github: Bool = false, config: WikiConfig = .empty) -> String {
        let chipPattern = chipRegex(config)
        var inFence = false
        var out: [String] = []
        let lines = markdown.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                out.append(line)
                continue
            }
            if inFence { out.append(line); continue }
            if let (tex, next) = displayMath(lines, from: i - 1) {
                out += ["", "`" + mathMarker + "d:" + encode(tex) + "`", ""]
                i = next
                continue
            }
            // Odd segments between backticks are inline code.
            out.append(line.components(separatedBy: "`").enumerated()
                .map { $0.offset % 2 == 1 ? $0.element : rewrite($0.element, roots: roots, github: github, config: config, chipPattern: chipPattern, inTable: trimmed.hasPrefix("|")) }
                .joined(separator: "`"))
        }
        return out.joined(separator: "\n")
    }

    /// Marks a math code span: private-use character plus `math:`, then `i:` (inline) or `d:` (display)
    /// and the percent-encoded TeX.
    static let mathMarker = "\u{E000}math:"

    private static let inlineMath = try! NSRegularExpression(
        pattern: #"(?<![\\$])\$(?![\s$])((?:[^$\\\n]|\\.)+?)(?<![\s\\])\$(?![\d$])"#)

    /// `$$` alone on a line up to the next `$$` line, or `$$ tex $$` on one line. nil when unclosed.
    /// Returns the TeX and the index of the first line after the block.
    private static func displayMath(_ lines: [String], from start: Int) -> (String, Int)? {
        let first = lines[start].trimmingCharacters(in: .whitespaces)
        guard first.hasPrefix("$$") else { return nil }
        if first.count > 4, first.hasSuffix("$$") {
            let tex = String(first.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            return tex.isEmpty ? nil : (tex, start + 1)
        }
        guard first == "$$" else { return nil }
        var body: [String] = []
        var j = start + 1
        while j < lines.count {
            if lines[j].trimmingCharacters(in: .whitespaces) == "$$" {
                let tex = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                return tex.isEmpty ? nil : (tex, j + 1)
            }
            body.append(lines[j])
            j += 1
        }
        return nil
    }

    private static func encode(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? text
    }

    /// Chips are `[scheme:value]` for the built-in schemes, the compatibility alias (`m`) and every declared one.
    private static func chipRegex(_ config: WikiConfig) -> NSRegularExpression {
        let schemes = Set(WikiChip.builtinSchemes + WikiChip.aliasSchemes + config.chips.keys).sorted()
            .map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return try! NSRegularExpression(pattern: "\\[(\(schemes)):([^\\]\\s][^\\]\\n]*)\\](?!\\()")
    }

    private static func rewrite(_ text: String, roots: Set<String>?, github: Bool, config: WikiConfig,
                                chipPattern: NSRegularExpression, inTable: Bool = false) -> String {
        // Math first: nothing inside a formula may be read as a link or chip.
        var out = replace(inlineMath, in: text) { m, ns in
            "`" + mathMarker + "i:" + encode(ns.substring(with: m.range(at: 1))) + "`"
        }
        out = replace(source, in: out) { m, ns in
            let slug = encode(ns.substring(with: m.range(at: 1)))
            let path = encode(ns.substring(with: m.range(at: 2)))
            let line = ns.substring(with: m.range(at: 3))
            let label = ns.substring(with: m.range)
                .dropFirst().dropLast()
            let chip = "[\(label)](src:\(slug):\(path):\(line))"
            return github ? chip + " [\u{2197}](srcweb:\(slug):\(path):\(line))" : chip
        }
        if let roots {
            // A qualified link to a project the page does not declare is shown as a dead chip.
            out = replace(qualified, in: out) { m, ns in
                let project = ns.substring(with: m.range(at: 2))
                guard !roots.contains(project.removingPercentEncoding ?? project) else { return ns.substring(with: m.range) }
                let enc = project.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? project
                return "[\(ns.substring(with: m.range(at: 1)))](chip:broken:\(enc))"
            }
        }
        // Hidden tags (`[tag]`, declared in .bree-wiki.json) are provenance marks the reader does not need.
        for tag in config.hiddenTags.sorted() {
            let regex = try! NSRegularExpression(pattern: " ?\\[" + NSRegularExpression.escapedPattern(for: tag) + "\\](?!\\()")
            out = replace(regex, in: out) { _, _ in "" }
        }
        out = replace(wikilink, in: out) { m, ns in
            let target = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let label = m.range(at: 2).location == NSNotFound ? target : ns.substring(with: m.range(at: 2))
            return "[\(label)](wiki:\(target.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? target))"
        }
        out = replace(chipPattern, in: out) { m, ns in
            let kind = ns.substring(with: m.range(at: 1))
            let value = ns.substring(with: m.range(at: 2))
            let enc = value.addingPercentEncoding(withAllowedCharacters: valueAllowed) ?? value
            let label = (inTable ? WikiChip.tableLabel(kind: kind, value: value) : WikiChip.label(kind: kind, value: value))
                .replacingOccurrences(of: #"([\\`*_\[\]])"#, with: #"\\$1"#, options: .regularExpression)
            if WikiChip.hasHandler(kind: kind, config: config) { return "[\(label)](chip:\(kind):\(enc))" }
            // No handler: an inert label whose tooltip says why (the link title survives the sanitizer).
            let tip = String(format: String(localized: "wiki.chip.noHandler",
                                            defaultValue: "No command is set up for %@ chips. Declare one in .bree-wiki.json."), kind)
                .replacingOccurrences(of: "\"", with: "'")
            return "[\(label)](chip:inert:\(enc) \"\(tip)\")"
        }
        return out
    }

    private static func replace(
        _ regex: NSRegularExpression, in text: String, _ make: (NSTextCheckingResult, NSString) -> String
    ) -> String {
        let ns = text as NSString
        var result = ""
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            result += make(m, ns)
            last = m.range.location + m.range.length
        }
        return result + ns.substring(from: last)
    }
}

/// Code roots declared in a page's YAML front matter (`root:` and `roots:`). Every root must be an
/// absolute path inside the user's home (symlinks resolved); anything else is dropped.
struct WikiPageContext: Equatable {
    var root: String?
    var roots: [String: String]
    /// Upstream repository (`url`) and pinned commit (`sha`) of a repo source page.
    var url: String?
    var sha: String?

    static func parse(markdown: String, home: String = NSHomeDirectory()) -> WikiPageContext {
        var ctx = WikiPageContext(root: nil, roots: [:])
        let lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return ctx }
        var inRoots = false
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            let indented = line.hasPrefix(" ") || line.hasPrefix("\t")
            if inRoots, indented {
                if let (k, v) = pair(line), let path = safe(v, home: home) { ctx.roots[k] = path }
                continue
            }
            inRoots = false
            guard let (key, value) = pair(line) else { continue }
            if key == "root" { ctx.root = safe(value, home: home) }
            if key == "url", !indented { ctx.url = value }
            if key == "sha", !indented { ctx.sha = value }
            if key == "roots" {
                if value.hasPrefix("{") {
                    for item in value.dropFirst().split(separator: "}")[0...].prefix(1).joined().split(separator: ",") {
                        if let (k, v) = pair(String(item)), let path = safe(v, home: home) { ctx.roots[k] = path }
                    }
                } else if value.isEmpty { inRoots = true }
            }
        }
        return ctx
    }

    /// `<url>/blob/<sha>/<relpath>#L<line>`, only when the page front matter has both `url` and `sha`
    /// (https, no query or fragment, hex sha) and `relpath` stays inside the repo. The app never fetches it.
    func githubURL(relpath: String, line: Int?) -> URL? {
        guard let url, let sha, WikiLink.isSafeRelativePath(relpath),
              sha.count >= 7, sha.count <= 64, sha.allSatisfy(\.isHexDigit),
              let base = URL(string: url), base.scheme == "https", base.host != nil,
              base.query == nil, base.fragment == nil else { return nil }
        var text = url
        while text.hasSuffix("/") { text.removeLast() }
        if text.hasSuffix(".git") { text.removeLast(4) }
        let encoded = relpath.split(separator: "/", omittingEmptySubsequences: false).map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/")
        return URL(string: "\(text)/blob/\(sha)/\(encoded)" + (line.map { "#L\($0)" } ?? ""))
    }

    /// nil project: the page `root`, else the opener's index root. A project: only `roots[project]`.
    func codeRoot(project: String?, openerRoot: String?) -> String? {
        if let project { return roots[project] }
        return root ?? openerRoot
    }

    private static func pair(_ line: String) -> (String, String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        func unquoted(_ text: String) -> String {
            guard text.count >= 2, let q = text.first, q == "\"" || q == "'", text.last == q else { return text }
            return String(text.dropFirst().dropLast())
        }
        let key = unquoted(line[..<colon].trimmingCharacters(in: .whitespaces))
        let value = unquoted(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        return key.isEmpty ? nil : (key, value)
    }

    private static func safe(_ value: String, home: String) -> String? {
        guard value.hasPrefix("/"), !value.split(separator: "/").contains("..") else { return nil }
        let path = (value as NSString).standardizingPath
        let realHome = URL(fileURLWithPath: home).resolvingSymlinksInPath().path
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard WikiProject.contains(root: home, path: path), WikiProject.contains(root: realHome, path: real) else { return nil }
        return path
    }
}

/// Chip behavior shared by the router and the preview runner: labels, `doc:` path rules, and the
/// argv of each preview command. Pure, so it is testable without a web view.
enum WikiChip {
    /// A command to run with argv only (never through a shell). `tool` is resolved to a binary by the runner.
    struct Command: Equatable {
        let tool: String
        let arguments: [String]
        let directory: String?
    }

    static func label(kind: String, value: String) -> String {
        switch kind {
        case "doc": return (value as NSString).lastPathComponent
        case "commit": return String(value.prefix(7))
        default: return "\(kind):\(value)"
        }
    }

    /// The label in a table cell: a `doc:` file name without its leading `YYYY-MM-DD-` (the tooltip keeps the full path).
    static func tableLabel(kind: String, value: String) -> String {
        let label = label(kind: kind, value: value)
        guard kind == "doc" else { return label }
        return label.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}-(?=.)"#, with: "", options: .regularExpression)
    }

    /// The file a `doc:` chip opens, or nil when it must stay inert. Relative values resolve against `root`;
    /// absolute ones must be regular files under `home` once symlinks are resolved. `..` is never accepted.
    static func docPath(value: String, root: String?, home: String = NSHomeDirectory()) -> String? {
        guard !value.isEmpty, !value.split(separator: "/").contains("..") else { return nil }
        let candidate: String
        if value.hasPrefix("/") {
            candidate = value
        } else {
            guard let root, WikiLink.isSafeRelativePath(value) else { return nil }
            candidate = (root as NSString).appendingPathComponent(value)
        }
        let resolved = (candidate as NSString).resolvingSymlinksInPath
        let base = (home as NSString).resolvingSymlinksInPath
        guard resolved.hasPrefix(base + "/") else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return resolved
    }

    /// Chips Bree handles itself: `doc` and `commit` (git), plus the `yakala` capture-card alias.
    static let builtinSchemes = ["doc", "commit", "yakala"]
    /// Compatibility scheme name of the original wiki. They render as chips even without a declaration (inert then).
    static let aliasSchemes = ["m"]

    /// Whether a click on `[kind:value]` does anything: a built-in chip or a chip declared in `.bree-wiki.json`.
    static func hasHandler(kind: String, config: WikiConfig) -> Bool {
        builtinSchemes.contains(kind) || config.chips[kind] != nil
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: .regularExpression) != nil
    }

    /// The preview command of a chip that runs one: `commit:` (git, built in) or a declared chip. nil for any other
    /// kind, an invalid value, or a missing root. Values are validated before they reach argv (never `-`-leading).
    static func previewCommand(kind: String, value: String, root: String?, config: WikiConfig = .empty) -> Command? {
        if kind == "commit" {
            guard let root, root.hasPrefix("/"), matches(value, #"^[0-9a-fA-F]{4,40}$"#) else { return nil }
            return Command(tool: "git", arguments: ["-C", root, "show", "--stat", "--format=%h %s%n%an · %ad", value], directory: nil)
        }
        return config.chips[kind]?.command(value: value)
    }
}

/// `.bree-wiki.json` in a wiki folder: the external commands the wiki's author declares. Bree knows no tool by name.
///
///     { "chips": { "m": { "argv": ["my-notes", "show", "{value}"], "title": "Note {value}",
///                         "valuePattern": "^[0-9]{1,12}$", "output": "markdown" } },
///       "hiddenTags": ["genel"], "agentKinds": ["bot"], "symbolCommand": ["my-index", "def", "{symbol}"] }
///
/// Parsing is lenient: an entry that is not valid is dropped, the rest stays.
struct WikiConfig: Equatable {
    static let fileName = ".bree-wiki.json"
    static let empty = WikiConfig()

    enum Output: String, Equatable {
        /// stdout in a code block (the default).
        case text
        /// stdout as markdown.
        case markdown
        /// stdout starting with a `<id>|<kind> (<iso date>)` record header (a memory tool's records).
        case memory
    }

    struct Chip: Equatable {
        let scheme: String
        /// `argv[0]` is a bare tool name; `{value}` is replaced in every element.
        let argv: [String]
        /// Page title; `{value}` and `{scheme}` are replaced.
        let title: String
        /// Regex the value must match entirely (default: an id of letters, digits, `.` `_` `-`).
        let valuePattern: String?
        let output: Output

        static let defaultValuePattern = #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#

        func accepts(_ value: String) -> Bool {
            guard !value.isEmpty, !value.hasPrefix("-"), !value.contains(where: { $0.isNewline || $0 == "\0" }) else { return false }
            return value.range(of: valuePattern ?? Self.defaultValuePattern, options: .regularExpression) != nil
        }

        func command(value: String) -> WikiChip.Command? {
            guard accepts(value), let tool = argv.first else { return nil }
            return WikiChip.Command(
                tool: tool, arguments: argv.dropFirst().map { $0.replacingOccurrences(of: "{value}", with: value) }, directory: nil)
        }

        func pageTitle(value: String) -> String {
            title.replacingOccurrences(of: "{value}", with: value).replacingOccurrences(of: "{scheme}", with: scheme)
        }
    }

    var chips: [String: Chip] = [:]
    /// Bare tags (`[genel]`) that are removed from pages.
    var hiddenTags: Set<String> = []
    /// Extra record kinds (besides `agent` and `assistant`) that `memory` output shows as an agent reply.
    var agentKinds: Set<String> = []
    /// `["tool", "arg", "{symbol}"]`, run in the project root for `code:path#symbol` links.
    var symbolCommand: [String]?
    /// The wiki folder this config was read from; "" for none.
    var folder = ""
    /// True for the global folder the user picked. A repo-local wiki's commands need a one-time approval.
    var isTrusted = true

    private static func isTool(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._+-".contains($0)) }
            && !name.hasPrefix("-")
    }

    static func parse(_ data: Data, folder: String = "", isTrusted: Bool = true) -> WikiConfig {
        var config = WikiConfig(folder: folder, isTrusted: isTrusted)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return config }
        if let chips = object["chips"] as? [String: Any] {
            for (scheme, raw) in chips {
                guard WikiLink.isChipKind(scheme), !WikiChip.builtinSchemes.contains(scheme),
                      scheme != "inert", scheme != "broken",
                      let entry = raw as? [String: Any],
                      let argv = entry["argv"] as? [String], let tool = argv.first, isTool(tool),
                      argv.contains(where: { $0.contains("{value}") }) else { continue }
                let pattern = (entry["valuePattern"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                if let pattern, (try? NSRegularExpression(pattern: pattern)) == nil { continue }
                config.chips[scheme] = Chip(
                    scheme: scheme, argv: argv, title: (entry["title"] as? String) ?? "{scheme}:{value}", valuePattern: pattern,
                    output: (entry["output"] as? String).flatMap(Output.init(rawValue:)) ?? .text)
            }
        }
        if let tags = object["hiddenTags"] as? [String] {
            config.hiddenTags = Set(tags.filter { $0.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil })
        }
        if let kinds = object["agentKinds"] as? [String] {
            config.agentKinds = Set(kinds.filter { $0.range(of: #"^[A-Za-z0-9_-]{1,32}$"#, options: .regularExpression) != nil })
        }
        if let argv = object["symbolCommand"] as? [String], let tool = argv.first, isTool(tool),
           argv.contains(where: { $0.contains("{symbol}") }) {
            config.symbolCommand = argv
        }
        return config
    }

    /// The config of a wiki folder; trusted when it is the global folder.
    static func load(folder: String, global: String = WikiIndex.wikiDirectory()) -> WikiConfig {
        let trusted = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            == URL(fileURLWithPath: global).resolvingSymlinksInPath().path
        guard let data = FileManager.default.contents(atPath: (folder as NSString).appendingPathComponent(fileName)) else {
            return WikiConfig(folder: folder, isTrusted: trusted)
        }
        return parse(data, folder: folder, isTrusted: trusted)
    }

    /// The config that applies to a page: the one in the wiki folder the page lives in.
    static func forPage(_ path: String) -> WikiConfig {
        load(folder: WikiPaths.wikiRoot(containing: path))
    }

    /// `symbolCommand` with the symbol filled in; nil when none is declared or the symbol is not a plain name.
    func symbolArguments(symbol: String) -> [String]? {
        guard let symbolCommand, !symbol.isEmpty, symbol.count <= 200, !symbol.hasPrefix("-"),
              !symbol.contains(where: { $0.isWhitespace || $0.isNewline || $0 == "\0" }) else { return nil }
        return symbolCommand.map { $0.replacingOccurrences(of: "{symbol}", with: symbol) }
    }
}

/// One-time approval of the commands a repo-local wiki declares, like `direnv allow`: per (folder, argv), kept in
/// UserDefaults. The global folder the user picked is trusted without asking.
enum WikiTrust {
    static let defaultsKey = "wiki.trustedCommands"

    /// The approval key: the symlink-resolved folder and the argv template (with its `{value}` placeholders).
    static func key(folder: String, argv: [String]) -> String {
        URL(fileURLWithPath: folder).resolvingSymlinksInPath().path + "\n" + argv.joined(separator: "\u{1F}")
    }

    static func isApproved(folder: String, argv: [String], defaults: UserDefaults = .standard) -> Bool {
        (defaults.stringArray(forKey: defaultsKey) ?? []).contains(key(folder: folder, argv: argv))
    }

    static func approve(folder: String, argv: [String], defaults: UserDefaults = .standard) {
        var keys = defaults.stringArray(forKey: defaultsKey) ?? []
        let key = key(folder: folder, argv: argv)
        if !keys.contains(key) { keys.append(key) }
        defaults.set(keys, forKey: defaultsKey)
    }

    /// Whether `argv` (a template declared by `config`) may run: always for a trusted config, else after a stored
    /// approval, else when the user allows it in the dialog (which is then remembered).
    @MainActor
    static func authorize(config: WikiConfig, argv: [String], defaults: UserDefaults = .standard,
                          ask: (_ folder: String, _ command: String) -> Bool = askUser) -> Bool {
        if config.isTrusted || isApproved(folder: config.folder, argv: argv, defaults: defaults) { return true }
        guard ask(config.folder, argv.joined(separator: " ")) else { return false }
        approve(folder: config.folder, argv: argv, defaults: defaults)
        return true
    }

    @MainActor
    static func askUser(folder: String, command: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "wiki.trust.title", defaultValue: "Allow this wiki to run a command?")
        alert.informativeText = String(
            format: String(localized: "wiki.trust.message",
                           defaultValue: "The wiki in %@ wants to run:\n%@\n\nOnly allow it if you trust this repository. Bree asks once for this command."),
            (folder as NSString).abbreviatingWithTildeInPath, command)
        alert.addButton(withTitle: String(localized: "wiki.trust.allow", defaultValue: "Allow"))
        alert.addButton(withTitle: String(localized: "wiki.trust.deny", defaultValue: "Don't Allow"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Finds the binary of a declared tool: the user's login-shell PATH first, then the fixed folders.
enum WikiToolLookup {
    static var fixedFolders: [String] {
        [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
    }

    static func resolve(_ tool: String, loginPath: [String], fixed: [String] = fixedFolders,
                        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        guard !tool.isEmpty, !tool.contains("/") else { return nil }
        for folder in loginPath + fixed where folder.hasPrefix("/") {
            let candidate = (folder as NSString).appendingPathComponent(tool)
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    /// `PATH` as the user's login shell sets it (a GUI app starts with a minimal one). Read once; 3 s limit, then the
    /// app's own PATH.
    static let loginPath: [String] = {
        let fallback = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        process.arguments = ["-ilc", "printf '\\nBREE_PATH=%s\\n' \"$PATH\""]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return fallback }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("BREE_PATH=") }) else { return fallback }
        let parsed = line.dropFirst("BREE_PATH=".count).split(separator: ":").map(String.init)
        return parsed.isEmpty ? fallback : parsed
    }()

    static func executable(for tool: String) -> String? { resolve(tool, loginPath: loginPath) }
}

/// The wiki's own text size in px (separate from the markdown viewer's), changed with ⌘= ⌘− ⌘0.
enum WikiFontSize {
    static let key = "wiki.fontSize"
    static let defaultSize: Double = 14
    static let minimum: Double = 12
    static let maximum: Double = 18

    static func clamp(_ value: Double) -> Double { min(max(value, minimum), maximum) }

    static func resolved(defaults: UserDefaults = .standard) -> Double {
        guard let raw = defaults.object(forKey: key) as? NSNumber else { return defaultSize }
        return clamp(raw.doubleValue)
    }

    static func set(_ value: Double, defaults: UserDefaults = .standard) {
        defaults.set(Int(clamp(value).rounded()), forKey: key)
    }

    /// The size handed to the shared markdown renderer, which zooms by `size / 15` while the wiki
    /// stylesheet is written for 14 px.
    static func rendererSize(_ size: Double) -> Double {
        size * MarkdownFontSizeSettings.baseRenderPointSize / defaultSize
    }
}
