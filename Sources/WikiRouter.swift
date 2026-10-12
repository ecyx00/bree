import AppKit

/// Routes a click on an internal link of a wiki page (see `WikiLink`). The one place that turns
/// wiki links into Quick View / Architecture actions, used by the shared markdown renderer.
/// Which project index a concept page was opened from (a shared concepts folder in the global wiki has no index of its
/// own). In memory only, keyed by the symlink-resolved page path, so a pinned tab keeps working.
@MainActor
enum WikiOpeners {
    static var roots: [String: String] = [:]
    static func key(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
}

@MainActor
enum WikiRouter {
    /// What a routed link does, supplied by the surface the page is shown in (Quick View panel or the Wiki popover).
    struct Actions {
        let workspace: Workspace?
        /// Opens a code, doc or source file in Quick View.
        let openResource: (QuickViewResource) -> Void
        /// Shows another wiki page (`[[slug]]`) in the same surface.
        let openPage: (String) -> Void
        /// Shows a file in the same surface (the Wiki popover). nil: the surface only has Quick View.
        var pushFile: ((_ path: String, _ line: Int?) -> Void)? = nil
    }

    /// A click inside a wiki page shown by a Quick View markdown panel.
    static func route(href: String, pagePath: String, panelId: UUID, workspaceId: UUID) {
        let workspace = QuickViewWindowController.workspace(forPanelId: panelId)
            ?? AppDelegate.shared?.workspaceContainingPanel(panelId: panelId, preferredWorkspaceId: workspaceId)?.workspace
        route(href: href, pagePath: pagePath, actions: Actions(
            workspace: workspace,
            openResource: { resource in
                if QuickViewWindowController.open(resource, fromPanelId: panelId) { return }
                if let workspace { resource.open(from: workspace) }
            },
            openPage: { path in
                if QuickViewWindowController.open(.file(path: path), fromPanelId: panelId) { return }
                if let workspace { QuickViewResource.file(path: path).open(from: workspace) }
            }
        ))
    }

    static func route(href: String, pagePath: String, actions: Actions, quickView: Bool = false,
                      wikiDir: String? = nil) {
        guard let link = WikiLink.parse(href) else { return }
        // The wiki folder the page lives in: a repo-local `.bree/wiki`, else the global folder.
        let wikiDir = wikiDir ?? WikiPaths.wikiRoot(containing: pagePath)
        let config = WikiConfig.forPage(pagePath)
        let dir = (pagePath as NSString).deletingLastPathComponent
        let workspace = actions.workspace
        // A click stays in the popover and pushes a file page; ⌘-click (or a surface without pages) uses Quick View.
        let open: (QuickViewResource) -> Void = { resource in
            if case .file(let path, _, _) = resource, WikiPaths.isBlockedSource(path, wikiDir: wikiDir) { return }
            if !quickView, let push = actions.pushFile, case .file(let path, let line, _) = resource {
                push(path, line)
            } else {
                actions.openResource(resource)
            }
        }
        // Code root: the page's front matter first, then the index the page was opened from.
        let opener = projectRoot(wikiDir: dir) ?? WikiOpeners.roots[WikiOpeners.key(pagePath)]
        let text = (try? String(contentsOfFile: pagePath, encoding: .utf8)) ?? ""
        let context = WikiPageContext.parse(markdown: text)
        let root = context.codeRoot(project: nil, openerRoot: opener)
        func openCode(root: String?, path: String, line: Int?, symbol: String?) {
            guard let root else { return showNoRoot(path) }
            let top = (root as NSString).appendingPathComponent(path)
            guard let symbol else { return open(.file(path: top, line: line)) }
            // The wiki's declared symbol command (if any, and approved) first; its failure falls back to a file scan.
            let argv = config.symbolArguments(symbol: symbol).flatMap {
                WikiTrust.authorize(config: config, argv: config.symbolCommand ?? $0) ? $0 : nil
            }
            Task {
                var found: Int?
                if let argv { found = await SymbolCommand.line(argv: argv, root: root, relativePath: path) }
                // No command, no hit, tool missing or slow: read the file itself for the definition.
                if found == nil { found = SymbolLine.find(symbol, inFileAt: top) }
                open(.file(path: top, line: found))
            }
        }
        switch link {
        case .page(let slug):
            guard let target = WikiPaths.resolveSlug(slug, pageDir: dir) else { return }
            if let opener { WikiOpeners.roots[WikiOpeners.key(target)] = opener }
            actions.openPage(target)
        case .code(let path, let line):
            openCode(root: root, path: path, line: line, symbol: nil)
        case .codeSymbol(let path, let symbol):
            openCode(root: root, path: path, line: nil, symbol: symbol)
        case .qualifiedCode(let project, let path, let line, let symbol):
            // An unknown @project stays inert: never guess a root.
            guard let qRoot = context.codeRoot(project: project, openerRoot: opener) else { return }
            openCode(root: qRoot, path: path, line: line, symbol: symbol)
        case .source(let slug, let path, let line):
            // The snapshot shows as plain text (QuickViewResource never renders snap files).
            guard let file = WikiPaths.snapFile(slug: slug, relpath: path, wikiDir: wikiDir) else { return }
            open(.file(path: file, line: line))
        case .sourceWeb(_, let path, let line):
            // Rebuilt from the page front matter (url + sha); the href itself is never trusted. No fetch by the app.
            if let url = context.githubURL(relpath: path, line: line) { NSWorkspace.shared.open(url) }
        case .board:
            // Flow boards do not exist yet: show the boards view of the Architecture popup.
            if let workspace { ArchitectureWindowController.shared.openBoards(from: workspace) }
        case .chip(let kind, let value):
            // Only doc and capture-card chips open here; declared chips (m, ...) and commit open as pages of the Wiki popover (`WikiPopoverModel.route`), nowhere else,
            // genel and broken stay plain.
            if kind == "yakala" {
                // A capture card: only `_kaynaklar/yakala/<id>.md`, resolved inside that folder.
                guard let card = WikiPaths.yakalaCard(id: value, wikiDir: wikiDir) else { return }
                return open(.file(path: card))
            }
            guard kind == "doc", let path = WikiChip.docPath(value: value, root: root) else { return }
            open(.file(path: path))
        }
    }

    /// The code root of a wiki page, as `route` resolves it (front matter first, then the opener).
    static func codeRoot(pagePath: String) -> String? {
        let dir = (pagePath as NSString).deletingLastPathComponent
        let opener = projectRoot(wikiDir: dir) ?? WikiOpeners.roots[WikiOpeners.key(pagePath)]
        let text = (try? String(contentsOfFile: pagePath, encoding: .utf8)) ?? ""
        return WikiPageContext.parse(markdown: text).codeRoot(project: nil, openerRoot: opener)
    }

    private static func showNoRoot(_ path: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "architecture.wiki.noRoot.title", defaultValue: "No project for this page")
        alert.informativeText = String(
            format: String(localized: "architecture.wiki.noRoot.message",
                           defaultValue: "Open it from a project's Wiki tab to resolve code links.\n%@"),
            path)
        alert.runModal()
    }

    private static func projectRoot(wikiDir: String) -> String? {
        guard let data = FileManager.default.contents(atPath: (wikiDir as NSString).appendingPathComponent("index.json")),
              let index = try? WikiIndex.decode(data) else { return nil }
        return index.root
    }
}

/// The line of a symbol's definition found by reading the file: the fallback when `my-index def` gives nothing.
enum SymbolLine {
    private static let keywords = "def|class|func|function|fn|struct|enum|protocol|interface|trait|impl|type|const|let|var|static|actor|extension|module|object"

    /// 1-based line of the first definition of `symbol` in `text`, nil when there is none.
    /// A definition is a declaration keyword (after optional modifiers) followed by the whole symbol name.
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

/// The wiki's `symbolCommand` (e.g. `my-index def {symbol}`, cwd = project root). Its output is read as rows that
/// start with `<relpath>:<line>`; any failure returns nil and the caller scans the file instead.
enum SymbolCommand {
    /// Prefers the hit inside `relativePath`, else the first hit; nil on any failure.
    static func line(argv: [String], root: String, relativePath: String) async -> Int? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: run(argv: argv, root: root, relativePath: relativePath))
            }
        }
    }

    static func parse(output: String, relativePath: String) -> Int? {
        let hits: [(path: String, line: Int)] = output.split(separator: "\n").compactMap { row in
            guard let token = row.split(separator: " ").first,
                  let colon = token.lastIndex(of: ":"),
                  let n = Int(token[token.index(after: colon)...]) else { return nil }
            return (String(token[..<colon]), n)
        }
        return (hits.first { $0.path == relativePath } ?? hits.first)?.line
    }

    private static func run(argv: [String], root: String, relativePath: String) -> Int? {
        guard let tool = argv.first, let exe = WikiToolLookup.executable(for: tool) else { return nil }
        let command = WikiChip.Command(tool: tool, arguments: Array(argv.dropFirst()), directory: root)
        guard let text = WikiPreview.run(command, executable: exe, cap: false) else { return nil }
        return parse(output: text, relativePath: relativePath)
    }
}

/// Runs the argv of a chip preview off the main thread: no shell, 8 s kill, output capped for the card.
enum WikiPreview {
    static let maxCharacters = 4000

    static func text(for command: WikiChip.Command) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: run(command)) }
        }
    }

    private static func run(_ command: WikiChip.Command) -> String? {
        guard let exe = WikiToolLookup.executable(for: command.tool) else { return nil }
        return run(command, executable: exe, cap: true)
    }

    /// stdout of the command (argv only, no shell, 8 s kill); nil when it fails. `cap`: cut for a card.
    static func run(_ command: WikiChip.Command, executable exe: String, cap: Bool) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = command.arguments
        if let directory = command.directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return cap && text.count > maxCharacters ? String(text.prefix(maxCharacters)) + "\n…" : text
    }
}
