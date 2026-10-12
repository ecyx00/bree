import Foundation

// Wiki search: pure index, Turkish folding, ranking, snippets, recents. No UI here (see WikiPopover.swift).

enum WikiSearchText {
    /// Case-, diacritic- and Turkish-insensitive form: İ ı I i all become "i", ş->s, ğ->g, ü->u, ö->o, ç->c.
    /// One output character per input character, so offsets in the folded text map back to the original.
    static func fold(_ text: String) -> String { String(foldedCharacters(text)) }

    static func foldedCharacters(_ text: String) -> [Character] { text.map(foldCharacter) }

    static func foldCharacter(_ c: Character) -> Character {
        if c.isASCII { return Character(c.lowercased()) }
        switch c {
        case "İ", "ı", "I": return "i"
        default: break
        }
        let s = String(c).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return s.first ?? c
    }

    static func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    /// First index where `token` starts a word in `hay` (prefix match), or nil.
    static func firstMatch(of token: [Character], in hay: [Character]) -> Int? {
        let n = token.count
        guard n > 0, hay.count >= n else { return nil }
        var i = 0
        while i <= hay.count - n {
            if hay[i] == token[0], i == 0 || !isWordCharacter(hay[i - 1]), hay[i..<(i + n)].elementsEqual(token) { return i }
            i += 1
        }
        return nil
    }
}

enum WikiMatchKind: Int, Comparable {
    case exactTitle, titlePrefix, titleWord, oneLiner, heading, body
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    /// "Topics" section (title or one-liner); the rest are "In pages".
    var isTopic: Bool { self <= .oneLiner }
}

struct WikiSnippet: Equatable {
    var text: String
    /// Character offsets of the match inside `text`.
    var highlight: Range<Int>?
}

struct WikiSearchEntry: Equatable {
    var project: String
    var slug: String
    var title: String
    var oneLiner: String
    var updated: String
    var path: String
    var headings: [String]
    var body: String

    // Folded once at build time; searching never folds per keystroke.
    fileprivate let foldedTitle: [Character]
    fileprivate let foldedOneLiner: [Character]
    fileprivate let foldedHeadings: [[Character]]
    fileprivate let foldedBody: [Character]

    init(project: String, slug: String, title: String, oneLiner: String, updated: String, path: String,
         headings: [String], body: String) {
        self.project = project
        self.slug = slug
        self.title = title
        self.oneLiner = oneLiner
        self.updated = updated
        self.path = path
        self.headings = headings
        self.body = body
        foldedTitle = WikiSearchText.foldedCharacters(title)
        foldedOneLiner = WikiSearchText.foldedCharacters(oneLiner)
        foldedHeadings = headings.map(WikiSearchText.foldedCharacters)
        foldedBody = WikiSearchText.foldedCharacters(body)
    }
}

struct WikiSearchHit: Equatable {
    var entry: WikiSearchEntry
    var kind: WikiMatchKind
    var snippet: WikiSnippet
}

enum WikiSearchScope: Equatable {
    case all
    case project(String)
}

struct WikiSearchIndex {
    var entries: [WikiSearchEntry] = []

    /// Splits front matter off; returns the headings (outside code fences) and the body text.
    static func parse(markdown: String) -> (headings: [String], body: String) {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            lines.removeSubrange(0...end)
        }
        var headings: [String] = []
        var inFence = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, line.hasPrefix("#") else { continue }
            let hashes = line.prefix(while: { $0 == "#" })
            guard hashes.count <= 6, line.dropFirst(hashes.count).first == " " else { continue }
            let text = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { headings.append(text) }
        }
        // `<details>`/`<summary>` tags are markup; their text stays searchable body.
        let body = lines.joined(separator: "\n")
            .replacingOccurrences(of: "</?(details|summary)[^>]*>", with: "", options: .regularExpression)
        return (headings, body)
    }

    /// Topic pages of the given indexes, in order. Never reads `_kaynaklar` (snap) files.
    static func build(indexes: [WikiIndex], wikiDir: String? = nil) -> WikiSearchIndex {
        var seen = Set<String>()
        var entries: [WikiSearchEntry] = []
        for index in indexes {
            for page in index.pages {
                guard let path = index.pagePath(for: page, wikiDir: wikiDir),
                      !path.contains("/" + WikiPaths.sourcesFolder + "/"),
                      !WikiPaths.isSnapFile(path, wikiDir: wikiDir ?? index.base),
                      seen.insert(path).inserted,
                      let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
                let parsed = parse(markdown: text)
                entries.append(WikiSearchEntry(
                    project: index.project, slug: page.slug, title: page.title, oneLiner: page.oneLiner,
                    updated: page.updated, path: path, headings: parsed.headings, body: parsed.body))
            }
        }
        return WikiSearchIndex(entries: entries)
    }

    func search(_ query: String, scope: WikiSearchScope = .all, preferredProject: String? = nil) -> [WikiSearchHit] {
        let tokens = WikiSearchText.fold(query).split(whereSeparator: { $0.isWhitespace }).map { Array($0) }
        guard !tokens.isEmpty else { return [] }
        let joined = Array(tokens.map { String($0) }.joined(separator: " "))
        var hits: [WikiSearchHit] = []
        for entry in entries {
            if case .project(let name) = scope, entry.project != name { continue }
            if let hit = Self.match(entry, tokens: tokens, joined: joined) { hits.append(hit) }
        }
        func rank(_ h: WikiSearchHit) -> Int { h.entry.project == preferredProject ? 0 : 1 }
        return hits.sorted { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.kind != b.kind { return a.kind < b.kind }
            if a.entry.updated != b.entry.updated { return a.entry.updated > b.entry.updated }
            return a.entry.title < b.entry.title
        }
    }

    private static func all(_ tokens: [[Character]], in hay: [Character]) -> Bool {
        tokens.allSatisfy { WikiSearchText.firstMatch(of: $0, in: hay) != nil }
    }

    private static func match(_ e: WikiSearchEntry, tokens: [[Character]], joined: [Character]) -> WikiSearchHit? {
        func hit(_ kind: WikiMatchKind, original: String, folded: [Character]) -> WikiSearchHit {
            WikiSearchHit(entry: e, kind: kind, snippet: snippet(original: original, folded: folded, tokens: tokens))
        }
        let title = e.foldedTitle
        if title == joined { return hit(.exactTitle, original: e.oneLiner, folded: e.foldedOneLiner) }
        if title.starts(with: joined) { return hit(.titlePrefix, original: e.oneLiner, folded: e.foldedOneLiner) }
        if all(tokens, in: title) { return hit(.titleWord, original: e.oneLiner, folded: e.foldedOneLiner) }
        if all(tokens, in: e.foldedOneLiner) { return hit(.oneLiner, original: e.oneLiner, folded: e.foldedOneLiner) }
        if let i = e.foldedHeadings.firstIndex(where: { all(tokens, in: $0) }) {
            return hit(.heading, original: e.headings[i], folded: e.foldedHeadings[i])
        }
        if all(tokens, in: e.foldedBody) { return hit(.body, original: e.body, folded: e.foldedBody) }
        // Tokens spread over several fields still match the page as a whole.
        let fields = [title, e.foldedOneLiner, e.foldedBody] + e.foldedHeadings
        guard tokens.allSatisfy({ t in fields.contains { WikiSearchText.firstMatch(of: t, in: $0) != nil } }) else { return nil }
        return hit(.body, original: e.body, folded: e.foldedBody)
    }

    private static func snippet(original: String, folded: [Character], tokens: [[Character]]) -> WikiSnippet {
        let chars = Array(original)
        let found = tokens.compactMap { t in WikiSearchText.firstMatch(of: t, in: folded).map { ($0, t.count) } }.min { $0.0 < $1.0 }
        return window(chars, match: found.map { $0.0..<($0.0 + $0.1) })
    }

    static func snippet(in text: String, token: String, radius: Int = 60) -> WikiSnippet {
        let t = Array(WikiSearchText.fold(token))
        let found = WikiSearchText.firstMatch(of: t, in: WikiSearchText.foldedCharacters(text))
        return window(Array(text), match: found.map { $0..<($0 + t.count) }, radius: radius)
    }

    /// About `radius` characters each side of the match, on one line, with "…" where it was cut.
    private static func window(_ chars: [Character], match: Range<Int>?, radius: Int = 60) -> WikiSnippet {
        let centre = match ?? 0..<0
        let lo = max(0, centre.lowerBound - radius)
        let hi = min(chars.count, (match == nil ? radius * 2 : centre.upperBound + radius))
        var body = chars[lo..<hi].map { $0.isNewline || $0 == "\t" ? " " : $0 }
        var offset = 0
        if lo > 0 { body.insert("…", at: 0); offset = 1 }
        if hi < chars.count { body.append("…") }
        let highlight = match.map { ($0.lowerBound - lo + offset)..<($0.upperBound - lo + offset) }
        return WikiSnippet(text: String(body), highlight: highlight)
    }
}

struct WikiRecents {
    static let limit = 5
    private static let searchesKey = "bree.wiki.recentSearches"
    private static let pagesKey = "bree.wiki.recentPages"
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    struct Page: Equatable { var path: String; var title: String }

    var searches: [String] { defaults.stringArray(forKey: Self.searchesKey) ?? [] }

    var pages: [Page] {
        (defaults.array(forKey: Self.pagesKey) as? [[String: String]] ?? []).compactMap {
            guard let path = $0["path"], let title = $0["title"] else { return nil }
            return Page(path: path, title: title)
        }
    }

    /// Newest first, deduplicated by folded text, capped at `limit`. Blank queries are ignored.
    func addSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        let key = WikiSearchText.fold(q)
        let rest = searches.filter { WikiSearchText.fold($0) != key }
        defaults.set(Array(([q] + rest).prefix(Self.limit)), forKey: Self.searchesKey)
    }

    func clearSearches() { defaults.removeObject(forKey: Self.searchesKey) }

    func addPage(path: String, title: String) {
        let rest = pages.filter { $0.path != path }
        let all = ([Page(path: path, title: title)] + rest).prefix(Self.limit)
        defaults.set(all.map { ["path": $0.path, "title": $0.title] }, forKey: Self.pagesKey)
    }
}

enum WikiSearchEscape {
    enum Action: Equatable { case clearQuery, closeSearch }
    /// First Esc clears the field, the second closes search.
    static func action(query: String) -> Action { query.isEmpty ? .closeSearch : .clearQuery }
}

enum WikiSearchHighlight {
    /// Page script: scrolls to the first word that starts with the folded token and flashes it.
    /// The colour comes from the page's own text colour, so it follows the Bree palette.
    static func script(tokenJSONArray: String) -> String {
        """
        (function(tokens) {
          var t = tokens[0];
          if (!t) { return; }
          function fc(c) {
            if (c === '\u{130}' || c === '\u{131}' || c === 'I') { return 'i'; }
            var d = c.normalize('NFD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase();
            return d.length ? d.charAt(0) : c;
          }
          function fold(s) { var o = ''; for (var k = 0; k < s.length; k++) { o += fc(s.charAt(k)); } return o; }
          var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
          var node;
          while ((node = walker.nextNode())) {
            var f = fold(node.nodeValue), i = -1, from = 0;
            while ((i = f.indexOf(t, from)) >= 0) {
              if (i === 0 || !/[\\p{L}\\p{N}]/u.test(f.charAt(i - 1))) { break; }
              from = i + 1;
            }
            if (i < 0) { continue; }
            var range = document.createRange();
            range.setStart(node, i);
            range.setEnd(node, i + t.length);
            var mark = document.createElement('mark');
            mark.style.cssText = 'background:color-mix(in srgb,currentColor 25%,transparent);color:inherit;border-radius:3px;transition:background .8s';
            range.surroundContents(mark);
            mark.scrollIntoView({block: 'center'});
            setTimeout(function() { mark.style.background = 'transparent'; }, 1600);
            return;
          }
        })(\(tokenJSONArray));
        """
    }
}

/// One selectable row of the empty-query view: a recent page or a recent query.
enum WikiRecentRow: Equatable {
    case page(WikiRecents.Page)
    case search(String)
}

extension WikiRecents {
    /// Recent pages first, then recent searches: the order the empty-query view shows them.
    var rows: [WikiRecentRow] { pages.map(WikiRecentRow.page) + searches.map(WikiRecentRow.search) }
}

enum WikiSearchSelection {
    /// Moves a row selection by `delta`, clamped to the list. An empty list selects row 0.
    static func move(_ current: Int, by delta: Int, count: Int) -> Int {
        count > 0 ? min(max(current + delta, 0), count - 1) : 0
    }
}

enum WikiSearchState: Equatable {
    case recents, noRecentsHint, results, noMatches, noTopics

    static func resolve(query: String, resultCount: Int, recentCount: Int, indexIsEmpty: Bool) -> WikiSearchState {
        if indexIsEmpty { return .noTopics }
        if query.trimmingCharacters(in: .whitespaces).isEmpty { return recentCount > 0 ? .recents : .noRecentsHint }
        return resultCount > 0 ? .results : .noMatches
    }
}
