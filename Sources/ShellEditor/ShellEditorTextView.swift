import AppKit
import Carbon.HIToolbox
import CmuxFoundation
import CmuxTerminalCore
import SwiftUI

/// Builds the editor font from the Ghostty config family and size.
enum ShellEditorFont {
    static func make(family: String, size: CGFloat) -> NSFont {
        let size = size.isFinite && size > 0 ? size : 13
        let name = family.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty,
           let font = NSFont(descriptor: NSFontDescriptor(fontAttributes: [.family: name]), size: size) {
            return font
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

/// The docked command input. Every custom key path bails out while IME
/// composition is active so marked text is never intercepted.
@MainActor
final class ShellEditorTextView: NSTextView {
    weak var shellHost: (any ShellEditorHost)?
    var onHeightChange: ((CGFloat) -> Void)?
    /// Drives the dock's visible focus ring.
    var onFocusChange: ((Bool) -> Void)?
    static let maxLines = 8

    /// Placeholder and hint text: `textSecondary` (4.5:1 floor on every surface).
    static var placeholderColor: NSColor { BreeChromePalette.currentSnapshot.ns.textSecondary }
    /// Ghost suggestion: `glyphTertiary` (3:1 floor), dimmer than the placeholder.
    static var ghostColor: NSColor { BreeChromePalette.currentSnapshot.ns.glyphTertiary }

    private let history = ShellEditorHistory.shared
    private var ghost: String? { didSet { if ghost != oldValue { needsDisplay = true } } }
    private var ghostDismissed = false
    private var pathGhostTask: Task<Void, Never>?
    private var applyingProgrammatic = false
    private var walkPrefix: String?
    private var walkIndex = -1

    // Completion box
    private enum BoxMode { case completion, search }
    private let model = TerminalCompletionPopupModel()
    private var panel: TerminalCompletionPanel?
    private var boxMode: BoxMode = .completion
    private var boxContext: TerminalCompletionContext?
    private var queryTask: Task<Void, Never>?
    private var generation = 0
    private var observers: [NSObjectProtocol] = []
    private var resignObserver: NSObjectProtocol?
    private(set) var isBoxOpen = false
    /// Buffer and caret the box candidates were computed for (completion mode).
    private var boxSnapshot: (buffer: String, caret: Int)?
    /// Key codes forwarded down to the program whose key-up must follow.
    private var forwardedKeyUps = Set<UInt16>()

    private var isProgramInput: Bool { shellHost?.shellEditorProgramInputActive ?? false }
    private var isMasked: Bool { isProgramInput && (shellHost?.shellEditorInputIsMasked ?? false) }

    /// `NSTextView(frame:textContainer: nil)` has NO text system: typing and
    /// `string =` silently do nothing (the "visible but nothing types" bug).
    /// Build storage, layout manager and container explicitly.
    static func make() -> ShellEditorTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        return ShellEditorTextView(frame: .zero, textContainer: container)
    }

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setup()
        cmuxDebugLog("shellEditor.init textContainer=\(self.textContainer != nil) layoutManager=\(layoutManager != nil) storage=\(textStorage != nil) editable=\(isEditable)")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func setup() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        drawsBackground = false
        font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)  // replaced by the terminal font on mount
        textColor = BreeChromePalette.currentSnapshot.ns.textPrimary
        insertionPointColor = BreeChromePalette.currentSnapshot.ns.activeIndicator
        NotificationCenter.default.addObserver(
            self, selector: #selector(chromePaletteDidChange),
            name: BreeChromePaletteStore.didChangeNotification, object: nil
        )
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        textContainerInset = NSSize(width: 0, height: 4)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        setAccessibilityLabel(Self.placeholder)
        model.onSelect = { [weak self] index in
            self?.model.selection = index
            self?.acceptSelection()
        }
    }

    @objc private func chromePaletteDidChange() {
        maskDidChange()
        insertionPointColor = BreeChromePalette.currentSnapshot.ns.activeIndicator
    }

    static var placeholder: String {
        String(localized: "shellEditor.placeholder", defaultValue: "Run a command")
    }

    static var programPlaceholder: String {
        String(localized: "shellEditor.placeholder.program", defaultValue: "Input goes to the running program")
    }

    /// Dim hint after the placeholder; empty when the shortcut is unbound.
    private static var placeholderHint: String {
        let keys = KeyboardShortcutSettings.shortcut(for: .toggleShellEditor).displayString
        guard !keys.isEmpty else { return "" }
        return String(localized: "shellEditor.placeholder.hint", defaultValue: "\(keys) for raw terminal")
    }

    func applyFont(_ newFont: NSFont) {
        guard font != newFont else { return }
        font = newFont
        needsDisplay = true
        updateHeight()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        // Wrapping depends on width: recompute the dock height after a resize.
        if widthChanged { DispatchQueue.main.async { [weak self] in self?.updateHeight() } }
    }

    // MARK: Layout and drawing

    private var lineHeight: CGFloat { layoutManager?.defaultLineHeight(for: font ?? .systemFont(ofSize: 13)) ?? 16 }

    private func updateHeight() {
        guard let lm = layoutManager, let tc = textContainer else { return }
        lm.ensureLayout(for: tc)
        let lines = min(CGFloat(Self.maxLines), max(1, (lm.usedRect(for: tc).height / lineHeight).rounded()))
        let height = lines * lineHeight + textContainerInset.height * 2
        onHeightChange?(height)
    }

    /// Top-left of the ghost text (after the last glyph of a non-empty buffer).
    private func ghostOrigin() -> NSPoint? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        lm.ensureLayout(for: tc)
        let glyph = lm.glyphIndexForCharacter(at: (string as NSString).length - 1)
        let used = lm.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        return NSPoint(x: used.maxX + textContainerOrigin.x, y: used.minY + textContainerOrigin.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !hasMarkedText(), let font else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.placeholderColor]
        if string.isEmpty {
            let origin = NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
            let placeholder = NSAttributedString(string: isProgramInput ? Self.programPlaceholder : Self.placeholder, attributes: attrs)
            placeholder.draw(at: origin)
            let hint = Self.placeholderHint
            if !hint.isEmpty {
                // Right-aligned, 1 pt smaller (min 10 pt); dropped when it would crowd the placeholder.
                let hintFont = NSFont(descriptor: font.fontDescriptor, size: max(10, font.pointSize - 1)) ?? font
                let hintAttrs: [NSAttributedString.Key: Any] = [.font: hintFont, .foregroundColor: Self.placeholderColor]
                let hintText = NSAttributedString(string: hint, attributes: hintAttrs)
                let rightEdge = bounds.width - textContainerOrigin.x - (textContainer?.lineFragmentPadding ?? 0)
                let hintX = rightEdge - hintText.size().width
                if hintX >= origin.x + placeholder.size().width + 24 {
                    let baselineShift = (font.ascender - hintFont.ascender)
                    hintText.draw(at: NSPoint(x: hintX, y: origin.y + (isFlipped ? baselineShift : -baselineShift)))
                }
            }
        } else if isMasked {
            // The real text is drawn clear (see maskDidChange); show bullets instead.
            let dots = String(repeating: "\u{2022}", count: string.count)
            NSAttributedString(string: dots, attributes: [.font: font, .foregroundColor: BreeChromePalette.currentSnapshot.ns.textPrimary])
                .draw(at: NSPoint(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y))
        } else if let ghost, let origin = ghostOrigin() {
            let ghostAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.ghostColor]
            NSAttributedString(string: ghost, attributes: ghostAttrs).draw(at: origin)
        }
    }

    private func updateGhost() {
        let length = (string as NSString).length
        let sel = selectedRange()
        guard !ghostDismissed, !isBoxOpen, !isProgramInput, !hasMarkedText(), sel.length == 0, sel.location == length, !string.contains("\n") else {
            ghost = nil
            pathGhostTask?.cancel()
            return
        }
        ghost = history.ghost(for: string)
        if ghost == nil { refreshPathGhost() } else { pathGhostTask?.cancel() }
    }

    /// Path ghost text: when history has nothing, the word at the caret has
    /// exactly one path candidate extending it. Several matches are noise (the
    /// first alphabetical child is not a prediction); Tab lists them. Runs off
    /// the main thread and is dropped if the buffer changed meanwhile.
    private func refreshPathGhost() {
        pathGhostTask?.cancel()
        let buffer = string
        let context = TerminalCompletionContext.parse(buffer: buffer, caret: buffer.count)
        let word = context.word
        let pathLike = word.contains("/") || word.hasPrefix("~") || word.hasPrefix(".")
        guard context.openQuote == nil, !word.isEmpty, !word.hasPrefix("-"), pathLike || !context.isCommandPosition else { return }
        let cwd = shellHost?.shellEditorWorkingDirectory ?? NSHomeDirectory()
        let directoriesOnly = ["cd", "pushd", "rmdir"].contains(context.command ?? "")
        pathGhostTask = Task { [weak self] in
            let found = await TerminalCompletionProviders.pathCandidatesOffPool(word: word, cwd: cwd, directoriesOnly: directoriesOnly)
            guard let self, !Task.isCancelled, self.string == buffer, self.ghost == nil, !self.isBoxOpen else { return }
            let extending = found.compactMap { TerminalCompletionInline.ghostSuffix(rawWord: context.rawWord, candidate: $0) }
            if extending.count == 1, let suffix = extending.first {
                self.ghost = suffix
                cmuxDebugLog("shellEditor.ghost path word=\(word.count) candidates=\(found.count) suffixLen=\(suffix.count)")
            } else {
                cmuxDebugLog("shellEditor.ghost path none word=\(word.count) candidates=\(found.count) extending=\(extending.count)")
            }
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        // Cmd-C stays enabled with an empty editor selection: it copies the grid's selection.
        if item.action == #selector(copy(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    override func copy(_ sender: Any?) {
        if selectedRange().length == 0 { shellHost?.shellEditorCopyTerminalSelection() } else { super.copy(sender) }
    }

    override func setSelectedRange(_ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting stillSelectingFlag: Bool) {
        super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateGhost()
    }

    override func didChangeText() {
        if !applyingProgrammatic { walkPrefix = nil }
        ghostDismissed = false
        super.didChangeText()
        updateGhost()
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in self?.updateHeight() }
        if isBoxOpen { runQuery() }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let handled = super.performKeyEquivalent(with: event)
        cmuxDebugLog("shellEditor.performKeyEquivalent code=\(event.keyCode) handled=\(handled)")
        return handled
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            shellHost?.shellEditorViewDidBecomeFirstResponder()
            onFocusChange?(true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        if isBoxOpen { cmuxDebugLog("shellEditor.box closed reason=resignFirstResponder") }
        closeBox()
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
#if DEBUG
        if ok {
            DispatchQueue.main.async { [weak self] in
                cmuxDebugLog("shellEditor.focus resigned firstResponderNow=\(String(describing: self?.window?.firstResponder))")
            }
        }
#endif
        return ok
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if isBoxOpen { cmuxDebugLog("shellEditor.box closed reason=moveToWindow") }
        closeBox()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.isBoxOpen == true { cmuxDebugLog("shellEditor.box closed reason=windowResignKey") }
                self?.closeBox()
            }
        }
        // Mounted after the focus request was made: claim focus now.
        DispatchQueue.main.async { [weak self] in
            guard let self, let host = self.shellHost as? TerminalPanel, host.shellEditorHoldsFocusIntent, host.shellEditorIsFocusedPanelInKeyWindow else { return }
            host.shellEditorFocusEditor(requester: "viewDidMoveToWindow")
        }
    }

    /// The panel flipped between command input and program input.
    func programModeDidChange(entering: Bool) {
        closeBox()
        ghost = nil
        pathGhostTask?.cancel()
        walkPrefix = nil
        // Half-typed program input must not turn into a shell command (or a
        // draft) when the mode ends.
        if !entering, !string.isEmpty { setBuffer("") }
        maskDidChange()
        needsDisplay = true
    }

    /// Masked text is drawn clear and replaced by bullets in `draw`.
    func maskDidChange() {
        textColor = isMasked ? .clear : BreeChromePalette.currentSnapshot.ns.textPrimary
        needsDisplay = true
    }

    private func setBuffer(_ text: String) {
        applyingProgrammatic = true
        string = text
        setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        didChangeText()
        applyingProgrammatic = false
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // IME composition (Turkish, Japanese, ...) passes through untouched.
        let mods = event.modifierFlags.intersection([.shift, .control, .option, .command])
        let code = Int(event.keyCode)
        cmuxDebugLog("shellEditor.keyDown code=\(code) mods=\(mods.rawValue) marked=\(hasMarkedText()) box=\(isBoxOpen) editable=\(isEditable) hasStorage=\(textStorage != nil) len=\((string as NSString).length)")
        if hasMarkedText() { super.keyDown(with: event); return }
        if isProgramInput, handleProgramKey(event, code: code, mods: mods) { return }

        if isBoxOpen, handleBoxKey(code: code, mods: mods) { return }

        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.contains(.shift) || mods.contains(.option) { insertNewlineIgnoringFieldEditor(self) } else { submit() }
            return
        case kVK_Tab where mods.isEmpty:
            openCompletion()
            return
        case kVK_Escape where mods.isEmpty:
            if ghost != nil {
                ghostDismissed = true
                ghost = nil
            }
            return
        case kVK_UpArrow where mods.isEmpty && !isProgramInput:
            if walkHistory(older: true) { return }
        case kVK_DownArrow where mods.isEmpty && !isProgramInput:
            if walkHistory(older: false) { return }
        case kVK_RightArrow where mods.isEmpty, kVK_End where mods.isEmpty:
            if acceptGhost() { return }
        case kVK_RightArrow where mods == .option:
            if acceptGhost(segmentOnly: true) { return }
        default:
            break
        }

        if mods == .control, let key = event.charactersIgnoringModifiers?.lowercased(), handleControl(key) { return }
        super.keyDown(with: event)
        cmuxDebugLog("shellEditor.keyDown afterSuper len=\((string as NSString).length)")
    }

    // MARK: Program input

    private static let passthroughCodes: Set<Int> = [
        kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab, kVK_Escape, kVK_Delete, kVK_ForwardDelete,
        kVK_UpArrow, kVK_DownArrow, kVK_LeftArrow, kVK_RightArrow,
        kVK_PageUp, kVK_PageDown, kVK_Home, kVK_End,
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    /// Keys while a command runs. Returns true when handled; false lets the
    /// regular editing path run (typing, arrows and Backspace on a buffer).
    private func handleProgramKey(_ event: NSEvent, code: Int, mods: NSEvent.ModifierFlags) -> Bool {
        if mods.contains(.command) { return false }
        let ctrlLetter = mods.contains(.control) ? event.charactersIgnoringModifiers?.lowercased() : nil
        // Ctrl-C always reaches the program; the half-typed line is dropped.
        if ctrlLetter == "c" {
            if !string.isEmpty { setBuffer("") }
            shellHost?.shellEditorSendControl(.interrupt)
            return true
        }
        if string.isEmpty {
            if Self.passthroughCodes.contains(code) || mods.contains(.control) {
                forward(event)
                return true
            }
            return false
        }
        switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter:
            if mods.contains(.shift) || mods.contains(.option) { insertNewlineIgnoringFieldEditor(self); return true }
            let text = string
            setBuffer("")
            undoManager?.removeAllActions()
            shellHost?.shellEditorSubmitProgramInput(text)
            return true
        case kVK_Escape where mods.isEmpty:
            setBuffer("")
            return true
        case kVK_Tab where mods.isEmpty:
            insertTab(nil)
            return true
        default:
            break
        }
        // Ctrl-letter on a buffer: editing keys only; never the shell-history search.
        if let key = ctrlLetter {
            if ["a", "e", "k", "u", "w", "d"].contains(key) { return handleControl(key) }
            return true
        }
        return false
    }

    private func forward(_ event: NSEvent) {
        forwardedKeyUps.insert(event.keyCode)
        shellHost?.shellEditorForwardKey(event, isDown: true)
    }

    override func keyUp(with event: NSEvent) {
        if forwardedKeyUps.remove(event.keyCode) != nil {
            shellHost?.shellEditorForwardKey(event, isDown: false)
            return
        }
        super.keyUp(with: event)
    }

    private func handleControl(_ key: String) -> Bool {
        switch key {
        case "c":
            if string.isEmpty { shellHost?.shellEditorSendControl(.interrupt) } else { setBuffer("") }
        case "d":
            if string.isEmpty { shellHost?.shellEditorSendControl(.eof) } else { deleteForward(nil) }
        case "z":
            guard string.isEmpty else { return false }
            shellHost?.shellEditorSendControl(.suspend)
        case "l": shellHost?.shellEditorSendControl(.clearScreen)
        case "a": moveToBeginningOfLine(nil)
        case "e": if !acceptGhost() { moveToEndOfLine(nil) }
        case "k": deleteToEndOfLine(nil)
        case "u": deleteToBeginningOfLine(nil)
        case "w": deleteWordBackward(nil)
        case "r": openSearch()
        default: return false
        }
        return true
    }

    // MARK: Submit

    private func submit() {
        let text = string
        if text.isEmpty { shellHost?.shellEditorSubmit(""); return }
        if Self.needsContinuation(text) { insertNewlineIgnoringFieldEditor(self); return }
        history.record(text)
        walkPrefix = nil
        setBuffer("")
        undoManager?.removeAllActions()
        shellHost?.shellEditorSubmit(text)
    }

    /// Unclosed quote or a trailing odd run of backslashes.
    nonisolated static func needsContinuation(_ text: String) -> Bool {
        if TerminalCompletionContext.parse(buffer: text, caret: text.count).openQuote != nil { return true }
        return text.reversed().prefix(while: { $0 == "\\" }).count % 2 == 1
    }

    // MARK: History walk and ghost

    private func walkHistory(older: Bool) -> Bool {
        guard selectedRange().length == 0 else { return false }
        guard older ? caretOnFirstVisualLine() : caretOnLastVisualLine() else { return false }
        if older {
            let prefix = walkPrefix ?? string
            guard let hit = history.walk(from: walkPrefix == nil ? -1 : walkIndex, forward: true, prefix: prefix) else { return true }
            if walkPrefix == nil { walkPrefix = prefix; walkIndex = -1 }
            walkIndex = hit
            setBuffer(history.entries[hit])
        } else {
            guard let prefix = walkPrefix else { return false }
            if let hit = history.walk(from: walkIndex, forward: false, prefix: prefix) {
                walkIndex = hit
                setBuffer(history.entries[hit])
            } else {
                walkIndex = -1
                walkPrefix = nil
                setBuffer(prefix)
            }
        }
        return true
    }

    /// Line fragment rect holding the caret, in text container coordinates.
    private func caretFragmentRect() -> NSRect? {
        guard let lm = layoutManager, let tc = textContainer, !string.isEmpty else { return nil }
        lm.ensureLayout(for: tc)
        let length = (string as NSString).length
        let loc = selectedRange().location
        if loc >= length, !lm.extraLineFragmentRect.isEmpty { return lm.extraLineFragmentRect }
        let glyph = lm.glyphIndexForCharacter(at: min(loc, length - 1))
        return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
    }

    private func caretOnFirstVisualLine() -> Bool {
        guard let lm = layoutManager, let rect = caretFragmentRect() else { return true }
        return rect.minY <= lm.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY + 0.5
    }

    private func caretOnLastVisualLine() -> Bool {
        guard let lm = layoutManager, let rect = caretFragmentRect() else { return true }
        let last = lm.extraLineFragmentRect.isEmpty
            ? lm.lineFragmentRect(forGlyphAt: max(0, lm.numberOfGlyphs - 1), effectiveRange: nil)
            : lm.extraLineFragmentRect
        return rect.minY >= last.minY - 0.5
    }

    private func acceptGhost(segmentOnly: Bool = false) -> Bool {
        guard let ghost, selectedRange().length == 0, selectedRange().location == (string as NSString).length else { return false }
        let text = segmentOnly ? TerminalCompletionInline.firstSegment(of: ghost) : ghost
        cmuxDebugLog("shellEditor.ghost accept segmentOnly=\(segmentOnly) len=\(text.count) dir=\(text.hasSuffix("/"))")
        self.ghost = nil
        insertText(text, replacementRange: NSRange(location: (string as NSString).length, length: 0))
        return true
    }

    // MARK: Completion box

    private func openCompletion() {
        closeBox()
        boxMode = .completion
        isBoxOpen = true
        ghost = nil
        pathGhostTask?.cancel()
        runQuery(autoAcceptSingle: true)
    }

    private func openSearch() {
        closeBox()
        boxMode = .search
        isBoxOpen = true
        ghost = nil
        pathGhostTask?.cancel()
        runQuery()
    }

    private func caretCharacterOffset() -> Int {
        let ns = string as NSString
        return ns.substring(to: min(selectedRange().location, ns.length)).count
    }

    private func runQuery(autoAcceptSingle: Bool = false) {
        queryTask?.cancel()
        generation &+= 1
        let token = generation
        if boxMode == .search {
            let q = string.lowercased()
            let found = history.entries
                .lazy.filter { q.isEmpty || $0.lowercased().contains(q) }
                .prefix(50)
                .map { TerminalCompletionCandidate(kind: .history, title: $0, insertion: $0) }
            boxSnapshot = nil
            finish(Array(found), context: nil, query: string, autoAcceptSingle: false)
            return
        }
        let buffer = string
        let caretUTF16 = selectedRange().location
        let context = TerminalCompletionContext.parse(buffer: buffer, caret: caretCharacterOffset())
        let cwd = shellHost?.shellEditorWorkingDirectory ?? NSHomeDirectory()
        queryTask = Task { [weak self] in
            let worker = Task.detached(priority: .userInitiated) {
                await TerminalCompletionProviders.candidates(for: context, cwd: cwd, isCancelled: { Task.isCancelled })
            }
            let found = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard let self, !Task.isCancelled, self.generation == token,
                  self.string == buffer, self.selectedRange().location == caretUTF16 else { return }
            // The Tab menu lists completions only; history is the ghost text and Ctrl-R.
            let completions = found.filter { $0.kind != .history }
            self.boxSnapshot = (buffer, caretUTF16)
            self.finish(completions, context: context, query: context.word, autoAcceptSingle: autoAcceptSingle)
        }
    }

    private func finish(_ found: [TerminalCompletionCandidate], context: TerminalCompletionContext?, query: String, autoAcceptSingle: Bool) {
        guard isBoxOpen else { return }
        guard !found.isEmpty else { closeBox(); return }
        boxContext = context
        var seen = Set<String>()
        let found = found.filter { seen.insert($0.id).inserted }
        model.candidates = found
        model.query = query
        model.selection = 0
        cmuxDebugLog("shellEditor.tab candidates=\(found.count) fromTab=\(autoAcceptSingle)")
        if autoAcceptSingle, found.count == 1 { acceptSelection(); return }
        if autoAcceptSingle, let context, boxMode == .completion,
           let exact = TerminalCompletionInline.exactCommandIndex(word: context.word, isCommandPosition: context.isCommandPosition, candidates: found) {
            cmuxDebugLog("shellEditor.tab exactCommand index=\(exact)")
            model.selection = exact
            acceptSelection()
            return
        }
        if autoAcceptSingle, let context, boxMode == .completion,
           let extra = TerminalCompletionInline.commonPrefixSuffix(rawWord: context.rawWord, candidates: found) {
            // fish: Tab first completes what every candidate shares; the
            // edit re-queries (box stays open) and the list shows if still ambiguous.
            cmuxDebugLog("shellEditor.tab commonPrefix extra=\(extra.count)")
            insertText(extra, replacementRange: NSRange(location: selectedRange().location, length: 0))
            return
        }
        presentBox()
    }

    private func presentBox() {
        // The editor can live in a window that is not the key window (portal or
        // overlay host); keystrokes reaching this view while the app is active
        // is what "visible and focused" means here.
        let keyWindow = NSApp.keyWindow
        let focused = NSApp.isActive && window?.firstResponder === self
        cmuxDebugLog("shellEditor.present window=\(window?.windowNumber ?? -1) key=\(window?.isKeyWindow ?? false) appKey=\(keyWindow?.windowNumber ?? -1) parent=\(window?.parent?.windowNumber ?? -1) active=\(NSApp.isActive) firstResponder=\(focused)")
        guard let window, window.isKeyWindow || focused || (window.parent != nil && window.parent === keyWindow) else {
            cmuxDebugLog("shellEditor.present skipped")
            closeBox(); return
        }
        let rows = min(model.candidates.count, 8)
        let size = NSSize(
            width: TerminalCompletionPopupView.width,
            height: CGFloat(rows) * TerminalCompletionPopupView.rowHeight + TerminalCompletionPopupView.verticalPadding * 2
        )
        let panel = self.panel ?? makePanel()
        panel.setContentSize(size)
        // Anchor above the editor at the start of the word being completed.
        let ns = string as NSString
        let wordUTF16 = boxMode == .completion ? (boxContext?.rawWord as NSString?)?.length ?? 0 : ns.length
        let anchor = NSRange(location: max(0, selectedRange().location - wordUTF16), length: 0)
        let caret = firstRect(forCharacterRange: anchor, actualRange: nil)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? caret
        let x = min(max(caret.minX, visible.minX), max(visible.minX, visible.maxX - size.width))
        let editorTop = window.convertToScreen(convert(bounds, to: nil)).maxY
        panel.setFrameOrigin(NSPoint(x: x, y: max(caret.maxY, editorTop) + 4))
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }
        if !panel.isVisible { panel.orderFront(nil) }
        cmuxDebugLog("shellEditor.present rows=\(model.candidates.count) parent=\(panel.parent != nil) visible=\(panel.isVisible) frame=\(NSStringFromRect(panel.frame)) keyWindow=\(window.isKeyWindow)")
        if observers.isEmpty {
            let names: [NSNotification.Name] = [NSWindow.didResignKeyNotification, NSWindow.didMoveNotification, NSWindow.didResizeNotification]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeBox(caller: "window.\(name.rawValue)") }
                }
            }
        }
    }

    private func makePanel() -> TerminalCompletionPanel {
        let host = NSHostingView(rootView: TerminalCompletionPopupView(model: model))
        let panel = TerminalCompletionPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.identifier = NSUserInterfaceItemIdentifier("bree.shellEditor.completionPanel")
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .popUpMenu
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentView = host
        self.panel = panel
        return panel
    }

    func closeBox(caller: String = #function) {
        let wasOpen = isBoxOpen
        boxSnapshot = nil
        generation &+= 1
        queryTask?.cancel()
        isBoxOpen = false
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        // The popup root is keyed on `session`, so every session starts from
        // an empty model and fresh row state while the panel is reused.
        model.candidates = []
        model.query = ""
        model.selection = 0
        model.session &+= 1
        cmuxDebugLog("shellEditor.closeBox wasOpen=\(wasOpen) caller=\(caller)")
        if wasOpen { updateGhost() }
    }

    private func moveSelection(by delta: Int) {
        let count = model.candidates.count
        guard count > 0 else { return }
        model.selection = (model.selection + delta + count) % count
    }

    /// The candidates still describe the token under the caret.
    private var boxIsFresh: Bool {
        boxMode == .search || (boxSnapshot.map { $0.buffer == string && $0.caret == selectedRange().location } ?? false)
    }

    private func handleBoxKey(code: Int, mods: NSEvent.ModifierFlags) -> Bool {
        let accepting = (code == kVK_Tab && mods.isEmpty) || (code == kVK_Return && mods.isEmpty)
            || (code == kVK_ANSI_KeypadEnter && mods.isEmpty) || (code == kVK_RightArrow && mods.isEmpty)
        if accepting, !boxIsFresh {
            // The buffer moved on since the list was built (typing, a pending
            // query): never apply it. Tab starts over on the token under the caret.
            closeBox()
            if code == kVK_Tab { openCompletion(); return true }
            return false
        }
        switch code {
        case kVK_UpArrow where mods.isEmpty: moveSelection(by: -1)
        case kVK_DownArrow where mods.isEmpty: moveSelection(by: 1)
        case kVK_Tab where mods == .shift: moveSelection(by: -1)
        case kVK_Tab where mods.isEmpty,
             kVK_Return where mods.isEmpty, kVK_ANSI_KeypadEnter where mods.isEmpty, kVK_RightArrow where mods.isEmpty:
            acceptSelection()
        case kVK_Escape where mods.isEmpty:
            ghostDismissed = true
            closeBox()
        default: return false  // typing, backspace etc. edit normally and refilter in didChangeText
        }
        return true
    }

    private func acceptSelection() {
        guard isBoxOpen, model.candidates.indices.contains(model.selection) else { return }
        let candidate = model.candidates[model.selection]
        let mode = boxMode
        let fresh = boxIsFresh
        closeBox()
        if mode == .search {
            setBuffer(candidate.insertion)
            return
        }
        // Always the token under the caret now, never the one the list was built for.
        guard fresh else { return }
        let context = TerminalCompletionContext.parse(buffer: string, caret: caretCharacterOffset())
        let deleteCount: Int
        let text: String
        if candidate.kind == .history {
            deleteCount = context.linePrefix.count
            text = candidate.insertion
        } else {
            deleteCount = context.rawWord.count
            text = candidate.replacementText
        }
        cmuxDebugLog("shellEditor.accept kind=\(candidate.kind) dir=\(candidate.isDirectory) space=\(candidate.appendsSpace) textLen=\(text.count)")
        // Convert the character count before the caret into a UTF-16 range.
        let ns = string as NSString
        let caret = min(selectedRange().location, ns.length)
        let head = ns.substring(to: caret)
        let keep = String(head.dropLast(deleteCount))
        let start = (keep as NSString).length
        insertText(text, replacementRange: NSRange(location: start, length: caret - start))
        // A directory ends in `/` with no space; didChangeText refreshes the
        // ghost text for its children, and the next Tab lists them.
    }
}

// MARK: - SwiftUI entry

struct ShellEditorDockView: View {
    let host: any ShellEditorHost
    /// Passed by value from the observing parent so the chip re-renders on `cd`.
    let workingDirectory: String?
    /// Git branch of this pane's shell; nil outside a repo.
    var branch: String?
    let focusRequest: Int
    let font: NSFont
    @State private var editorHeight: CGFloat = 24
    @State private var isEditorFocused = false
    @Environment(\.breePalette) private var palette

    private var cwdChip: String? {
        guard let cwd = workingDirectory, !cwd.isEmpty else { return nil }
        let home = NSHomeDirectory()
        let path = cwd == home || cwd.hasPrefix(home + "/") ? "~" + String(cwd.dropFirst(home.count)) : cwd
        return path.split(separator: "/").suffix(2).joined(separator: "/").nilIfEmpty ?? path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let chip = cwdChip {
                HStack(spacing: 6) {
                    Text(chip)
                        .lineLimit(1)
                    if let branch, !branch.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .imageScale(.small)
                                .accessibilityHidden(true)
                            Text(branch)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                    .breeFont(.mono)
                    .foregroundStyle(palette.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(palette.hoverFill))
            }
            HStack(alignment: .top, spacing: 8) {
                Text("❯")
                    .font(Font(font))
                    .fontWeight(.semibold)
                    .foregroundStyle(palette.activeIndicator)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
                ShellEditorRepresentable(host: host, focusRequest: focusRequest, font: font, height: $editorHeight, isFocused: $isEditorFocused)
                    .frame(height: editorHeight)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous).fill(palette.surfaceSunken))
            // `borderStrong` keeps a 3:1 boundary; focus swaps it for a 2 pt focus ring.
            .overlay(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous)
                    .strokeBorder(
                        isEditorFocused ? palette.focusRing : palette.borderStrong,
                        lineWidth: isEditorFocused ? 2 : 1
                    )
            )
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private struct ShellEditorRepresentable: NSViewRepresentable {
    let host: any ShellEditorHost
    let focusRequest: Int
    let font: NSFont
    @Binding var height: CGFloat
    @Binding var isFocused: Bool

    final class Coordinator { var lastFocus: Int? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        ShellEditorHistory.shared.seedIfNeeded()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = ShellEditorTextView.make()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        textView.shellHost = host
        host.shellEditorRegisterView(textView)
        textView.applyFont(font)
        if let draft = ShellEditorHistory.shared.drafts[host.shellEditorPanelID] {
            textView.string = draft
            textView.setSelectedRange(NSRange(location: (draft as NSString).length, length: 0))
        }
        let binding = $height
        textView.onHeightChange = { h in if abs(binding.wrappedValue - h) > 0.5 { binding.wrappedValue = h } }
        let focusBinding = $isFocused
        textView.onFocusChange = { focused in
            DispatchQueue.main.async { focusBinding.wrappedValue = focused }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? ShellEditorTextView else { return }
        textView.shellHost = host
        textView.applyFont(font)
        if context.coordinator.lastFocus != focusRequest {
            context.coordinator.lastFocus = focusRequest
            DispatchQueue.main.async { [weak textView] in
                guard let textView, let host = textView.shellHost else { return }
                if !host.shellEditorFocusEditor(requester: "focusRequest") {
                    textView.window?.makeFirstResponder(textView)
                }
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        guard let textView = scroll.documentView as? ShellEditorTextView, let host = textView.shellHost else { return }
        // Program input (and anything masked) is never kept as a draft.
        let keep = !host.shellEditorProgramInputActive && !textView.string.isEmpty
        ShellEditorHistory.shared.drafts[host.shellEditorPanelID] = keep ? textView.string : nil
        textView.closeBox()
        host.shellEditorRegisterView(nil)
    }
}
