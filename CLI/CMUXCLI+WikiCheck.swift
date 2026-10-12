import Darwin
import Foundation

extension CMUXCLI {
    /// `wiki check [dir]` validates a wiki folder against the bree-wiki/1 contract the app reads
    /// (Sources/WikiSupport.swift, guide: Resources/guides/wiki.md). It runs before socket discovery, so no
    /// running app is needed. Every check prints one PASS or FAIL line; exit status 1 when any check failed.
    ///
    /// The app code (WikiSupport.swift, WikiRouter.swift) imports AppKit and cannot be linked into this
    /// target, so the index decoding, the link parsing and the symbol scan are ported verbatim from there
    /// (`WikiIndex.decode`, `WikiIndex.pagePath`, `WikiLink.parseCode`, `SymbolLine.find`).
    func runWikiCommand(command: String, commandArgs: [String]) throws -> Bool {
        guard command == "wiki" else { return false }
        let args = commandArgs
        if args.isEmpty || args == ["--help"] || args == ["-h"] || args.first == "help" {
            print(Self.wikiUsage)
            return true
        }
        guard args.first == "check", args.count <= 2 else {
            throw CLIError(message: "Unknown wiki command: \(args.joined(separator: " "))\n\n" + Self.wikiUsage, exitCode: 2)
        }
        let explicit = args.count == 2 ? args[1] : nil
        let report = WikiCheck.run(directory: try WikiCheck.resolveDirectory(explicit: explicit))
        for line in report.lines { print(line) }
        print("\(report.passed) passed, \(report.failed) failed")
        if report.failed > 0 { Darwin.exit(1) }
        return true
    }

    static var wikiUsage: String {
        """
        Usage: bree wiki check [dir]

        Validate a wiki folder against the bree-wiki/1 contract that Bree reads (see `bree guide wiki`).
        dir defaults to the nearest .bree/wiki above the current directory. Needs no running app.

        Checks, one PASS or FAIL line each:
          index.json parses and has the required fields (project, group title, page slug and title)
          every listed page file exists inside the wiki folder
          every [[slug]] names a listed page
          every code: link points to a file that exists; :line is within the file; #symbol is found
        Exit status 1 when any check fails.
        """
    }
}

enum WikiCheck {
    struct Report {
        var lines: [String] = []
        var passed = 0
        var failed = 0
        mutating func pass(_ text: String) { passed += 1; lines.append("PASS \(text)") }
        mutating func fail(_ text: String) { failed += 1; lines.append("FAIL \(text)") }
    }

    struct Page { let slug: String; let title: String; let file: String? }

    static func resolveDirectory(explicit: String?) throws -> String {
        let fm = FileManager.default
        if let explicit {
            let path = (explicit as NSString).expandingTildeInPath
            let absolute = path.hasPrefix("/") ? path : (fm.currentDirectoryPath as NSString).appendingPathComponent(path)
            return URL(fileURLWithPath: absolute).standardizedFileURL.path
        }
        var current = URL(fileURLWithPath: fm.currentDirectoryPath).standardizedFileURL.path
        while true {
            let candidate = (current as NSString).appendingPathComponent(".bree/wiki")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate, isDirectory: &isDir), isDir.boolValue { return candidate }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current || parent.isEmpty { break }
            current = parent
        }
        throw CLIError(message: "No .bree/wiki found above the current directory. Pass the wiki folder: bree wiki check <dir>", exitCode: 1)
    }

    static func run(directory dir: String) -> Report {
        var report = Report()
        let indexPath = (dir as NSString).appendingPathComponent("index.json")
        guard let data = FileManager.default.contents(atPath: indexPath) else {
            report.fail("index.json: cannot be read at \(indexPath)")
            return report
        }
        let decoded: (project: String, root: String, schema: String, pages: [Page], groups: Int)
        do { decoded = try decodeIndex(data) } catch {
            report.fail("index.json: \((error as? IndexError)?.message ?? "it cannot be decoded")")
            return report
        }
        report.pass("index.json parses (project \(decoded.project), \(decoded.pages.count) pages in \(decoded.groups) groups)")
        if decoded.schema != "bree-wiki/1" {
            report.pass("index.json schema is \"\(decoded.schema)\" (the app does not enforce it; the contract is bree-wiki/1)")
        }
        let slugs = Set(decoded.pages.map(\.slug))
        if slugs.count != decoded.pages.count { report.fail("index.json: a slug is listed more than once") }

        // Same rule as WikiIndex.withRoot / WikiLibrary.load: a repo-local index may omit `root`.
        var codeRoot: String? = decoded.root.isEmpty ? nil : decoded.root
        if codeRoot == nil, (dir as NSString).lastPathComponent == "wiki",
           ((dir as NSString).deletingLastPathComponent as NSString).lastPathComponent == ".bree" {
            codeRoot = ((dir as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
        }

        var lineCounts: [String: Int?] = [:]
        for page in decoded.pages {
            guard let path = pagePath(page, dir: dir) else {
                report.fail("page \(page.slug): its file path is not allowed (it must be a .md file inside the wiki folder)")
                continue
            }
            guard let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) else {
                report.fail("page \(page.slug): file missing or unreadable at \(path)")
                continue
            }
            report.pass("page \(page.slug): \((path as NSString).lastPathComponent) exists")
            for target in wikiLinks(in: text) {
                switch target {
                case .page(let slug):
                    if slugs.contains(slug) { report.pass("page \(page.slug): [[\(slug)]] is a listed page") }
                    else { report.fail("page \(page.slug): [[\(slug)]] names no listed page") }
                case .code(let path, let line, let symbol, let raw):
                    guard let path else { report.fail("page \(page.slug): code:\(raw) is not a safe relative path"); continue }
                    guard let root = codeRoot else {
                        report.fail("page \(page.slug): code:\(raw) cannot be resolved, the index has no \"root\"")
                        continue
                    }
                    let file = (root as NSString).appendingPathComponent(path)
                    var isDir: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: file, isDirectory: &isDir), !isDir.boolValue else {
                        if line == nil && symbol == nil && isDir.boolValue { report.pass("page \(page.slug): code:\(raw) is a folder") }
                        else { report.fail("page \(page.slug): code:\(raw) file not found: \(file)") }
                        continue
                    }
                    if let line {
                        let count = lineCount(of: file, cache: &lineCounts)
                        if let count, line <= count { report.pass("page \(page.slug): code:\(raw) line \(line) is within \(count) lines") }
                        else { report.fail("page \(page.slug): code:\(raw) line \(line) is out of range (file has \(count.map(String.init) ?? "unreadable") lines)") }
                    } else if let symbol {
                        if let found = SymbolScan.find(symbol, inFileAt: file) { report.pass("page \(page.slug): code:\(raw) found at line \(found)") }
                        else { report.fail("page \(page.slug): code:\(raw) symbol \"\(symbol)\" not found in \(path)") }
                    } else {
                        report.pass("page \(page.slug): code:\(raw) exists")
                    }
                case .qualified(let raw):
                    report.pass("page \(page.slug): code:\(raw) belongs to another project, not checked")
                }
            }
        }
        return report
    }

    // MARK: Index (ported from WikiIndex.decode in Sources/WikiSupport.swift)

    struct IndexError: Error { let message: String }

    static func decodeIndex(_ data: Data) throws -> (project: String, root: String, schema: String, pages: [Page], groups: Int) {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) } catch { throw IndexError(message: "it is not valid JSON") }
        guard let dict = object as? [String: Any] else { throw IndexError(message: "the top level must be an object") }
        func text(_ any: Any?) -> String? { (any as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let project = text(dict["project"]), !project.isEmpty else { throw IndexError(message: "\"project\" is missing") }
        var pages: [Page] = []
        var groupCount = 0
        if let raw = dict["groups"] {
            guard let list = raw as? [Any] else { throw IndexError(message: "\"groups\" must be a list") }
            for (g, item) in list.enumerated() {
                guard let group = item as? [String: Any] else { throw IndexError(message: "groups[\(g)] must be an object") }
                guard let title = text(group["title"]), !title.isEmpty else { throw IndexError(message: "groups[\(g)]: \"title\" is missing") }
                groupCount += 1
                if let rawPages = group["pages"] {
                    guard let pageList = rawPages as? [Any] else { throw IndexError(message: "groups[\(g)].pages must be a list") }
                    for (p, pageItem) in pageList.enumerated() {
                        let at = "groups[\(g)].pages[\(p)]"
                        guard let page = pageItem as? [String: Any] else { throw IndexError(message: "\(at) must be an object") }
                        guard let slug = text(page["slug"]), !slug.isEmpty else { throw IndexError(message: "\(at): \"slug\" is missing") }
                        guard let pageTitle = text(page["title"]), !pageTitle.isEmpty else { throw IndexError(message: "\(at): \"title\" is missing") }
                        let file = text(page["file"]).flatMap { $0.isEmpty ? nil : $0 }
                        guard file != nil || isSafeSlug(slug) else { throw IndexError(message: "\(at): \"slug\" must not contain / \\ or ..") }
                        pages.append(Page(slug: slug, title: pageTitle, file: file))
                    }
                }
            }
        }
        return (project, text(dict["root"]) ?? "", text(dict["schema"]) ?? "", pages, groupCount)
    }

    static func isSafeSlug(_ slug: String) -> Bool {
        !slug.isEmpty && !slug.contains("/") && !slug.contains("\\") && !slug.contains("..")
    }

    /// Ported from WikiIndex.pagePath and WikiPaths.confined.
    static func pagePath(_ page: Page, dir: String) -> String? {
        let rel: String
        if let file = page.file {
            guard !file.isEmpty, !file.hasPrefix("/"), file.lowercased().hasSuffix(".md") else { return nil }
            rel = file
        } else {
            guard isSafeSlug(page.slug) else { return nil }
            rel = page.slug + ".md"
        }
        let root = URL(fileURLWithPath: dir).resolvingSymlinksInPath().path
        let resolved = URL(fileURLWithPath: (dir as NSString).appendingPathComponent(rel)).resolvingSymlinksInPath().path
        guard !resolved.split(separator: "/").contains(".."), resolved.hasPrefix(root + "/") else { return nil }
        return resolved
    }

    // MARK: Links

    enum Target {
        case page(String)
        case code(path: String?, line: Int?, symbol: String?, raw: String)
        case qualified(String)
    }

    private static let wikilink = try! NSRegularExpression(pattern: #"\[\[([^\]\|\n]+)(?:\|([^\]\n]+))?\]\]"#)
    private static let codeLink = try! NSRegularExpression(pattern: #"\]\(code:([^)\s]+)\)"#)

    /// `[[slug]]` and `(code:...)` links outside fenced blocks and inline code, like WikiMarkdown.preprocess.
    static func wikiLinks(in markdown: String) -> [Target] {
        var inFence = false
        var out: [Target] = []
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            if inFence { continue }
            let outside = line.components(separatedBy: "`").enumerated().filter { $0.offset % 2 == 0 }.map(\.element).joined(separator: " ")
            let range = NSRange(location: 0, length: (outside as NSString).length)
            for m in wikilink.matches(in: outside, range: range) {
                let slug = (outside as NSString).substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                out.append(.page(slug))
            }
            for m in codeLink.matches(in: outside, range: range) {
                let raw = (outside as NSString).substring(with: m.range(at: 1))
                out.append(parseCode(raw))
            }
        }
        return out
    }

    /// Ported from WikiLink.parse / parseCode / isSafeRelativePath.
    static func parseCode(_ rawHref: String) -> Target {
        if rawHref.hasPrefix("@") { return .qualified(rawHref) }
        var rest = rawHref.removingPercentEncoding ?? rawHref
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
        let safe = !rest.isEmpty && !rest.hasPrefix("/") && !rest.hasPrefix("~")
            && !rest.split(separator: "/", omittingEmptySubsequences: false).contains("..")
        guard safe else { return .code(path: nil, line: nil, symbol: nil, raw: rawHref) }
        if let symbol, !symbol.isEmpty { return .code(path: rest, line: nil, symbol: symbol, raw: rawHref) }
        return .code(path: rest, line: line, symbol: nil, raw: rawHref)
    }

    static func lineCount(of path: String, cache: inout [String: Int?]) -> Int? {
        if let cached = cache[path] { return cached }
        var count: Int?
        if let data = FileManager.default.contents(atPath: path), let text = String(data: data, encoding: .utf8) {
            count = text.components(separatedBy: "\n").count - (text.hasSuffix("\n") ? 1 : 0)
        }
        cache[path] = count
        return count
    }
}

/// The definition scan of the app (`SymbolLine` in Sources/WikiRouter.swift), copied unchanged: a declaration
/// keyword, optional modifiers before it, then the whole symbol name.
enum SymbolScan {
    private static let keywords = "def|class|func|function|fn|struct|enum|protocol|interface|trait|impl|type|const|let|var|static|actor|extension|module|object"

    static func find(_ symbol: String, in text: String) -> Int? {
        guard !symbol.isEmpty,
              let pattern = try? NSRegularExpression(
                pattern: "^\\s*(?:(?:export|public|private|internal|fileprivate|open|final|async|pub|default|abstract|override|static|@\\w+)\\s+)*(?:\(keywords))\\s+\(NSRegularExpression.escapedPattern(for: symbol))(?![\\w$])")
        else { return nil }
        var number = 0
        for line in text.components(separatedBy: "\n") {
            number += 1
            if pattern.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil { return number }
        }
        return nil
    }

    static func find(_ symbol: String, inFileAt path: String) -> Int? {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 2 * 1024 * 1024,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return find(symbol, in: text)
    }
}
