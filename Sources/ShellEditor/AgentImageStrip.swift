import AppKit
import CmuxFoundation
import CmuxTerminal
import GhosttyKit
import ImageIO
import SwiftUI

/// One image Claude saved for a session (`.../<session_id>/images/<N>.png`).
struct AgentImageEntry: Equatable, Sendable, Identifiable {
    let url: URL
    /// The numeric file stem (`Image #N`), nil for non-numeric names.
    let number: Int?
    let modified: Date

    var id: String { url.path }
    private var label: String { number.map(String.init) ?? url.deletingPathExtension().lastPathComponent }
    var title: String {
        String(format: String(localized: "agentImageStrip.title", defaultValue: "Image #%@"), label)
    }
    var accessibilityTitle: String {
        String(format: String(localized: "agentImageStrip.accessibility", defaultValue: "Image %@"), label)
    }
}

enum AgentImageDiscovery {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp"]

    static func defaultRoot() -> URL {
        URL(fileURLWithPath: "/private/tmp/claude-\(getuid())", isDirectory: true)
    }

    /// Lists `<root>/*/<sessionID>/images/*`, keeps image extensions, sorts by the numeric stem
    /// (non-numeric names last, by name). Blocking file I/O: call off the main thread.
    static func discover(root: URL = defaultRoot(), sessionID: String) -> [AgentImageEntry] {
        guard !sessionID.isEmpty, !sessionID.contains("/") else { return [] }
        let fm = FileManager.default
        let projects = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var entries: [AgentImageEntry] = []
        for project in projects {
            let dir = project.appendingPathComponent(sessionID, isDirectory: true)
                .appendingPathComponent("images", isDirectory: true)
            let files = (try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            for file in files where imageExtensions.contains(file.pathExtension.lowercased()) {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                entries.append(AgentImageEntry(
                    url: file,
                    number: Int(file.deletingPathExtension().lastPathComponent),
                    modified: modified
                ))
            }
        }
        return sorted(entries)
    }

    static func sorted(_ entries: [AgentImageEntry]) -> [AgentImageEntry] {
        entries.sorted { a, b in
            switch (a.number, b.number) {
            case let (x?, y?): return x != y ? x < y : a.url.path < b.url.path
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.url.lastPathComponent < b.url.lastPathComponent
            }
        }
    }
}

private enum AgentThumbnailCache {
    static let cache = NSCache<NSString, NSImage>()
    static let displayHeight: CGFloat = 36
    static let maxWidth: CGFloat = 64

    /// Downsampled thumbnail keyed by path + modification date. Blocking: call off the main thread.
    static func thumbnail(for entry: AgentImageEntry) -> NSImage? {
        let key = "\(entry.url.path)|\(entry.modified.timeIntervalSince1970)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let source = CGImageSourceCreateWithURL(entry.url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(displayHeight * 2 * 2),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width / 2, height: cg.height / 2))
        cache.setObject(image, forKey: key)
        return image
    }
}

/// Images the user hid with the thumbnail's remove button, this app run only.
/// Claude's files are never deleted.
@MainActor
final class AgentImageDismissals: ObservableObject {
    static let shared = AgentImageDismissals()
    @Published var paths: Set<String> = []
}

/// State of one pane's strip, driven by `AgentImageStripOverlayView`.
@MainActor
final class AgentImageStripModel: ObservableObject {
    @Published var images: [AgentImageEntry] = []
    var onOpen: (AgentImageEntry, CGRect) -> Void = { _, _ in }
    var onRemove: (AgentImageEntry) -> Void = { _ in }
}

/// Thumbnails drawn on an opaque chip that hugs them; it floats above Claude's input box.
struct AgentImageStripContent: View {
    @ObservedObject var model: AgentImageStripModel
    @ObservedObject private var dismissals = AgentImageDismissals.shared
    @Environment(\.breePalette) private var palette

    private var visible: [AgentImageEntry] { model.images.filter { !dismissals.paths.contains($0.id) } }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(visible) { entry in
                AgentImageThumbnail(entry: entry, onOpen: { model.onOpen(entry, $0) }, onRemove: { model.onRemove(entry) })
            }
        }
        .padding(4)
        .coordinateSpace(name: AgentImageStripSpace.name)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(palette.surfaceRaised))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(palette.separator, lineWidth: 1))
        .fixedSize()
    }
}

/// Window-level overlay inside the terminal pane (the terminal is an AppKit portal layer, so
/// SwiftUI siblings would sit under it). Never resizes the terminal. It shows only while Claude's
/// input box top rule is found in the live viewport (Claude Code fullscreen runs on the alternate
/// screen, so that is not excluded; the rule + prompt pattern is the Claude detector), and sits 4 pt above that rule.
@MainActor
final class AgentImageStripOverlayView: NSView {
    private let model = AgentImageStripModel()
    private let host: NSHostingView<AnyView>
    private weak var surfaceView: NSView?
    private var surfaceProvider: () -> TerminalSurface? = { nil }
    private var ruleRow: Int?
    private var popover: NSPopover?
    private var loop: Task<Void, Never>?
    private var lastRefresh = Date.distantPast
    private static let gap: CGFloat = 4

    init(surfaceView: NSView, surface: @escaping () -> TerminalSurface?) {
        self.surfaceView = surfaceView
        self.surfaceProvider = surface
        host = NSHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        host.rootView = AnyView(
            AgentImageStripContent(model: model).breePaletteEnvironment().cmuxAccentColorEnvironment()
        )
        host.appearance = NSAppearance(named: .darkAqua)
        host.isHidden = true
        addSubview(host)
        model.onOpen = { [weak self] entry, rect in self?.openPreview(entry, from: rect) }
        model.onRemove = { [weak self] entry in
            AgentImageDismissals.shared.paths.insert(entry.id)
            guard let number = entry.number, let surface = self?.surfaceProvider() else { return }
            Task { await AgentImageTokenRemover.remove(number: number, from: surface) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !host.isHidden else { return nil }
        if NSApp.currentEvent?.type == .scrollWheel { return nil }
        guard host.frame.contains(convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        loop?.cancel()
        guard window != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    override func layout() {
        super.layout()
        placeStrip()
    }

    /// Cheap content-change hook (scrollbar packets); throttled, a no-op without images.
    func contentDidChange() {
        guard !host.isHidden, Date().timeIntervalSince(lastRefresh) > 0.25 else { return }
        refreshPlacement()
    }

    /// Native NSPopover (a SwiftUI popover does not present from this AppKit overlay). Opens below
    /// the thumbnail; the anchor is nudged right so it never reaches over the sidebar.
    private func openPreview(_ entry: AgentImageEntry, from rect: CGRect) {
        popover?.close()
        let width = min(480, max(160, bounds.width / 2))
        let p = NSPopover()
        p.behavior = .transient
        let controller = EscapableHostingController(
            rootView: AgentImagePreview(entry: entry, maxWidth: width).breePaletteEnvironment()
        )
        controller.onEscape = { [weak p] in p?.close() }
        p.contentViewController = controller
        let paneLeft = host.convert(NSPoint(x: bounds.minX, y: 0), from: self).x
        let centerX = max(rect.midX, paneLeft + (width + 16) / 2 + 4)
        // Attach to this full-pane view, not the small hosting view: NSPopover refuses to present
        // from an anchor outside the bounds of a view that only hugs the thumbnails.
        let anchor = convert(NSRect(x: centerX - 1, y: rect.minY, width: 2, height: rect.height), from: host)
        popover = p
        DispatchQueue.main.async { [weak self, weak p] in
            guard let self, let p else { return }
            p.show(relativeTo: anchor, of: self, preferredEdge: self.isFlipped ? .maxY : .minY)
            // Take key focus so Esc reaches the controller (a transient popover does not by default).
            p.contentViewController?.view.window?.makeKey()
            p.contentViewController?.view.window?.makeFirstResponder(p.contentViewController?.view)
            #if DEBUG
            cmuxDebugLog("agentImageStrip.popover anchor=\(anchor) shown=\(p.isShown) flipped=\(self.isFlipped)")
            #endif
        }
    }

    private func tick() async {
        guard let surface = surfaceProvider(), AgentImageStripContext.isEligible(surface),
              let sessionID = AgentImageStripContext.sessionID(for: surface.id) else { return setImages([]) }
        let found = await Task.detached(priority: .utility) {
            AgentImageDiscovery.discover(sessionID: sessionID)
        }.value
        setImages(found)
        refreshPlacement()
    }

    private func setImages(_ found: [AgentImageEntry]) {
        if found != model.images { model.images = found }
        if found.isEmpty { ruleRow = nil; placeStrip() }
    }

    private func refreshPlacement() {
        lastRefresh = Date()
        let dismissed = AgentImageDismissals.shared.paths
        guard model.images.contains(where: { !dismissed.contains($0.id) }),
              let surface = surfaceProvider(),
              surface.liveInputCursor() != nil,   // live bottom only (not scrolled back)
              let grid = surface.gridMetrics(),
              let text = surface.readText(region: .viewport) else {
            ruleRow = nil; return placeStrip()
        }
        ruleRow = AgentImageStripPlacement.inputRuleRow(viewport: text, columns: grid.columns)
        placeStrip()
    }

    private func placeStrip() {
        guard let row = ruleRow, let surfaceView, let grid = surfaceProvider()?.gridMetrics() else {
            host.isHidden = true; return
        }
        let size = host.fittingSize
        // Grid is top-left origin; AppKit y is up. Vertical middle of the rule row (where the line is drawn):
        let ruleTopUp = surfaceView.bounds.height - (grid.paddingTop + (CGFloat(row) + 0.5) * grid.cellHeight)
        let origin = convert(NSPoint(x: grid.paddingLeft, y: ruleTopUp), from: surfaceView)
        host.frame = NSRect(x: origin.x + 8, y: origin.y + Self.gap, width: size.width, height: size.height)
        host.isHidden = size.width < 1
    }
}

/// Closes its popover on Esc.
private final class EscapableHostingController<Content: View>: NSHostingController<Content> {
    var onEscape: () -> Void = {}
    override func cancelOperation(_ sender: Any?) { onEscape() }
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(view)
    }
}

enum AgentImageStripContext {
    @MainActor
    static func panel(for surface: TerminalSurface) -> TerminalPanel? {
        let workspace = AppDelegate.shared?.tabManagerFor(tabId: surface.tabId)?.tabs.first { $0.id == surface.tabId }
        return workspace?.panels[surface.id] as? TerminalPanel
    }

    /// Today's conditions: shell editor setting on, no text box, no shell editor dock.
    @MainActor
    static func isEligible(_ surface: TerminalSurface) -> Bool {
        let enabled = UserDefaults.standard.object(forKey: "terminal.shellEditor") as? Bool ?? true
        guard enabled, let panel = panel(for: surface) else { return false }
        return !panel.isTextBoxActive && !panel.shellEditorActive
    }

    @MainActor
    static func sessionID(for surfaceID: UUID) -> String? {
        AgentLensStore.shared.cards.filter { $0.surfaceID == surfaceID && $0.claudeSessionID != nil }
            .max { $0.lastEventAt < $1.lastEventAt }?.claudeSessionID
    }
}

enum AgentImageStripPlacement {
    /// Viewport row of the top rule of Claude's input box: a full-width `─` line directly
    /// followed by a line starting with `❯`, searched from the bottom. nil = not Claude's input.
    static func inputRuleRow(viewport: String, columns: Int) -> Int? {
        let lines = viewport.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return nil }
        for i in stride(from: lines.count - 2, through: 0, by: -1) {
            let rule = lines[i].trimmingCharacters(in: .whitespaces)
            if rule.count >= max(20, columns - 2), rule.allSatisfy({ $0 == "─" }), lines[i + 1].hasPrefix("❯") {
                return i
            }
        }
        return nil
    }
}

private enum AgentImageStripSpace { static let name = "agentImageStrip" }

private struct AgentImageThumbnail: View {
    let entry: AgentImageEntry
    let onOpen: (CGRect) -> Void
    let onRemove: () -> Void
    @State private var image: NSImage?
    @State private var hovering = false
    @State private var frame: CGRect = .zero
    @Environment(\.breePalette) private var palette
    @Environment(\.cmuxAccentColor) private var cmuxAccent

    private static let removeLabel = String(localized: "agentImageStrip.remove", defaultValue: "Remove Image")

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button { onOpen(frame) } label: {
                Group {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(palette.hoverFill)
                    }
                }
                .frame(maxWidth: AgentThumbnailCache.maxWidth)
                .frame(height: AgentThumbnailCache.displayHeight)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovering ? cmuxAccent.selectedFillColor.opacity(0.18) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(hovering ? palette.borderStrong : palette.separator, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(palette.accentFill)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.78)))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Self.removeLabel)
            }
        }
        .onHover { hovering = $0 }
        .help(entry.title)
        .accessibilityLabel(entry.accessibilityTitle)
        .accessibilityAction(named: Text(Self.removeLabel), onRemove)
        .background(GeometryReader { geo in
            Color.clear.onChange(of: geo.frame(in: .named(AgentImageStripSpace.name)), initial: true) { _, new in frame = new }
        })
        .task(id: entry.id + "\(entry.modified.timeIntervalSince1970)") {
            let entry = entry
            image = await Task.detached(priority: .utility) { AgentThumbnailCache.thumbnail(for: entry) }.value
        }
    }
}

private struct AgentImagePreview: View {
    let entry: AgentImageEntry
    let maxWidth: CGFloat
    @State private var image: NSImage?
    @Environment(\.breePalette) private var palette

    var body: some View {
        let height = min(360, maxWidth * 0.75)
        VStack(spacing: 8) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: maxWidth, height: height)
            HStack {
                Text(entry.title).font(.system(size: 12, weight: .medium)).foregroundStyle(palette.textPrimary)
                Spacer()
                Button(String(localized: "agentImageStrip.openInPreview", defaultValue: "Open in Preview")) {
                    NSWorkspace.shared.open(entry.url)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(palette.textSecondary)
            }
        }
        .padding(8)
        .background(palette.surfaceOverlay)
        .task {
            let url = entry.url
            image = await Task.detached(priority: .userInitiated) { NSImage(contentsOf: url) }.value
        }
    }
}

/// Pure logic for deleting one `[Image #N]` token from Claude's unsent input.
/// Invariant: a backspace is only approved while the text before the cursor is
/// exactly `head + a non-empty prefix of the token`, so no other input is touched.
enum AgentImageTokenRemoval {
    struct Plan: Equatable {
        /// Row text left of the token.
        let head: String
        let token: String
        /// Cursor moves that put the cursor right after the token (+ right, - left).
        let horizontalMoves: Int
    }

    static func token(number: Int) -> String { "[Image #\(number)]" }

    /// Locates the token on the cursor's row. nil means "not certain": send no keys.
    static func plan(viewport: String, cursorRow: Int, cursorColumn: Int, number: Int) -> Plan? {
        let lines = viewport.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard cursorRow >= 0, cursorRow < lines.count, cursorColumn >= 0 else { return nil }
        let row = Array(lines[cursorRow])
        guard !row.contains(where: isWideOrUnsafe) else { return nil }
        let token = Array(token(number: number))
        let starts = row.indices.filter { $0 + token.count <= row.count && Array(row[$0..<($0 + token.count)]) == token }
        guard starts.count == 1, let start = starts.first else { return nil }
        return Plan(head: String(row[0..<start]), token: String(token), horizontalMoves: start + token.count - cursorColumn)
    }

    /// True when exactly `head + token.prefix(k)` (k >= 1) sits left of the cursor.
    static func shouldBackspace(rowText: String, cursorColumn: Int, plan: Plan) -> Bool {
        let row = Array(rowText)
        guard cursorColumn > 0, cursorColumn <= row.count, !row.contains(where: isWideOrUnsafe) else { return false }
        let before = String(row[0..<cursorColumn])
        let headCount = plan.head.count
        guard before.count > headCount, before.count <= headCount + plan.token.count else { return false }
        return before == plan.head + plan.token.prefix(before.count - headCount)
    }

    /// Cells must equal characters, so reject wide, emoji and combining text.
    private static func isWideOrUnsafe(_ c: Character) -> Bool {
        c.unicodeScalars.count > 1 || c.unicodeScalars.contains { s in
            switch s.value {
            case 0x1100...0x115F, 0x2E80...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF,
                 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x1F000...0x1FAFF, 0x20000...: return true
            default: return false
            }
        }
    }
}

extension TerminalSurface {
    /// Cursor cell in the viewport while the viewport shows the live bottom, else nil.
    @MainActor
    func liveInputCursor() -> (row: Int, column: Int)? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "agentImageStrip.cursor") else { return nil }
        var metrics = ghostty_surface_grid_metrics_s()
        var scrollbar = ghostty_surface_scrollbar_s()
        guard ghostty_surface_grid_metrics(surface, &metrics), ghostty_surface_scrollbar(surface, &scrollbar),
              metrics.cursor_in_viewport, metrics.cursor_width_cells == 1,
              scrollbar.offset + scrollbar.len >= scrollbar.total else { return nil }
        return (Int(metrics.cursor_row), Int(metrics.cursor_column))
    }
}

extension TerminalSurface {
    @MainActor
    func gridMetrics() -> (columns: Int, cellHeight: CGFloat, paddingTop: CGFloat, paddingLeft: CGFloat)? {
        guard let surface = liveSurfaceForGhosttyAccess(reason: "agentImageStrip.grid") else { return nil }
        var m = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &m), m.cell_height.isFinite, m.cell_height > 0 else { return nil }
        return (Int(m.columns), CGFloat(m.cell_height), CGFloat(m.padding_top), CGFloat(m.padding_left))
    }
}

enum AgentImageTokenRemover {
    /// Best effort. Any doubt (remote, tmux, scrolled, token not on the cursor row) sends no keys.
    @MainActor
    static func remove(number: Int, from surface: TerminalSurface) async {
        guard let workspace = AppDelegate.shared?.tabManagerFor(tabId: surface.tabId)?
                  .tabs.first(where: { $0.id == surface.tabId }),
              !workspace.isRemoteTerminalSurface(surface.id),
              (workspace.panels[surface.id] as? TerminalPanel)?.tmuxLayoutReport == nil else { return }
        func snapshot() -> (text: String, row: Int, col: Int)? {
            guard let cursor = surface.liveInputCursor(), let text = surface.readText(region: .viewport) else { return nil }
            return (text, cursor.row, cursor.column)
        }
        guard let first = snapshot(),
              let plan = AgentImageTokenRemoval.plan(
                  viewport: first.text, cursorRow: first.row, cursorColumn: first.col, number: number
              ) else { return }
        for _ in 0..<abs(plan.horizontalMoves) {
            guard surface.sendNamedKey(plan.horizontalMoves > 0 ? "right" : "left").accepted else { return }
        }
        // One backspace at a time: Claude may delete the pill whole or per character.
        let endColumn = plan.head.count + plan.token.count
        for _ in 0...plan.token.count {
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard let now = snapshot() else { return }
            let lines = now.text.split(separator: "\n", omittingEmptySubsequences: false)
            guard now.row < lines.count, now.col <= endColumn else { return }
            guard AgentImageTokenRemoval.shouldBackspace(rowText: String(lines[now.row]), cursorColumn: now.col, plan: plan) else { return }
            guard surface.sendNamedKey("backspace").accepted else { return }
        }
    }
}
