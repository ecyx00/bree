import AppKit
import BreeFoundation
import BreeTerminalCore
import GhosttyKit
import SwiftUI

/// Debug-only trace to /tmp/bree-debug-<tag>.log. Lengths only, never text.
@inline(__always)
private func completionLog(_ message: @autoclosure () -> String) {
#if DEBUG
    breeDebugLog(message())
#endif
}

/// Warp-style Tab completion for one terminal surface: a popup under the
/// cursor with commands, paths, git refs and history, gated by OSC 133 prompt
/// state so it never fires in full-screen apps, running commands, ssh or
/// nested shells. The terminal core and the shell are untouched; accepted
/// candidates are typed into the PTY as Backspace x N plus the escaped text.
@MainActor
final class TerminalCompletionController {
    private enum QueryMode {
        /// A Tab press; falls back to the shell's own completion when empty.
        case tab
        /// Re-filter after typing; closes when nothing matches.
        case refilter
        /// Reopen after accepting a directory, for the next path segment.
        case afterAccept
    }

    private static let defaultsKey = "terminal.completionPopup"
    private static let debounce: Duration = .milliseconds(100)
    private static let maxVisibleRows = 10

    private weak var view: GhosttyNSView?
    private let model = TerminalCompletionPopupModel()
    private var context: TerminalCompletionContext?
    private var generation: UInt64 = 0
    private var queryTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?
    private var pendingTab = false
    private var panel: TerminalCompletionPanel?
    private var host: NSHostingView<TerminalCompletionPopupView>?
    private var observers: [NSObjectProtocol] = []
    private var watchdog: Timer?
    private var anchorRowTop: CGFloat = 0

    private(set) var isOpen = false

    init(view: GhosttyNSView) {
        self.view = view
        model.onSelect = { [weak self] index in
            self?.model.selection = index
            self?.acceptSelection()
        }
    }

    private var isEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true
    }

    // MARK: Key routing

    /// Early keyDown hook. Returns true when the key was consumed.
    func handleKeyDown(_ event: NSEvent) -> Bool {
        // A key arriving while a Tab query is in flight: let the shell have
        // its Tab first so the order of keystrokes is preserved.
        completionLog("completion.key code=\(event.keyCode) open=\(isOpen) pendingTab=\(pendingTab) panelVisible=\(panel?.isVisible ?? false) candidates=\(model.candidates.count)")
        if pendingTab { cancelPendingTabAndSendIt() }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        if isOpen {
            switch (event.keyCode, flags) {
            case (126, []): moveSelection(by: -1); return true  // up
            case (125, []): moveSelection(by: 1); return true  // down
            case (48, []): moveSelection(by: 1); return true  // tab
            case (48, [.shift]): moveSelection(by: -1); return true
            case (36, []), (76, []): acceptSelection(); return true  // return, enter
            case (124, []): acceptSelection(); return true  // right arrow
            case (53, []): dismiss(); return true  // escape
            default:
                if Self.refiltersCompletion(event: event, flags: flags) {
                    scheduleQuery(.refilter)
                } else {
                    dismiss()
                }
                return false
            }
        }

        guard event.keyCode == 48, flags.isEmpty else { return false }
        let enabled = isEnabled
        let surface = view?.terminalCompletionSurface
        let cell = view?.terminalCompletionCursorCell()
        let ready = view?.terminalCompletionPanelID.map { TerminalCompletionShellBridge.shared.isReady(panel: $0) } ?? false
        completionLog("completion.tab open=\(isOpen) enabled=\(enabled) surface=\(surface != nil) cell=\(cell != nil) ready=\(ready)")
        guard enabled, let view, surface != nil, cell != nil else {
            if let failure = view?.terminalCompletionGateFailure { completionLog("completion.gate fail=\(failure)") }
            return false
        }
        pendingTab = true
        runQuery(.tab)
        return true
    }

    /// Printable keys and Backspace change the word without leaving it.
    private static func refiltersCompletion(event: NSEvent, flags: NSEvent.ModifierFlags) -> Bool {
        guard flags.isEmpty || flags == [.shift] else { return false }
        if event.keyCode == 51 { return true }  // Backspace
        guard let text = event.characters, let scalar = text.unicodeScalars.first else { return false }
        // Space ends the word: dismiss instead of listing the next argument.
        return scalar.value > 0x20 && scalar.value != 0x7F && !(0xF700...0xF8FF).contains(scalar.value)
    }

    private func cancelPendingTabAndSendIt() {
        pendingTab = false
        generation &+= 1
        queryTask?.cancel()
        view?.terminalCompletionSendTab()
    }

    // MARK: Query

    private func scheduleQuery(_ mode: QueryMode) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            self?.runQuery(mode)
        }
    }

    /// The input line the completion works on, and where it came from.
    private struct InputLine {
        var text: String
        var caret: Int
        var cwd: String?
    }

    /// The shell's own buffer when its integration reported the completion
    /// widget (exact, fresh `$PWD`), else Ghostty's OSC 133 reading of the grid.
    private func acquireInput(view: GhosttyNSView, surface: ghostty_surface_t) async -> InputLine? {
        if let panel = view.terminalCompletionPanelID, TerminalCompletionShellBridge.shared.isReady(panel: panel),
           let report = await TerminalCompletionShellBridge.shared.request(
               panel: panel,
               send: { view.terminalCompletionSendRaw($0) }
           ) {
            completionLog("completion.input src=shell len=\(report.text.count) caret=\(report.caret)")
            return InputLine(text: report.text, caret: report.caret, cwd: report.cwd)
        }
        guard !Task.isCancelled else { return nil }
        if let input = TerminalPromptInput.text(surface: surface) {
            completionLog("completion.input src=promptInput len=\(input.text.count) caret=\(input.caret)")
            return InputLine(text: input.text, caret: input.caret, cwd: nil)
        }
        completionLog("completion.input src=none len=0 caret=0")
        return nil
    }

    private func runQuery(_ mode: QueryMode) {
        queryTask?.cancel()
        generation &+= 1
        let token = generation
        guard isEnabled, let view,
              let surface = view.terminalCompletionSurface else {
            finish(mode, found: [], context: nil, reason: "noInput")
            return
        }
        queryTask = Task { [weak self] in
            guard let self else { return }
            let input = await self.acquireInput(view: view, surface: surface)
            guard !Task.isCancelled, self.generation == token else { return }
            guard let input else {
                self.finish(mode, found: [], context: nil, reason: "noInput")
                return
            }
            let context = TerminalCompletionContext.parse(buffer: input.text, caret: input.caret)
            let cwd: String
            if let reported = input.cwd, !reported.isEmpty {
                cwd = reported
                completionLog("completion.cwd src=shell")
            } else if let fromView = view.terminalCompletionWorkingDirectory {
                cwd = fromView
                completionLog("completion.cwd src=view")
            } else {
                cwd = NSHomeDirectory()
                completionLog("completion.cwd src=home")
            }
            let worker = Task.detached(priority: .userInitiated) {
                await TerminalCompletionProviders.candidates(
                    for: context,
                    cwd: cwd,
                    isCancelled: { Task.isCancelled }
                )
            }
            let found = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard !Task.isCancelled, self.generation == token else { return }
            self.finish(mode, found: found, context: context, reason: nil)
        }
    }

    private func finish(
        _ mode: QueryMode,
        found: [TerminalCompletionCandidate],
        context: TerminalCompletionContext?,
        reason: String?
    ) {
        let isTab = pendingTab && mode == .tab
        if isTab { pendingTab = false }
        // Typing never opens a list for an empty word; only Tab and a
        // directory accept do.
        let emptyWordRefilter = mode == .refilter && context?.word.isEmpty == true
        let single = found.count == 1 && found[0].kind != .history && found[0].insertion == context?.word
        let nothingToComplete = found.isEmpty || emptyWordRefilter || single
        guard let context, !nothingToComplete else {
            let why = reason ?? (found.isEmpty ? "empty" : "single")
            completionLog("completion.finish found=\(found.count) reason=\(why)")
            dismiss()
            // Native shell completion keeps working when we have nothing.
            if isTab { view?.terminalCompletionSendTab() }
            return
        }
        completionLog("completion.finish found=\(found.count) reason=shown mode=\(mode) wordLen=\(context.word.count) rawLen=\(context.rawWord.count) slashes=\(context.word.filter { $0 == "/" }.count)")
        self.context = context
        model.candidates = found
        model.selection = 0
        model.query = context.word.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? context.word
        present(wordColumns: context.rawWord.count)
    }

    // MARK: Accept

    private func moveSelection(by delta: Int) {
        let count = model.candidates.count
        guard count > 0 else { return }
        model.selection = (model.selection + delta + count) % count
    }

    private func acceptSelection() {
        guard isOpen, let context, model.candidates.indices.contains(model.selection) else {
            completionLog("completion.accept ignored open=\(isOpen) ctx=\(self.context != nil) sel=\(model.selection) n=\(model.candidates.count)")
            return
        }
        let candidate = model.candidates[model.selection]
        let deleteCount: Int
        let text: String
        if candidate.kind == .history {
            deleteCount = context.linePrefix.count
            text = candidate.insertion
        } else {
            // An open quote is replaced together with the word and the text
            // re-escaped unquoted, which is a valid shell word either way.
            deleteCount = context.rawWord.count
            text = candidate.replacementText
        }
        completionLog("completion.accept kind=\(candidate.kind) dir=\(candidate.isDirectory) space=\(candidate.appendsSpace) textLen=\(text.count)")
        dismiss()
        view?.terminalCompletionApply(deleteCount: deleteCount, text: text)
        if candidate.isDirectory { scheduleQuery(.afterAccept) }
    }

    // MARK: Popup

    func dismiss() {
        pendingTab = false
        generation &+= 1
        queryTask?.cancel()
        debounceTask?.cancel()
        isOpen = false
        watchdog?.invalidate()
        watchdog = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        completionLog("completion.dismiss")
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
    }

    private func present(wordColumns: Int) {
        guard let view, let window = view.window, window.isKeyWindow,
              let cell = view.terminalCompletionCursorCell() else {
            completionLog("completion.present key=\(view?.window?.isKeyWindow ?? false) frame=none")
            dismiss()
            return
        }
        let rows = min(model.candidates.count, Self.maxVisibleRows)
        let size = NSSize(
            width: TerminalCompletionPopupView.width,
            height: CGFloat(rows) * TerminalCompletionPopupView.rowHeight + TerminalCompletionPopupView.verticalPadding * 2
        )

        let host = self.host ?? NSHostingView(rootView: TerminalCompletionPopupView(model: model))
        self.host = host
        host.frame = NSRect(origin: .zero, size: size)
        let panel = self.panel ?? makePanel(host: host)
        panel.setContentSize(size)

        let onScreen = window.convertToScreen(view.convert(cell, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? onScreen
        var x = onScreen.minX - CGFloat(wordColumns) * onScreen.width
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        var y = onScreen.minY - size.height - 2
        if y < visible.minY { y = onScreen.maxY + 2 }  // no room below: flip above
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        completionLog("completion.present key=true frame=\(Int(x)),\(Int(y)),\(Int(size.width))x\(Int(size.height))")

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        if !panel.isVisible { panel.orderFront(nil) }
        // One transition for every open path (Tab, refilter, after-accept):
        // the popup is visible, so key routing must be armed and observed.
        anchorRowTop = cell.minY
        isOpen = true
        if observers.isEmpty || watchdog == nil { observe(window: window, view: view) }
        completionLog("completion.opened mode=popup rows=\(model.candidates.count) observers=\(observers.count)")
    }

    private func makePanel(host: NSHostingView<TerminalCompletionPopupView>) -> TerminalCompletionPanel {
        let panel = TerminalCompletionPanel(
            contentRect: host.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.identifier = NSUserInterfaceItemIdentifier("bree.terminal.completionPanel")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.worksWhenModal = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    /// Closes on focus loss, window move and resize, and (through the
    /// watchdog) tab switches and scrolling, which post no notification.
    private func observe(window: NSWindow, view: GhosttyNSView) {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification,
            NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.didResignKeyNotification,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        })
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validate() }
        }
    }

    /// Drops the popup when the surface lost focus, left the window, stopped
    /// being at a prompt, or the cursor row moved (scrolling, new output).
    private func validate() {
        guard isOpen, let view, let window = view.window,
              window.firstResponder === view,
              !view.isHiddenOrHasHiddenAncestor,
              view.terminalCompletionSurface != nil,
              let cell = view.terminalCompletionCursorCell(),
              abs(cell.minY - anchorRowTop) < 0.5 else {
            completionLog("completion.validate failed")
            dismiss()
            return
        }
    }
}

final class TerminalCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class TerminalCompletionPopupModel: ObservableObject {
    @Published var candidates: [TerminalCompletionCandidate] = []
    @Published var selection = 0
    /// Bumped per completion session; the popup root is keyed on it so no row state survives.
    @Published var session = 0
    /// The part of the word being completed, used to emphasize matched characters.
    @Published var query = ""
    var onSelect: (Int) -> Void = { _ in }
}

struct TerminalCompletionPopupView: View {
    static let width: CGFloat = 420
    static let rowHeight: CGFloat = 28
    static let verticalPadding: CGFloat = 5
    private static let cornerRadius: CGFloat = 10

    @ObservedObject var model: TerminalCompletionPopupModel
    /// Hosted in a bare `NSHostingView`, so it reads the store instead of the environment.
    @State private var paletteStore = BreeChromePaletteStore.shared
    private var palette: BreeChromePalette { paletteStore.palette }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.candidates.enumerated()), id: \.element.id) { index, candidate in
                        row(candidate, selected: index == model.selection)
                            .contentShape(Rectangle())
                            .onTapGesture { model.onSelect(index) }
                            .id(index)
                    }
                }
                .padding(.horizontal, 5)
                .padding(.vertical, Self.verticalPadding)
            }
            .onChange(of: model.selection) { _, newValue in
                proxy.scrollTo(newValue, anchor: nil)
            }
        }
        .id(model.session)
        .frame(width: Self.width)
        .background(palette.surfaceOverlay)
        .breeSurfaceColorScheme()
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(palette.separator, lineWidth: 1)
        }
        .transaction { $0.animation = nil }
    }

    private func row(_ candidate: TerminalCompletionCandidate, selected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: candidate.kind))
                .breeFont(.body, weight: .medium)
                .foregroundStyle(selected ? palette.activeIndicator : palette.textSecondary)
                .frame(width: 18)
            Text(Self.highlighted(candidate.title, query: model.query, accent: palette.accentFill))
                .breeFont(.body)
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Spacer(minLength: 12)
            Text(Self.detail(for: candidate))
                .breeFont(.secondary)
                .foregroundStyle(palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: Self.rowHeight, maxHeight: Self.rowHeight, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? palette.selectedQuiet : Color.clear)
        }
    }

    private static func symbol(for kind: TerminalCompletionCandidate.Kind) -> String {
        switch kind {
        case .command: return "terminal"
        case .file: return "doc"
        case .directory: return "folder"
        case .gitRef: return "arrow.triangle.branch"
        case .history: return "clock.arrow.circlepath"
        case .option: return "minus"
        }
    }

    /// The dim right-hand label: an option's description, else the kind.
    private static func detail(for candidate: TerminalCompletionCandidate) -> String {
        if let detail = candidate.detail, !detail.isEmpty { return detail }
        switch candidate.kind {
        case .directory: return String(localized: "terminal.completion.detail.directory", defaultValue: "Directory")
        case .file: return String(localized: "terminal.completion.detail.file", defaultValue: "File")
        case .command: return String(localized: "terminal.completion.detail.command", defaultValue: "Command")
        case .gitRef: return String(localized: "terminal.completion.detail.branch", defaultValue: "Branch")
        case .history: return String(localized: "terminal.completion.detail.history", defaultValue: "History")
        case .option: return ""
        }
    }

    /// Accent-colored, semibold characters for the query's in-order matches
    /// (the same subsequence rule the path provider filters with).
    private static func highlighted(_ title: String, query: String, accent: Color) -> AttributedString {
        var attributed = AttributedString(title)
        guard !query.isEmpty else { return attributed }
        var queryIndex = query.startIndex
        var offset = attributed.startIndex
        for character in title {
            let next = attributed.index(afterCharacter: offset)
            if queryIndex < query.endIndex,
               String(character).compare(
                   String(query[queryIndex]),
                   options: [.caseInsensitive, .diacriticInsensitive]
               ) == .orderedSame {
                attributed[offset..<next].foregroundColor = accent
                attributed[offset..<next].inlinePresentationIntent = .stronglyEmphasized
                queryIndex = query.index(after: queryIndex)
            }
            offset = next
        }
        return attributed
    }
}
