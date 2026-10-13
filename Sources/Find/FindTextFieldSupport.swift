import AppKit

enum FindFocusNotificationKey {
    static let selectAll = "bree.find.selectAll"
}

func breeClampedFindSelection(_ range: NSRange, in text: String) -> NSRange {
    let textLength = text.utf16.count
    guard range.location != NSNotFound else {
        return NSRange(location: textLength, length: 0)
    }
    let location = min(max(range.location, 0), textLength)
    let length = min(max(range.length, 0), textLength - location)
    return NSRange(location: location, length: length)
}

func breeTextFieldIsFirstResponder(_ field: NSTextField, in window: NSWindow) -> Bool {
    let firstResponder = window.firstResponder
    if firstResponder === field { return true }
    if let editor = field.currentEditor() as? NSTextView, firstResponder === editor { return true }
    return (firstResponder as? NSTextView).flatMap { breeFieldEditorOwnerView($0) } === field
}

private let breeFindSelectionChangingCommands: Set<String> = [
    "moveLeft:",
    "moveRight:",
    "moveBackward:",
    "moveForward:",
    "moveUp:",
    "moveDown:",
    "moveWordLeft:",
    "moveWordRight:",
    "moveWordBackward:",
    "moveWordForward:",
    "moveToBeginningOfLine:",
    "moveToEndOfLine:",
    "moveToBeginningOfDocument:",
    "moveToEndOfDocument:",
    "moveLeftAndModifySelection:",
    "moveRightAndModifySelection:",
    "moveBackwardAndModifySelection:",
    "moveForwardAndModifySelection:",
    "moveUpAndModifySelection:",
    "moveDownAndModifySelection:",
    "moveWordLeftAndModifySelection:",
    "moveWordRightAndModifySelection:",
    "moveWordBackwardAndModifySelection:",
    "moveWordForwardAndModifySelection:",
    "moveToBeginningOfLineAndModifySelection:",
    "moveToEndOfLineAndModifySelection:",
    "moveToBeginningOfDocumentAndModifySelection:",
    "moveToEndOfDocumentAndModifySelection:",
    "selectAll:",
]

func breeFindCommandMayChangeSelection(_ selector: Selector) -> Bool {
    breeFindSelectionChangingCommands.contains(NSStringFromSelector(selector))
}

func breeFindEventIsPlainEscape(_ event: NSEvent) -> Bool {
    ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags).isEmpty && ShortcutStroke.isEscapeCancelEvent(event)
}

private let breeFindSelectionStore = NSMapTable<AnyObject, NSValue>.weakToStrongObjects()
private let breeFindFieldEditorOwners = NSMapTable<NSTextView, FindSelectionTrackingTextField>.weakToWeakObjects()

func breeStoredFindSelection(for owner: AnyObject?) -> NSRange? {
    guard let owner else { return nil }
    return breeFindSelectionStore.object(forKey: owner)?.rangeValue
}

func breeStoreFindSelection(_ range: NSRange, for owner: AnyObject?) {
    guard let owner else { return }
    breeFindSelectionStore.setObject(NSValue(range: range), forKey: owner)
}

func breeTrackedFindFieldEditorOwner(_ editor: NSTextView) -> FindSelectionTrackingTextField? {
    guard editor.isFieldEditor else { return nil }
    return breeFindFieldEditorOwners.object(forKey: editor)
}

func breeFindTextFieldOwner(for responder: NSResponder?) -> FindSelectionTrackingTextField? {
    if let field = responder as? FindSelectionTrackingTextField {
        return field
    }
    if let editor = responder as? NSTextView {
        return breeTrackedFindFieldEditorOwner(editor) ?? (breeFieldEditorOwnerView(editor) as? FindSelectionTrackingTextField)
    }
    return nil
}

@MainActor
func breeRememberFindSelectionBeforePanelFocusMove(tabManager: TabManager?, window: NSWindow?) {
    guard let editor = window?.firstResponder as? NSTextView else { return }
    let selection = breeClampedFindSelection(editor.selectedRange(), in: editor.string)
    if let field = breeTrackedFindFieldEditorOwner(editor),
       let owner = field.breeSelectionOwner {
        _ = field.breeRememberSelection(selection, in: editor.string)
        breeStoreFindSelection(selection, for: owner)
        return
    }
    guard let workspace = tabManager?.selectedWorkspace,
          let focusedPanelId = workspace.focusedPanelId else { return }
    let owner = (workspace.focusedTerminalInputTarget()?.panel.searchState as AnyObject?)
        ?? (workspace.browserPanel(for: focusedPanelId)?.searchState as AnyObject?)
    guard let owner else { return }
    breeStoreFindSelection(selection, for: owner)
}

@discardableResult
func breeApplyFindFocusSelection(
    field: FindSelectionTrackingTextField,
    selectAll: Bool,
    alreadyFocused: Bool,
    rememberedRange: NSRange?
) -> NSRange? {
    guard let editor = field.currentEditor() as? NSTextView, !editor.hasMarkedText() else { return nil }
    if selectAll {
        let selection = field.breeRememberSelection(NSRange(location: 0, length: editor.string.utf16.count), in: editor.string)
        editor.setSelectedRange(selection)
        return selection
    }
    guard !alreadyFocused, let rememberedRange else { return nil }
    let selection = field.breeRememberSelection(rememberedRange, in: editor.string)
    editor.setSelectedRange(selection)
    return selection
}

@discardableResult
func breeRememberFindSelection(in root: NSView?) -> NSRange? {
    guard let root else { return nil }
    if let field = root as? FindSelectionTrackingTextField,
       let selection = field.breeRememberSelectionFromCurrentEditor() {
        return selection
    }
    for subview in root.subviews {
        if let selection = breeRememberFindSelection(in: subview) {
            return selection
        }
    }
    return nil
}

func breeFindResponderSnapshot() -> [String: String] {
    let responder = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder
    var updates: [String: String] = [
        "firstResponderType": responder.map { String(describing: type(of: $0)) } ?? "",
        "firstResponderIdentifier": (responder as? NSView)?.identifier?.rawValue ?? "",
    ]
    if let textView = responder as? NSTextView {
        updates["firstResponderSelectedRange"] = NSStringFromRange(textView.selectedRange())
        if let owner = breeFieldEditorOwnerView(textView) {
            updates["fieldEditorOwnerType"] = String(describing: type(of: owner))
            updates["fieldEditorOwnerIdentifier"] = owner.identifier?.rawValue ?? ""
        }
    }
    return updates
}

class FindSelectionTrackingTextField: NSTextField {
    var breeLastSelectedRange: NSRange?
    weak var breeSelectionOwner: AnyObject?
    var breeOnEscape: ((NSTextView) -> Bool)?
    /// Reports whether the field is actually being edited: true once it takes
    /// first responder, false when its field editor ends editing. Drives the
    /// focus stroke, which must not follow a focus request that never landed.
    var breeOnEditingChanged: ((Bool) -> Void)?
    private var breeSelectionObserver: NSObjectProtocol?
    private var breeKeyMonitor: Any?
    private weak var breeObservedEditor: NSTextView?
    private weak var breePreviousEditorNextResponder: NSResponder?

    deinit {
        breeDetachSelectionObserver()
        breeRemoveKeyMonitor()
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        breeAttachSelectionObserverIfNeeded()
        breeRestoreRememberedSelection()
        breeOnEditingChanged?(true)
        return true
    }

    override func textDidBeginEditing(_ notification: Notification) {
        super.textDidBeginEditing(notification)
        breeAttachSelectionObserverIfNeeded()
        breeInstallKeyMonitorIfNeeded()
        if breeLastSelectedRange == nil, breeStoredFindSelection(for: breeSelectionOwner) == nil {
            _ = breeRememberSelectionFromCurrentEditor()
        }
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        _ = breeRememberSelectionFromCurrentEditor()
    }

    override func textDidEndEditing(_ notification: Notification) {
        _ = breeRememberSelectionFromCurrentEditor()
        breeRemoveKeyMonitor()
        breeDetachSelectionObserver()
        super.textDidEndEditing(notification)
        breeOnEditingChanged?(false)
    }

    override func cancelOperation(_ sender: Any?) {
        if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText(), breeOnEscape?(editor) == true {
            return
        }
        super.cancelOperation(sender)
    }

    func breeRememberSelection(_ range: NSRange, in text: String) -> NSRange {
        let selection = breeClampedFindSelection(range, in: text)
        breeLastSelectedRange = selection
        breeStoreFindSelection(selection, for: breeSelectionOwner)
        return selection
    }

    func breeRememberSelection(from textView: NSTextView) -> NSRange {
        breeRememberSelection(textView.selectedRange(), in: textView.string)
    }

    func breeRememberSelectionFromCurrentEditor() -> NSRange? {
        guard let editor = currentEditor() as? NSTextView else { return nil }
        return breeRememberSelection(from: editor)
    }

    private func breeAttachSelectionObserverIfNeeded() {
        guard let editor = currentEditor() as? NSTextView else { return }
        if let breeObservedEditor, breeObservedEditor !== editor {
            breeDetachSelectionObserver()
        }
        breeAdoptFieldEditor(editor)
        guard breeSelectionObserver == nil else { return }
        breeSelectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let textView = notification.object as? NSTextView else { return }
            _ = self.breeRememberSelection(from: textView)
        }
    }

    private func breeDetachSelectionObserver() {
        if let breeSelectionObserver {
            NotificationCenter.default.removeObserver(breeSelectionObserver)
            self.breeSelectionObserver = nil
        }
        if let editor = breeObservedEditor {
            if editor.nextResponder === self {
                editor.nextResponder = breePreviousEditorNextResponder
            }
            if breeTrackedFindFieldEditorOwner(editor) === self {
                breeFindFieldEditorOwners.removeObject(forKey: editor)
            }
        }
        breePreviousEditorNextResponder = nil
        breeObservedEditor = nil
    }

    private func breeAdoptFieldEditor(_ editor: NSTextView) {
        breeObservedEditor = editor
        breeFindFieldEditorOwners.setObject(self, forKey: editor)
        if editor.nextResponder !== self {
            breePreviousEditorNextResponder = editor.nextResponder
            editor.nextResponder = self
        }
        breeInstallKeyMonitorIfNeeded()
    }

    private func breeInstallKeyMonitorIfNeeded() {
        guard breeKeyMonitor == nil else { return }
        breeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let eventWindow = event.window ?? (event.windowNumber > 0 ? NSApp.window(withWindowNumber: event.windowNumber) : nil)
            guard let self,
                  eventWindow == nil || eventWindow === self.window,
                  let editor = self.currentEditor() as? NSTextView,
                  self.window?.firstResponder === editor else { return event }
            if breeFindEventIsPlainEscape(event), !editor.hasMarkedText(), self.breeOnEscape?(editor) == true { return nil }
            DispatchQueue.main.async { [weak self, weak editor] in
                guard let self, let editor else { return }
                _ = self.breeRememberSelection(from: editor)
            }
            return event
        }
    }

    private func breeRemoveKeyMonitor() {
        if let breeKeyMonitor {
            NSEvent.removeMonitor(breeKeyMonitor)
            self.breeKeyMonitor = nil
        }
    }

    private func breeRestoreRememberedSelection() {
        guard let rememberedSelection = breeStoredFindSelection(for: breeSelectionOwner) ?? breeLastSelectedRange else { return }
        if let editor = currentEditor() as? NSTextView, !editor.hasMarkedText() {
            let selection = breeRememberSelection(rememberedSelection, in: editor.string)
            editor.setSelectedRange(selection)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let editor = self.currentEditor() as? NSTextView,
                  !editor.hasMarkedText() else { return }
            let selection = self.breeRememberSelection(rememberedSelection, in: editor.string)
            editor.setSelectedRange(selection)
        }
    }
}
