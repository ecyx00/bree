import CoreGraphics
import Foundation

// Pure helpers behind the Wiki popover and the two resizable popovers. No AppKit views here.

/// Pages the Wiki popover shows, newest on top. `list` is the root; the stack holds opened pages.
extension Locale {
    /// The language the app UI is shown in (xcstrings), so dates agree with the surrounding text
    /// when the app language differs from the system region.
    static var breeApp: Locale {
        Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
    }
}

struct WikiBackStack: Equatable {
    struct Entry: Equatable {
        let path: String
        var title: String
        /// The line a code or source page opens at (marked), nil for a plain page.
        var line: Int?
        /// Where the reader was on this page when they left it, in CSS px.
        var scrollY: Double = 0
    }

    private(set) var entries: [Entry] = []

    var current: Entry? { entries.last }
    var isEmpty: Bool { entries.isEmpty }
    var depth: Int { entries.count }

    /// Opening the page that is already on top is a no-op.
    mutating func push(_ entry: Entry) {
        if let last = entries.last, last.path == entry.path, last.line == entry.line { return }
        entries.append(entry)
    }

    /// Remembers where the reader is on the current page, then opens `entry` on top of it.
    mutating func push(_ entry: Entry, leavingScrollY: Double) {
        recordScroll(leavingScrollY)
        push(entry)
    }

    /// Updates the offset of the page on top (for the snapshot taken when the popover closes).
    mutating func recordScroll(_ y: Double) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].scrollY = max(0, y)
    }

    /// Sets the title of the page on top (a memory page learns its title once its text has loaded).
    mutating func retitleCurrent(_ title: String) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].title = title
    }

    @discardableResult
    mutating func pop() -> Entry? { entries.popLast() }

    mutating func removeAll() { entries.removeAll() }

    /// The label of the back button: the page below the current one, else the list ("Wiki").
    var previousTitle: String? { entries.count >= 2 ? entries[entries.count - 2].title : nil }
}

/// A chip page (`commit:` or a chip declared in .bree-wiki.json) opened as a page of the popover.
/// The back stack addresses it with a pseudo path `memory:<kind>:<value>`; the text comes from `WikiPreview`.
enum WikiMemory {
    static let pathPrefix = "memory:"

    static func pseudoPath(kind: String, value: String) -> String { "\(pathPrefix)\(kind):\(value)" }

    /// The chip kind and value behind a pseudo path; nil for a real file path.
    static func chip(fromPath path: String) -> (kind: String, value: String)? {
        guard path.hasPrefix(pathPrefix) else { return nil }
        let parts = path.dropFirst(pathPrefix.count).split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        return (String(parts[0]), String(parts[1]))
    }

    enum Kind: Equatable {
        /// `agent` or `assistant`, or a kind the wiki declares in `agentKinds`: the agent's reply.
        case agent
        /// `user`: the user's own message.
        case user
        /// Anything else the memory tool may add.
        case note

        static let builtinAgentKinds: Set<String> = ["agent", "assistant"]

        init(raw: String, agentKinds: Set<String> = []) {
            if Self.builtinAgentKinds.contains(raw) || agentKinds.contains(raw) {
                self = .agent
            } else {
                self = raw == "user" ? .user : .note
            }
        }
    }

    /// The first line of a memory tool's record output: `4504+1|agent (2026-10-05T16:13:43+03:00)`, then `agent: <text>`.
    struct Header: Equatable {
        var id: String
        var kind: Kind
        var date: Date?
        /// The text without the header line and the `kind:` label of its first line.
        var body: String
    }

    /// nil when the first line is not such a header (the caller then shows the text as it is).
    static func parse(_ text: String, agentKinds: Set<String> = []) -> Header? {
        let lines = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first, let match = headerPattern.firstMatch(
            in: String(first), range: NSRange(location: 0, length: (String(first) as NSString).length))
        else { return nil }
        let line = String(first) as NSString
        func group(_ n: Int) -> String? {
            let range = match.range(at: n)
            return range.location == NSNotFound ? nil : line.substring(with: range)
        }
        guard let id = group(1), let raw = group(2) else { return nil }
        var body = lines.count > 1 ? String(lines[1]) : ""
        if body.hasPrefix(raw + ":") {
            body = String(body.dropFirst(raw.count + 1)).trimmingCharacters(in: .init(charactersIn: " "))
        }
        return Header(id: id, kind: Kind(raw: raw, agentKinds: agentKinds), date: group(3).flatMap(parseDate),
                      body: body.trimmingCharacters(in: .newlines))
    }

    private static let headerPattern = try! NSRegularExpression(
        pattern: #"^([0-9]+)(?:\+[0-9]+)?\|([A-Za-z0-9_-]+)(?: \(([^)]*)\))?\s*$"#)

    private static func parseDate(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }

    /// "5 Eki 2026 16:13" in Turkish, "5 Oct 2026 16:13" in English.
    static func dateText(_ date: Date, locale: Locale = .breeApp, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "d MMM yyyy HH:mm"
        return formatter.string(from: date)
    }

    static func label(_ kind: Kind) -> String {
        switch kind {
        case .agent: String(localized: "wiki.memory.agent", defaultValue: "Agent reply")
        case .user: String(localized: "wiki.memory.user", defaultValue: "Your message")
        case .note: String(localized: "wiki.memory.note", defaultValue: "Note")
        }
    }

    /// "Agent reply · 5 Oct 2026 16:13"; the label alone when the date is unknown.
    static func title(kind: Kind, date: Date?, locale: Locale = .breeApp, timeZone: TimeZone = .current) -> String {
        guard let date else { return label(kind) }
        return "\(label(kind)) · \(dateText(date, locale: locale, timeZone: timeZone))"
    }

    /// The title and markdown of a loaded chip page. `text` nil: the command failed or its tool is missing.
    static func page(kind chipKind: String, value: String, text: String?, config: WikiConfig = .empty) -> (title: String, markdown: String) {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return (label(.note), String(localized: "wiki.memory.unavailable", defaultValue: "This note could not be loaded."))
        }
        switch chipKind {
        case "commit":
            let title = String(format: String(localized: "wiki.memory.commit", defaultValue: "Commit %@"), String(value.prefix(7)))
            return (title, WikiFilePage.fenced(text, language: "text"))
        default:
            guard let chip = config.chips[chipKind] else { return (label(.note), text) }
            switch chip.output {
            case .memory:
                guard let header = parse(text, agentKinds: config.agentKinds) else { return (chip.pageTitle(value: value), text) }
                return (title(kind: header.kind, date: header.date), header.body)
            case .markdown: return (chip.pageTitle(value: value), text)
            case .text: return (chip.pageTitle(value: value), WikiFilePage.fenced(text, language: "text"))
            }
        }
    }
}

enum WikiPopoverSizing {
    static let homeMinimum: CGFloat = 280
    static let maximum: CGFloat = 520
    /// Header (36) and its divider.
    static let chrome: CGFloat = 37

    /// The popover height of the topic list: its content plus the header, between 280 and 520 pt.
    static func homeHeight(content: CGFloat) -> CGFloat { min(max(content + chrome, homeMinimum), maximum) }
}

/// Titles and dates the Wiki popover shows. Pure.
enum WikiTitle {
    /// "semble · README.md": the repo with the file name; the bare name when no repo is known.
    static func file(path: String, repo: String?) -> String {
        let name = (path as NSString).lastPathComponent
        guard let repo, !repo.isEmpty, repo != name else { return name }
        return "\(repo) · \(name)"
    }

    /// The name of the nearest folder above `path` that holds a `.git`, searching up to (not including) `home`.
    static func repoName(forFile path: String, home: String = NSHomeDirectory(), fileManager: FileManager = .default) -> String? {
        // A source snapshot (`_kaynaklar/snap/<slug>/...`) belongs to the repo it was taken from: its slug.
        let parts = path.components(separatedBy: "/")
        if let snap = parts.firstIndex(of: "snap"), snap >= 1, parts[snap - 1] == WikiPaths.sourcesFolder, snap + 2 < parts.count {
            return parts[snap + 1]
        }
        var dir = (path as NSString).deletingLastPathComponent
        while dir.count > 1, dir != home, dir != "/" {
            if fileManager.fileExists(atPath: (dir as NSString).appendingPathComponent(".git")) {
                return (dir as NSString).lastPathComponent
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    static func file(path: String) -> String { file(path: path, repo: repoName(forFile: path)) }

    /// The header title: empty while the page's own H1 is visible (the page tells the model), else the title.
    static func header(title: String, pageHeadingVisible: Bool) -> String { pageHeadingVisible ? "" : title }

    /// "10 Eki" in Turkish, "Oct 10" in English; the year is added for another year. An unparsable date is returned as is.
    static func shortDate(_ iso: String, locale: Locale = .breeApp, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = timeZone
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: String(iso.prefix(10))) else { return iso }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(sameYear ? "MMMd" : "yMMMd")
        return formatter.string(from: date)
    }
}

/// What a file page shows. Pure: reads the file, decides markdown / highlighted source / fallback.
enum WikiFilePage {
    static let maxBytes = 2 * 1024 * 1024
    enum Reason: Equatable { case tooLarge, binary, unreadable, forbidden }
    enum Content: Equatable {
        case markdown(String)
        /// A capture card (outside content): rendered, but with no images and inert links.
        case card(String)
        /// `markdown` is a fenced code block; the page script numbers its lines and marks `line`.
        case source(markdown: String, line: Int?)
        case unsupported(Reason)
    }

    static func load(path: String, line: Int?, wikiDir: String? = nil) -> Content {
        let wikiDir = wikiDir ?? WikiPaths.wikiRoot(containing: path)
        if WikiPaths.isBlockedSource(path, wikiDir: wikiDir) { return .unsupported(.forbidden) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber
        else { return .unsupported(.unreadable) }
        if size.intValue > maxBytes { return .unsupported(.tooLarge) }
        guard let data = FileManager.default.contents(atPath: path) else { return .unsupported(.unreadable) }
        if data.count > maxBytes { return .unsupported(.tooLarge) }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { return .unsupported(.binary) }
        let ext = (path as NSString).pathExtension.lowercased()
        let isMarkdown = ext == "md" || ext == "markdown"
        // Snapshots are untrusted downloads: plain text only, never rendered.
        let isSnap = WikiPaths.isSnapFile(path, wikiDir: wikiDir)
        if isMarkdown && WikiPaths.isYakalaCard(path, wikiDir: wikiDir) { return .card(text) }
        if isMarkdown && !isSnap { return .markdown(text) }
        return .source(markdown: fenced(text, language: isSnap ? "text" : language(forExtension: ext)), line: line)
    }

    /// A fence longer than any backtick run in `text`, so the file can never close it early.
    static func fenced(_ text: String, language: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        let body = text.hasSuffix("\n") ? String(text.dropLast()) : text
        return "\(fence)\(language)\n\(body)\n\(fence)\n"
    }

    /// highlight.js language of a file extension; "text" (no colouring) for anything unknown.
    static func language(forExtension ext: String) -> String {
        switch ext {
        case "swift": return "swift"
        case "js", "mjs", "cjs", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "rs": return "rust"
        case "go": return "go"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hpp", "hh": return "cpp"
        case "m", "mm": return "objectivec"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "rb": return "ruby"
        case "sh", "bash", "zsh": return "bash"
        case "json": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "html", "htm", "xml", "plist": return "xml"
        case "css": return "css"
        case "sql": return "sql"
        default: return "text"
        }
    }
}

/// The popover's stack per workspace, in memory, so closing and reopening keeps the reader's place.
final class WikiPopoverMemory {
    static let shared = WikiPopoverMemory()
    private var stacks: [UUID: WikiBackStack] = [:]

    /// An empty stack (the reader went home) forgets the place.
    func save(_ stack: WikiBackStack, for workspace: UUID) {
        stacks[workspace] = stack.isEmpty ? nil : stack
    }

    func stack(for workspace: UUID) -> WikiBackStack? { stacks[workspace] }
}

/// JS run after a page renders: number the source lines, then scroll (restored offset, else target line, else top).
enum WikiPageScript {
    static func afterRender(source: Bool, line: Int?, scrollY: Double?, inert: Bool = false) -> String {
        var js = "(function(){var c=document.getElementById('content');if(!c){return;}\n"
        if inert {
            // Capture cards hold outside content: no images, no live links.
            js += "c.querySelectorAll('img,picture,video,audio,iframe,.bree-remote-image-placeholder').forEach(function(n){n.remove();});"
            js += "c.querySelectorAll('a').forEach(function(a){a.removeAttribute('href');});\n"
        }
        if source {
            js += decorate.replacingOccurrences(of: "TARGET", with: line.map(String.init) ?? "null") + "\n"
        }
        // The scroll is retried for up to 1.5 s: on a freshly opened popover the page lays out after this script ran,
        // and a smooth-scroll (`html { scroll-behavior: smooth }`) or a clamp to a short document would lose it.
        js += scrollHelper
        js += "if(window.__breeReportHeading){window.__breeReportHeading(true);}"
        if let scrollY {
            js += "bree_go(\(Int(scrollY.rounded())));"
        } else if source, line != nil {
            js += "bree_go('target');"
        } else {
            js += "bree_go(0);"
        }
        return js + "})();"
    }

    /// `bree_go(y | 'target')`: scrolls to `y` (or the marked line) until the layout settles; the reader's own input stops it.
    private static let scrollHelper = #"""
    function bree_go(where){var root=document.documentElement,prev=root.style.scrollBehavior,stop=false,t0=performance.now();
    root.style.scrollBehavior='auto';
    function halt(){stop=true;}
    ['wheel','keydown','mousedown','touchstart'].forEach(function(n){window.addEventListener(n,halt,{once:true,passive:true});});
    function want(){if(where!=='target'){return where;}var t=c.querySelector('.bree-ln-target');
      return t?Math.max(0,Math.round(t.getBoundingClientRect().top+window.scrollY-window.innerHeight/3)):0;}
    (function step(){var y=want();
      if(!stop){window.scrollTo(0, y);}
      var settled=Math.abs(window.scrollY-y)<2,age=performance.now()-t0;
      if(stop||(settled&&age>250)||age>1500){root.style.scrollBehavior=prev;return;}
      requestAnimationFrame(step);})();}
    """#

    /// Splits the highlighted code into one block per line (re-opening spans that cross a line) and marks the target.
    private static let decorate = #"""
    (function(target){var code=c.querySelector('pre > code.hljs');if(!code||code.dataset.breeLines){return;}
    code.dataset.breeLines='1';
    var lines=code.innerHTML.split('\n');if(lines.length>1&&lines[lines.length-1]===''){lines.pop();}
    var open=[],out=[];
    lines.forEach(function(l,i){
      var s=open.join('')+l,re=/<(\/?)span([^>]*)>/g,m;
      while((m=re.exec(l))){if(m[1]){open.pop();}else{open.push('<span'+m[2]+'>');}}
      var ind=0,txt=l.replace(/<[^>]*>/g,'');for(var k=0;k<txt.length;k++){if(txt[k]===' '){ind++;}else if(txt[k]==='\t'){ind+=8-(ind%8);}else{break;}}
      out.push('<span class="bree-ln'+(i+1===target?' bree-ln-target':'')+'" data-n="'+(i+1)+'" style="--ind:'+ind+'ch">'+s+'</span>'.repeat(open.length)+'\n</span>');
    });
    code.innerHTML=out.join('');})(TARGET);
    """#
}

/// "This project" or "General" on the one topic list.
enum WikiScope: Equatable {
    case project, general
}

enum WikiBrowse {
    /// The scopes that have a list. Without a matched project only General shows; a missing
    /// `_genel/index.json` hides General.
    static func scopes(project: WikiIndex?, general: WikiIndex?) -> [WikiScope] {
        (project == nil ? [] : [WikiScope.project]) + (general == nil ? [] : [WikiScope.general])
    }

    /// "This project" is on by default when the project has pages; otherwise General (when it exists).
    /// The section name of the topic list (the wiki's own first group title), reused by search.
    static func topicsTitle(project: WikiIndex?, general: WikiIndex?) -> String? {
        [project, general].compactMap { $0 }.lazy.compactMap { $0.groups.first?.title }.first { !$0.isEmpty }
    }

    static func defaultScope(project: WikiIndex?, general: WikiIndex?) -> WikiScope {
        if let project, !project.pages.isEmpty { return .project }
        if general != nil { return .general }
        return .project
    }

    static func index(for scope: WikiScope, project: WikiIndex?, general: WikiIndex?) -> WikiIndex? {
        scope == .project ? project : general
    }

    /// Keeps the chosen scope while it still exists, else falls back to the default.
    static func resolvedScope(_ scope: WikiScope?, project: WikiIndex?, general: WikiIndex?) -> WikiScope {
        if let scope, scopes(project: project, general: general).contains(scope) { return scope }
        return defaultScope(project: project, general: general)
    }
}

/// `window.breeWikiAnchors` for the Architecture board: code anchors (`<relpath>#<symbol>`) of the
/// wiki pages of the matched project that point into the current repo.
enum WikiAnchors {
    struct Entry: Equatable {
        let slug: String
        let title: String
    }

    private static let link = try! NSRegularExpression(pattern: #"\]\(code:(@?[^)\s]+)\)"#)

    /// An unqualified link counts when the page's code root (front-matter `root`, else the index root)
    /// is `repoRoot`; `code:@project/..` counts when the page's `roots[project]` is `repoRoot`.
    /// The first page in index order wins a duplicated anchor. Pages `read` cannot return are skipped.
    static func build(index: WikiIndex, repoRoot: String, read: (WikiPage) -> String?) -> [String: Entry] {
        var map: [String: Entry] = [:]
        for page in index.pages {
            guard let text = read(page) else { continue }
            let context = WikiPageContext.parse(markdown: text)
            let entry = Entry(slug: page.slug, title: page.title)
            var inFence = false
            for line in text.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
                if inFence { continue }
                let ns = line as NSString
                for m in link.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                    switch WikiLink.parse("code:" + ns.substring(with: m.range(at: 1))) {
                    case .codeSymbol(let path, let symbol):
                        let root = context.codeRoot(project: nil, openerRoot: index.root)
                        guard let root, WikiProject.same(root, repoRoot) else { continue }
                        if map[path + "#" + symbol] == nil { map[path + "#" + symbol] = entry }
                    case .qualifiedCode(let project, let path, _, let symbol?):
                        guard let root = context.codeRoot(project: project, openerRoot: nil),
                              WikiProject.same(root, repoRoot) else { continue }
                        if map[path + "#" + symbol] == nil { map[path + "#" + symbol] = entry }
                    default:
                        continue
                    }
                }
            }
        }
        return map
    }

    /// Sorted keys, so the same wiki always gives the same script.
    static func json(_ map: [String: Entry]) -> String {
        let object = map.mapValues { ["slug": $0.slug, "title": $0.title] }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        // The script sits in a JS source string: keep a "</" or U+2028 from ending anything early.
        return text.replacingOccurrences(of: "</", with: "<\\/")
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// Size rules of the resizable popovers: clamp to the visible screen, remember per popover.
enum PopoverSizing {
    static let minimum = CGSize(width: 480, height: 360)
    /// Space kept free around a popover on the screen.
    static let screenMargin: CGFloat = 16

    /// Within `minimum` and the visible frame (less the margin). A screen smaller than the minimum wins.
    /// `maxHeight` lowers the height ceiling further (room below the popover's top edge).
    static func clamp(_ size: CGSize, visible: CGRect, maxHeight: CGFloat? = nil) -> CGSize {
        let ceilingW = max(visible.width - screenMargin * 2, 1)
        var ceilingH = max(visible.height - screenMargin * 2, 1)
        if let maxHeight { ceilingH = min(ceilingH, max(maxHeight, 1)) }
        let width = min(max(size.width, min(minimum.width, ceilingW)), ceilingW)
        let height = min(max(size.height, min(minimum.height, ceilingH)), ceilingH)
        return CGSize(width: width.rounded(), height: height.rounded())
    }

    private static func key(_ name: String) -> String { "bree.popoverSize.\(name)" }

    static func save(_ size: CGSize, name: String, defaults: UserDefaults = .standard) {
        defaults.set(["w": Double(size.width), "h": Double(size.height)], forKey: key(name))
    }

    /// The remembered size, clamped to `visible`; nil when none was saved.
    static func load(name: String, visible: CGRect, defaults: UserDefaults = .standard) -> CGSize? {
        guard let stored = defaults.dictionary(forKey: key(name)),
              let w = stored["w"] as? Double, let h = stored["h"] as? Double, w > 0, h > 0 else { return nil }
        return clamp(CGSize(width: w, height: h), visible: visible)
    }
}
