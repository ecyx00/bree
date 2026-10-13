import AppKit
import BreeAppKitSupportUI
import Combine
import BreeFoundation
import BreeSidebar
import BreeWorkspaces
import SwiftUI

/// Pure-AppKit workspace row cell: renders every TabItemView slot without
/// SwiftUI hosting. Subviews are created once (dynamic slots use view pools),
/// content applies in configure, and geometry resolves in one manual
/// layout pass shared with height measurement.
@MainActor
final class SidebarWorkspaceRowTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarWorkspaceRowTableCellView")

    // Chrome
    private let backgroundView = NSView()
    private let railView = NSView()
    private let topDropIndicator = SidebarReorderIndicatorView()
    private let bottomDropIndicator = SidebarReorderIndicatorView()
    private let hintPill = SidebarShortcutHintPillView()
    /// Hosts every content subview so the Done-status dim composites like the
    /// legacy row's `.opacity(0.6)` on the content VStack — the selection
    /// background, rail, drop indicators, and hint pill stay full-strength.
    private let contentContainer = SidebarRowContentContainerView()
    // Title line
    private let leadingBadge = SidebarRowUnreadBadgeView()
    private let pinImageView = NSImageView()
    private let muteImageView = NSImageView()
    private let mediaAudioView = NSImageView()
    private let mediaMicView = NSImageView()
    private let mediaCameraView = NSImageView()
    private let statusGlyphButton = SidebarRowTaskStatusGlyphButton()
    /// `sidebar.compactAgentStatus` leading status glyph.
    private let compactStatusGlyphView = SidebarCompactStatusGlyphImageView()
    private let titleView = SidebarRowTextView(lines: 1)
    private let closeButton = SidebarHeaderGlyphButton()
    // Detail slots
    private let descriptionView = SidebarRowTextView(lines: 12)
    private let subtitleView = SidebarRowTextView(lines: 2)
    /// Line 2 of every card: what the workspace is doing (agent, running
    /// command, or branch and directory); one line, tail-truncated.
    private let agentLineView = SidebarRowTextView(lines: 1)
    /// Fixed 8 pt leading slot of line 1 (status marker; empty when idle).
    private let markerView = SidebarRowStatusMarkerView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
    /// Age of the last state change, right-aligned on line 1.
    private let ageView = SidebarRowTextView(lines: 1)
    /// 6 pt dot left of the age/close slot: an unseen mod warning or error for this workspace.
    /// Mod attention marker: a glyph (triangle for warn, x-circle for error), not only a coloured dot.
    private let modDotView = NSImageView()
    private var modAttention: ModAttentionKind?
    private var modAttentionSub: AnyCancellable?
    private var baseAccessibilityLabel = ""
#if DEBUG
    private var lastLoggedAgentLine: String?
#endif
    private let remoteTargetView = SidebarRowTextView(lines: 1)
    private let remoteStatusView = SidebarRowTextView(lines: 1)
    private let remoteReconnectButton = NSButton()
    private var metadataRows: [SidebarRowIconTextLine] = []
    private let metadataToggleButton = SidebarRowLinkButton()
    private var markdownBlocks: [SidebarRowTextView] = []
    private let markdownToggleButton = SidebarRowLinkButton()
    private let logLine = SidebarRowIconTextLine()
    private let progressView = SidebarRowProgressView()
    private let branchIconView = NSImageView()
    private var branchLines: [SidebarRowIconTextLine] = []
    private var portButtons: [SidebarRowLinkButton] = []
    private let checklistSection = SidebarRowChecklistSection()
    /// Presents the legacy SwiftUI `SidebarWorkspaceStatusPopover` from the
    /// manual status glyph (min width 200, max height 400, below the glyph).
    private let statusPopoverPresenter = SidebarRowSwiftUIPopoverPresenter()
    private var lastStatusPopoverModel: SidebarWorkspaceStatusPopoverModel?

    private var model: SidebarWorkspaceRowModel?
    private var selectionChromeObservers: [NSObjectProtocol] = []
    private var workspaceSelectionChromeObserver: NSObjectProtocol?
    private var actions: SidebarAppKitRowActions?
    private var isPointerHovering = false
    private var contextMenuVisible = false
    private var contextMenuDidOpen: (() -> Void)?
    private var contextMenuDidClose: (() -> Void)?
    /// Active inline-rename session; the title is display-only when nil.
    private var renameSession: SidebarRowInlineRenameSession?
    var isEditing: Bool { renameSession != nil }
    private var pumpCancellables: [AnyCancellable] = []
    private weak var pumpWorkspace: Workspace?
    private var pumpRebuild: (@MainActor () -> Void)?
    private var isPresentationActive = true

#if DEBUG
    /// Test seam: observes every full model application (configure, pump,
    /// optimistic press/deselect, hover enforcement).
    var applyModelProbeForTesting: ((SidebarWorkspaceRowModel) -> Void)?
#endif
    /// Per-row churn pump: mirrors TabItemView's onReceive subscriptions so
    /// metadata/branch/PR updates repaint just this cell without any
    /// container re-render; installation also replays the current model.
    func installPump(
        workspace: Workspace,
        rebuild: @escaping @MainActor () -> Void
    ) {
        pumpRebuild = rebuild
        guard pumpWorkspace !== workspace else { return }
        pumpCancellables.removeAll()
        pumpWorkspace = workspace
        workspace.sidebarImmediateObservationPublisher
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.pumpRebuild?() }
            }
            .store(in: &pumpCancellables)
        workspace.sidebarObservationPublisher
            .dropFirst()
            .debounce(for: .milliseconds(40), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.pumpRebuild?() }
            }
            .store(in: &pumpCancellables)
        rebuild()
    }

    /// Measurement/apply entry used by the pump path.
    func applyRebuiltModel(_ model: SidebarWorkspaceRowModel) {
        guard self.model != model else { return }
        self.model = model
        applyModel(paintedModel(model))
        needsLayout = true
    }

    /// Selection flags painted ahead of the authoritative apply. Hover and
    /// pump repaints layer it over the stored model; before this they
    /// repainted the stored model, so moving the pointer off a just-clicked
    /// row snapped its highlight off until the selection render landed.
    /// Cleared only by restoreStoredModelPaint (authoritative apply or the
    /// preview bailout), a different workspace, or reuse.
    private var optimisticSelection: (isActive: Bool, isMultiSelected: Bool)?

    private func paintedModel(_ model: SidebarWorkspaceRowModel) -> SidebarWorkspaceRowModel {
        guard let optimisticSelection else { return model }
        var painted = model
        painted.isActive = optimisticSelection.isActive
        painted.isMultiSelected = optimisticSelection.isMultiSelected
        return painted
    }

    private func paintOptimisticSelection(isActive: Bool, isMultiSelected: Bool) {
        guard let model else { return }
        optimisticSelection = (isActive, isMultiSelected)
        applyModel(paintedModel(model))
        needsLayout = true
    }

    var currentModelForMeasurement: SidebarWorkspaceRowModel? { model }

    /// Paints the FULL selected treatment instantly on press by applying a
    /// selection-flipped copy of the model — every selection-derived color
    /// (background, title, secondary text, notification preview, badges)
    /// flips with the highlight instead of trailing in with the terminal
    /// swap. The stored model stays authoritative; the next configure()
    /// reconciles (or reverts if the selection did not land).
    func showOptimisticSelectionHighlight() {
        guard let model else { return }
        let painted = paintedModel(model)
        guard !painted.isActive else { return }
        paintOptimisticSelection(isActive: true, isMultiSelected: false)
    }

    /// Counterpart for the row selection is LEAVING: applies the full
    /// deselected treatment instantly so old and new selection never show
    /// together while the authoritative render sits behind the terminal-view
    /// swap. configure() reconciles right after.
    func showOptimisticDeselection() {
        // Checks the painted state, not the stored model: a row that is only
        // optimistically highlighted (rapid clicks) must peel too.
        guard let model else { return }
        let painted = paintedModel(model)
        guard painted.isActive || painted.isMultiSelected else { return }
        paintOptimisticSelection(isActive: false, isMultiSelected: false)
    }

    /// Modifier-click preview: a cmd/shift press JOINS the multi-selection,
    /// so it paints the dim multi-select tint — painting the full active
    /// treatment made every cmd-click flash bright blue and then settle
    /// dim once the authoritative state landed.
    func showOptimisticMultiSelection() {
        guard let model else { return }
        let painted = paintedModel(model)
        guard !painted.isActive, !painted.isMultiSelected else { return }
        paintOptimisticSelection(isActive: false, isMultiSelected: true)
    }

    /// Restores the stored (authoritative) model's paint, undoing any
    /// optimistic treatment. Used by the preview bailout when no
    /// authoritative apply arrives to reconcile.
    func restoreStoredModelPaint() {
        optimisticSelection = nil
        guard let model else { return }
        applyModel(model)
        needsLayout = true
    }

#if DEBUG
    var hasOptimisticSelectionForTesting: Bool { optimisticSelection != nil }
#endif

    /// True when a press at this view should not repaint selection (the
    /// close button closes without selecting; the status glyph and checklist
    /// controls act without activating the row,
    /// exactly like their legacy SwiftUI Buttons).
    func selectionPreviewShouldIgnore(_ hitView: NSView) -> Bool {
        for control in [closeButton, statusGlyphButton, checklistSection] {
            if hitView === control || hitView.isDescendant(of: control) {
                return true
            }
        }
        return false
    }

    /// Re-renders only the age text (called by the controller's shared 60 s timer).
    func refreshAge() {
        guard renameSession == nil,
              let since = model?.agentLine?.since, !ageView.isHidden else { return }
        let text = SidebarRowAgentLine.ageText(since: since)
        guard ageView.stringValue != text else { return }
        ageView.stringValue = text
        needsLayout = true
    }

    /// Configures line 2, the status marker and the age; returns the line 2
    /// text for the row's accessibility label (name + line 2).
    @discardableResult
    private func applyAgentLine(_ line: SidebarRowAgentLine?, model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) -> String {
        agentLineView.isHidden = false
        let font = model.font(.secondary)
        let mono = model.font(.mono)
        let secondary = palette.secondary(0.8)
        let ns = palette.chrome.ns
        let separator = " \u{00B7} "
        typealias Segment = (text: String, machine: Bool, color: NSColor?)
        var segments: [Segment] = []
        var marker: SidebarRowStatusMarkerView.Marker = .none
        var markerColor = secondary
        let claude: Segment = ("Claude", false, nil)
        if let line {
            let detail = line.machine ?? line.human
            let detailIsMachine = line.machine != nil
            switch line.kind {
            case .needsApproval:
                marker = .attention
                markerColor = ns.signalAttention
                // The state word leads and wears the signal colour, so a row that
                // needs the user stands out from calm rows by text, not only a dot.
                segments = [(String(localized: "sidebar.card.state.needsApproval", defaultValue: "Needs approval"), false, ns.signalAttention)]
                if let detail { segments.append((detail, detailIsMachine, nil)) }
            case .needsInput:
                marker = .attention
                markerColor = ns.signalAttention
                segments = [(String(localized: "sidebar.card.state.needsInput", defaultValue: "Needs input"), false, ns.signalAttention)]
                if let detail { segments.append((detail, detailIsMachine, nil)) }
            case .working:
                marker = .activity
                segments = [claude]
                segments.append(detail.map { ($0, detailIsMachine, nil) }
                    ?? (String(localized: "sidebar.card.state.working", defaultValue: "working"), false, nil))
            case .agentIdle:
                let unseen = model.unreadCount > 0
                marker = unseen ? .success : .none
                markerColor = ns.signalSuccess
                segments = [claude, unseen
                    ? (String(localized: "sidebar.card.state.done", defaultValue: "done"), false, nil)
                    : (String(localized: "sidebar.card.state.idle", defaultValue: "idle"), false, nil)]
            case .agentError:
                marker = .error
                markerColor = ns.signalError
                segments = [(String(localized: "sidebar.card.state.error", defaultValue: "Error"), false, ns.signalError)]
                if let detail { segments.append((detail, detailIsMachine, nil)) }
            case .commandRunning:
                marker = .activity
                segments = [(String(localized: "sidebar.card.state.running", defaultValue: "running"), false, nil)]
                if let command = line.machine { segments.append((command, true, nil)) }
            case .idle:
                // A title that already is the path would repeat the directory.
                let title = model.snapshot.title
                let titleIsPath = title.hasPrefix("/") || title.hasPrefix("~") || title == line.directory
                segments = [line.branch, titleIsPath ? nil : line.directory].compactMap { $0 }.map { ($0, true, nil) }
            }
            if line.queued > 0 {
                segments.append((String(format: String(localized: "sidebar.card.queued", defaultValue: "%lld queued"), line.queued).replacingOccurrences(of: " ", with: "\u{00A0}"), false, nil))
            }
        }
        // Neutral activity indicator; signals keep their hue.
        if marker == .activity { markerColor = palette.secondary(0.9) }
        markerView.configure(marker, color: markerColor)

        let text = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                text.append(NSAttributedString(string: separator, attributes: [.font: font, .foregroundColor: secondary]))
            }
            text.append(NSAttributedString(
                string: segment.text,
                attributes: [.font: segment.machine ? mono : font, .foregroundColor: segment.color ?? secondary]
            ))
        }
        let plain = text.string
        // Nothing to say (a path title with no branch): hide the line so the
        // row has no empty gap; hidden blocks take no height in the layout.
        agentLineView.isHidden = segments.isEmpty
#if DEBUG
        let logKey = "\(model.workspaceId.uuidString)|\(plain)"
        if lastLoggedAgentLine != logKey {
            lastLoggedAgentLine = logKey
            breeDebugLog("sidebar.agentLine ws=\(model.workspaceId.uuidString.prefix(8)) text=\"\(plain)\"")
        }
#endif
        agentLineView.configurePlainText(text.string, font: font, color: secondary)
        agentLineView.attributedStringValue = text
        agentLineView.lineBreakMode = .byTruncatingTail

        let ageFont = model.font(.caption)
        ageView.isHidden = line?.since == nil
        if let since = line?.since {
            ageView.stringValue = SidebarRowAgentLine.ageText(since: since)
            ageView.font = ageFont
            // textSecondary carries a 4.5:1 floor; glyphTertiary (3:1) measured 4.21:1.
            ageView.textColor = palette.secondary()
            ageView.lineBreakMode = .byClipping
        }
        return plain
    }

    private func applyBackgroundStyle(_ style: SidebarWorkspaceRowBackgroundStyle) {
        backgroundView.layer?.backgroundColor = (style.color ?? .clear)
            .withAlphaComponent((style.color == nil ? 0 : style.opacity) * ((style.color?.alphaComponent) ?? 1)).cgColor
    }

    /// Paints the selection fill and edge for `model`.
    private func applySelectionChrome(_ model: SidebarWorkspaceRowModel) {
        let palette = palette(model)
        let settings = model.settings
        let style = sidebarWorkspaceRowBackgroundStyle(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            isActive: model.isActive,
            isMultiSelected: model.isMultiSelected,
            customColorHex: model.snapshot.customColorHex,
            colorScheme: palette.colorScheme,
            sidebarSelectionColorHex: settings.selectionColorHex,
            subtleSelection: settings.subtleSelection,
            isEmphasized: palette.isSelectionEmphasized,
            increaseContrast: palette.increasesSelectionContrast,
            accent: palette.accent
        )
        applyBackgroundStyle(palette.backgroundStyle(style))
        if let edgeColor = style.edgeColor {
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.borderColor = edgeColor.cgColor
        } else if settings.activeTabIndicatorStyle.drawsActiveBorder(
            isActive: model.isActive,
            increaseContrast: model.displayAccessibility.increaseContrast
        ) {
            backgroundView.layer?.borderWidth = 1.5
            backgroundView.layer?.borderColor = palette.chrome.ns.borderStrong.cgColor
        } else if style.color == nil {
            // Calm row: text only, no fill or border, so the few rows that
            // need attention are the only ones with anything extra. Hover
            // keeps a quiet wash.
            backgroundView.layer?.backgroundColor = isPointerHovering
                ? palette.chrome.ns.surfaceRaised.withAlphaComponent(0.5).cgColor
                : NSColor.clear.cgColor
            backgroundView.layer?.borderWidth = 0
        } else {
            // Selected card: quiet neutral wash with a 1 px hairline.
            backgroundView.layer?.borderWidth = 1
            backgroundView.layer?.borderColor = palette.chrome.ns.selectedBorder.cgColor
        }
    }

    private func repaintSelectionChrome() {
        guard let model else { return }
        let painted = paintedModel(model)
        guard painted.isActive || painted.isMultiSelected else { return }
        // Window activation switches the default solid fill between
        // `selectedFill` and `selectedQuiet`, and the subtle left-rail
        // treatment depends on it too, so every selected row repaints.
        // Selection-derived foregrounds must resolve from the same window and
        // accessibility state as the fill. These notifications are rare, so
        // repaint the row from its existing model instead of leaving text
        // colors from the previous emphasis/contrast state behind.
        applyModel(painted)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        selectionChromeObservers.forEach { NotificationCenter.default.removeObserver($0) }
        selectionChromeObservers.removeAll()
        workspaceSelectionChromeObserver.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        workspaceSelectionChromeObserver = nil
        guard let window else { return }
        let repaint: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.repaintSelectionChrome() }
        }
        // Palette roles feed every text and fill colour of the row, so a theme
        // change repaints the whole row, not only the selection chrome.
        let repaintPalette: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let model = self.model else { return }
                self.applyModel(self.paintedModel(model))
            }
        }
        selectionChromeObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification, object: window, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignMainNotification, object: window, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: BreeChromePaletteStore.didChangeNotification, object: nil, queue: .main, using: repaintPalette
            ),
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main, using: repaint
            ),
            NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main, using: repaint
            ),
        ]
        workspaceSelectionChromeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main,
            using: repaint
        )
        repaintSelectionChrome()
    }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        wantsLayer = true
        layer?.masksToBounds = false

        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = BreeMetrics.radiusCard
        backgroundView.layer?.cornerCurve = .continuous
        backgroundView.layer?.borderWidth = 0
        addSubview(backgroundView)
        railView.wantsLayer = true
        addSubview(railView)
        addSubview(contentContainer)

        for view in [pinImageView, muteImageView, mediaAudioView, mediaMicView, mediaCameraView] {
            view.imageScaling = .scaleProportionallyDown
            contentContainer.addSubview(view)
        }
        // The glyph view sets its own scaling mode, shared with the SwiftUI list.
        contentContainer.addSubview(compactStatusGlyphView)
        statusGlyphButton.isHidden = true
        statusGlyphButton.onClick = { [weak self] in self?.toggleStatusPopover() }
        contentContainer.addSubview(statusGlyphButton)
        contentContainer.addSubview(leadingBadge)
        contentContainer.addSubview(markerView)
        contentContainer.addSubview(ageView)
        modDotView.imageScaling = .scaleProportionallyDown
        modDotView.isHidden = true
        contentContainer.addSubview(modDotView)
        ModAttentionStore.shared.start()
        modAttentionSub = ModAttentionStore.shared.$kinds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] kinds in
                MainActor.assumeIsolated { self?.applyModAttention(kinds) }
            }
        contentContainer.addSubview(titleView)
        closeButton.onClick = { [weak self] in
            Self.closeRevealHeld = true
            self?.actions?.commands.closeWorkspace()
        }
        closeButton.setAccessibilityRole(.button)
        closeButton.setAccessibilityIdentifier("sidebarWorkspaceCloseButton")
        closeButton.setAccessibilityElement(false)
        closeButton.concealImmediately()
        contentContainer.addSubview(closeButton)

        contentContainer.addSubview(descriptionView)
        descriptionView.onOpenLink = { [weak self] url in
            guard let self else { return }
            self.actions?.commands.updateSelection()
            self.actions?.onOpenWorkspaceDescriptionURL(url)
        }
        contentContainer.addSubview(subtitleView)
        contentContainer.addSubview(agentLineView)
        contentContainer.addSubview(remoteTargetView)
        contentContainer.addSubview(remoteStatusView)
        remoteReconnectButton.isBordered = false
        remoteReconnectButton.imagePosition = .imageLeading
        remoteReconnectButton.target = self
        remoteReconnectButton.action = #selector(didClickReconnect)
        contentContainer.addSubview(remoteReconnectButton)
        contentContainer.addSubview(metadataToggleButton)
        contentContainer.addSubview(markdownToggleButton)
        contentContainer.addSubview(logLine)
        contentContainer.addSubview(progressView)
        branchIconView.imageScaling = .scaleProportionallyDown
        contentContainer.addSubview(branchIconView)
        contentContainer.addSubview(checklistSection)
        statusPopoverPresenter.minWidth = 200
        statusPopoverPresenter.maxHeight = 400

        topDropIndicator.wantsLayer = true
        bottomDropIndicator.wantsLayer = true
        addSubview(topDropIndicator)
        addSubview(bottomDropIndicator)
        addSubview(hintPill)

    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        for action in retirePresentation() {
            action()
        }
        model = nil
        optimisticSelection = nil
        modAttention = nil
        modDotView.isHidden = true
        // The recycled cell may have been the hovered row (often the one just
        // closed). Snap its close button hidden so it cannot fade out on
        // whichever row AppKit hands this cell to next.
        isPointerHovering = false
        closeButton.setAccessibilityElement(false)
        closeButton.concealImmediately()
        hintPill.resetForReuse()
    }

    func setPresentationActive(_ isActive: Bool) {
        isPresentationActive = isActive
        compactStatusGlyphView.isPresentationActive = isActive
    }

    func suspendPresentation(commitEdits: Bool = false) {
        for action in detachPresentation(commitEdits: commitEdits) {
            action()
        }
    }

    func detachPresentation(commitEdits: Bool = false) -> [@MainActor () -> Void] {
        var postUpdateActions: [@MainActor () -> Void] = []
        if let session = renameSession {
            // Resolve before teardown so field-editor end-editing can no
            // longer re-enter commit; the write itself stays deferred past
            // the table mutation.
            let title = session.resolveForSuspension()
            if commitEdits, let title, let commitRename = actions?.commitRename {
                postUpdateActions.append { commitRename(title) }
            }
            removeInlineRenameSession()
        }
        if let checklistAction = checklistSection.detachPresentation(commitEdits: commitEdits) {
            postUpdateActions.append(checklistAction)
        }
        if statusPopoverPresenter.isShown {
            statusPopoverPresenter.close()
        }
        lastStatusPopoverModel = nil
        actions = nil
        contextMenuDidOpen = nil
        contextMenuDidClose = nil
        contextMenuVisible = false
        pumpCancellables.removeAll()
        pumpWorkspace = nil
        pumpRebuild = nil
        setPresentationActive(false)
        return postUpdateActions
    }

    /// Ends the row's semantic lifetime and releases link proxies before reuse.
    func retirePresentation(commitEdits: Bool = false) -> [@MainActor () -> Void] {
        invalidateLinkAccessibility()
        return detachPresentation(commitEdits: commitEdits)
    }

    func configurePresentation(model: SidebarWorkspaceRowModel) {
        let previous = self.model
        suspendPresentation()
        guard previous != model else { return }
        if previous?.workspaceId != model.workspaceId {
            optimisticSelection = nil
            invalidateLinkAccessibility()
        }
        self.model = model
        applyModel(paintedModel(model))
        needsLayout = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsLayout = true
        }
    }

    // MARK: Configure

    func configure(
        model: SidebarWorkspaceRowModel,
        actions: SidebarAppKitRowActions,
        isPointerHovering: Bool,
        contextMenuDidOpen: @escaping () -> Void,
        contextMenuDidClose: @escaping () -> Void
    ) {
        let requiresFullApply = self.actions == nil
        let previous = self.model
        self.actions = actions
        self.contextMenuDidOpen = contextMenuDidOpen
        self.contextMenuDidClose = contextMenuDidClose
        let hoverChanged = self.isPointerHovering != isPointerHovering
        self.isPointerHovering = isPointerHovering
        if previous?.workspaceId != model.workspaceId {
            optimisticSelection = nil
            invalidateLinkAccessibility()
            cancelInlineRename()
            if statusPopoverPresenter.isShown {
                statusPopoverPresenter.close()
            }
            lastStatusPopoverModel = nil
        }
        guard requiresFullApply || previous != model || hoverChanged else { return }
        self.model = model
        if renameSession != nil, !requiresFullApply {
            // Never reconfigure the cell under an active rename field; the
            // latest model is applied when the session ends.
            return
        }
        applyModel(paintedModel(model))
        needsLayout = true
    }

    /// Invalidates the only text views that vend row-owned web-link proxies.
    private func invalidateLinkAccessibility() {
        descriptionView.invalidateLinkAccessibility()
        for view in markdownBlocks {
            view.invalidateLinkAccessibility()
        }
    }

    private func palette(_ model: SidebarWorkspaceRowModel) -> SidebarRowPalette {
        SidebarRowPalette(
            model: model,
            isSelectionEmphasized: NSApp.isActive && (window.map { $0.isKeyWindow || $0.isMainWindow } ?? true),
            increasesSelectionContrast: model.displayAccessibility.increaseContrast
        )
    }

    private func applyModel(_ model: SidebarWorkspaceRowModel) {
#if DEBUG
        applyModelProbeForTesting?(model)
#endif
        // Legacy parity: the SwiftUI sidebar never animates content or color
        // changes; layer-backed subviews here otherwise pick up implicit
        // 0.25s actions on backgroundColor/frame (rails and text visibly
        // crossfaded during resizes and selection).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let palette = palette(model)
        let snapshot = model.snapshot
        let settings = model.settings

        // Chrome
        applySelectionChrome(model)
        let railColor = sidebarWorkspaceRowExplicitRailNSColor(
            activeTabIndicatorStyle: settings.activeTabIndicatorStyle,
            customColorHex: snapshot.customColorHex,
            colorScheme: palette.colorScheme
        )
        railView.isHidden = railColor == nil
        if let railColor {
            railView.layer?.backgroundColor = railColor.withAlphaComponent(0.95).cgColor
        }

        // Title line
        pinImageView.configureSidebarWorkspaceAccessory(
            symbol: "pin.fill", label: snapshot.isPinned
                ? String(localized: "sidebar.pinnedWorkspaceProtected.tooltip", defaultValue: "Pinned workspace — protected from Close") : nil,
            pointSize: model.glyphSize, tint: palette.secondary(0.8)
        )
        muteImageView.configureSidebarWorkspaceAccessory(
            symbol: "bell.slash.fill", label: snapshot.isMuted
                ? String(localized: "sidebar.mutedWorkspace.tooltip", defaultValue: "Notifications muted for this workspace") : nil,
            pointSize: model.glyphSize, tint: palette.secondary(0.8)
        )
        let media = snapshot.mediaActivity
        mediaAudioView.isHidden = !media.isPlayingAudio
        if media.isPlayingAudio {
            mediaAudioView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "speaker.wave.2.fill", pointSize: model.glyphSize, weight: .semibold
            )
            mediaAudioView.contentTintColor = palette.secondary(0.8)
            mediaAudioView.toolTip = String(localized: "sidebar.mediaActivity.audio.tooltip", defaultValue: "Playing audio in a background browser")
        }
        mediaMicView.isHidden = !media.isUsingMicrophone
        if media.isUsingMicrophone {
            mediaMicView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "mic.fill", pointSize: model.glyphSize, weight: nil
            )
            mediaMicView.contentTintColor = palette.chrome.ns.textSecondary
        }
        mediaCameraView.isHidden = !media.isUsingCamera
        if media.isUsingCamera {
            mediaCameraView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "video.fill", pointSize: model.glyphSize, weight: nil
            )
            mediaCameraView.contentTintColor = palette.chrome.ns.textSecondary
        }

        // Manual task-status glyph (legacy `SidebarWorkspaceManualStatusIndicatorMenu`):
        // only a human-set status draws row chrome; automatic status stays out.
        let showsStatusGlyph = model.todoControlsEnabled
            && snapshot.hasManualTaskStatus
            && snapshot.taskStatus != nil
        statusGlyphButton.isHidden = !showsStatusGlyph
        if showsStatusGlyph, let taskStatus = snapshot.taskStatus {
            statusGlyphButton.configure(
                model: .init(
                    status: taskStatus,
                    hasOverride: true,
                    usesMonochrome: model.isActive,
                    fontScale: model.fontScale,
                    colorScheme: palette.colorScheme,
                    accent: palette.accent,
                    differentiateWithoutColor: model.displayAccessibility.differentiateWithoutColor
                ),
                monochromeColor: palette.secondary(0.8),
                neutralColor: palette.secondary(0.8)
            )
        }
        reconcileStatusPopover(model: model, showsAnchor: showsStatusGlyph)
        configureCompactStatusGlyph(model: model, palette: palette)

        // Compact status rows are one line, so title wrapping does not undo it.
        let titleLineLimit = settings.wrapsWorkspaceTitles && snapshot.compactStatusGlyph == nil ? 8 : 1
        titleView.maximumNumberOfLines = titleLineLimit
        titleView.lineBreakMode = titleLineLimit == 1 ? .byTruncatingTail : .byWordWrapping
        let boundedTitle = snapshot.title.sidebarBoundedDisplayString(
            maxDisplayedLines: titleLineLimit,
            maxDisplayedCharacters: 2048
        )
#if DEBUG
        if titleView.stringValue != boundedTitle {
            breeDebugLog(
                "sidebar.row.titlePaint workspace=\(model.workspaceId.uuidString.prefix(8)) " +
                "title=\"\(boundedTitle.prefix(40))\""
            )
        }
#endif
        titleView.stringValue = boundedTitle
        titleView.font = model.font(.title)
        titleView.textColor = palette.primaryText
        titleView.alphaValue = snapshot.isMuted ? 0.6 : 1

        // Badge / close
        // Compact status draws running and unread as its one glyph instead.
        let compacts = snapshot.compactStatusGlyph != nil
        let badgeVisible = !compacts && model.unreadCount > 0
        configureStatusSlot(
            model: model,
            palette: palette,
            badgeVisible: badgeVisible
        )
        closeButton.glyphImage = RenderableSystemSymbol.configuredAppKitImage(
            systemName: "xmark", pointSize: model.glyphSize, weight: .medium
        )
        closeButton.contentTintColor = palette.secondary(0.7)
        let closeButtonTooltip = snapshot.isPinned
            ? String(localized: "sidebar.pinnedWorkspaceProtected.tooltip", defaultValue: "Pinned workspace — protected from Close")
            : String(localized: "sidebar.closeWorkspace.tooltip", defaultValue: "Close workspace")
        closeButton.toolTip = closeButtonTooltip
        closeButton.setAccessibilityLabel(closeButtonTooltip)
        updateCloseVisibility()

        // Description / subtitle
        let description = snapshot.customDescription
        descriptionView.isHidden = description == nil
        if let description {
            let display = description.sidebarBoundedDisplayString(maxDisplayedLines: 12, maxDisplayedCharacters: 4096)
            let customDescriptionColor = settings.workspaceDescriptionColorHex.flatMap(NSColor.init(hex:))
            let descriptionColor = customDescriptionColor ?? palette.secondary(0.84, inactiveOpacity: 0.95)
            if let rendered = SidebarMarkdownRenderer(markdown: display).workspaceDescription {
                descriptionView.configureAttributedText(
                    rendered,
                    font: model.font(.secondary),
                    color: descriptionColor,
                    linkColor: customDescriptionColor ?? palette.linkText
                )
            } else {
                descriptionView.configurePlainText(
                    display,
                    font: model.font(.secondary),
                    color: descriptionColor
                )
            }
        }

        // Line 2 is always present and states the same thing, so the
        // notification and conversation subtitles would only duplicate it.
        subtitleView.isHidden = true
        let lineAccessibilityText = applyAgentLine(model.agentLine, model: model, palette: palette)

        // Remote
        let showsRemote = !settings.hidesAllDetails && settings.showsSSH && snapshot.remoteWorkspaceSidebarText != nil
        remoteTargetView.isHidden = !showsRemote
        remoteStatusView.isHidden = !showsRemote
        remoteReconnectButton.isHidden = !(showsRemote && snapshot.showsRemoteReconnectAffordance)
        if showsRemote {
            remoteTargetView.stringValue = snapshot.remoteWorkspaceSidebarText ?? ""
            remoteTargetView.font = model.font(.mono)
            remoteTargetView.textColor = palette.secondary(0.8)
            remoteTargetView.lineBreakMode = .byTruncatingMiddle
            remoteTargetView.toolTip = snapshot.remoteStateHelpText
            remoteStatusView.stringValue = snapshot.remoteConnectionStatusText
            remoteStatusView.font = model.font(.caption, weight: .medium)
            remoteStatusView.textColor = palette.secondary(0.58)
            if !remoteReconnectButton.isHidden {
                remoteReconnectButton.attributedTitle = NSAttributedString(
                    string: String(localized: "sidebar.remote.reconnect.button", defaultValue: "Reconnect"),
                    attributes: [
                        .font: model.font(.caption, weight: .medium),
                        .foregroundColor: palette.secondary(0.9),
                    ]
                )
                remoteReconnectButton.toolTip = String(localized: "sidebar.remote.reconnect.help", defaultValue: "Reconnect to the remote host")
            }
        }

        configureMetadata(model: model, palette: palette)
        configureLogAndProgress(model: model, palette: palette)
        configureBranchDirectory(model: model, palette: palette)
        configurePorts(model: model, palette: palette)
        if let actions {
            checklistSection.configure(model: model, palette: palette, actions: actions)
        }

        // Hint pill + indicators + dim/drag
        hintPill.configure(
            text: model.shortcutHintText,
            fontSize: model.font(.caption).pointSize,
            emphasis: model.isActive ? 1.0 : 0.9,
            colorScheme: palette.colorScheme,
            representedIdentity: model.workspaceId
        )
        topDropIndicator.accentColor = palette.accent
        bottomDropIndicator.accentColor = palette.accent
        topDropIndicator.layer?.backgroundColor = palette.accentColor.cgColor
        bottomDropIndicator.layer?.backgroundColor = palette.accentColor.cgColor
        topDropIndicator.isHidden = !model.topDropIndicatorVisible
        bottomDropIndicator.isHidden = !model.bottomDropIndicatorVisible
        alphaValue = model.isBeingDragged ? 0.6 : 1
        // Done rows read as settled (legacy parity): dim the row CONTENT to
        // ~60% — never the selection background, rail, or drop chrome.
        contentContainer.alphaValue = snapshot.taskStatus == .done ? 0.6 : 1

        setAccessibilityIdentifier("sidebarWorkspace.\(model.workspaceId.uuidString)")
        let baseLabel = snapshot.accessibilityLabel(
            index: model.index, workspaceCount: model.accessibilityWorkspaceCount
        )
        baseAccessibilityLabel = lineAccessibilityText.isEmpty ? baseLabel : baseLabel + ", " + lineAccessibilityText
        applyModAttention(ModAttentionStore.shared.kinds)
    }

    /// Shows or clears the mod attention dot and keeps the accessibility label in step.
    private func applyModAttention(_ kinds: [UUID: ModAttentionKind]) {
        guard let model else { return }
        let kind = kinds[model.workspaceId]
        if kind != modAttention {
            modAttention = kind
            needsLayout = true
        }
        modDotView.isHidden = kind == nil
        if let kind {
            let colors = BreeChromePalette.currentSnapshot.ns
            modDotView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: kind == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill", pointSize: 9, weight: nil
            )
            modDotView.contentTintColor = kind == .error ? colors.signalError : colors.signalAttention
        }
        let suffix: String?
        switch kind {
        case .error?: suffix = String(localized: "sidebar.workspace.modError", defaultValue: "Mod error")
        case .warn?: suffix = String(localized: "sidebar.workspace.modWarning", defaultValue: "Mod warning")
        case nil: suffix = nil
        }
        setAccessibilityLabel(suffix.map { baseAccessibilityLabel + ", " + $0 } ?? baseAccessibilityLabel)
    }

    /// Live drop-line painting during native reorder drags. The controller
    /// owns the indicator for the drag's lifetime (the model's flags stay
    /// false, so no SwiftUI rows rebuild runs per gap change) and moves it
    /// with two direct view mutations instead of a full-list apply.
    func paintControllerDropIndicator(top: Bool, bottom: Bool) {
        let colorScheme = model.map { $0.colorSchemeIsDark ? ColorScheme.dark : .light }
            ?? SidebarAppearanceColorResolver().currentColorScheme()
        let accent = (model?.settings.accentColor ?? BreeAccentColor()).nsColor(for: colorScheme)
        topDropIndicator.layer?.backgroundColor = accent.cgColor
        bottomDropIndicator.layer?.backgroundColor = accent.cgColor
        topDropIndicator.isHidden = !top
        bottomDropIndicator.isHidden = !bottom
    }

#if DEBUG
    var dropIndicatorPaintForTesting: (top: Bool, bottom: Bool) {
        (!topDropIndicator.isHidden, !bottomDropIndicator.isHidden)
    }

    var closeButtonPaintForTesting: (isHidden: Bool, alpha: CGFloat) {
        (closeButton.isHidden, closeButton.alphaValue)
    }
#endif

    private func configureStatusSlot(
        model: SidebarWorkspaceRowModel,
        palette: SidebarRowPalette,
        badgeVisible: Bool
    ) {
        let badgeFill = breeNotificationBadgeNSColor(
            hex: model.settings.notificationBadgeColorHex,
            fallback: palette.chrome.ns.accentFill
        )
        // Text on the ivory accent fill uses the surface colour (dark on dark themes).
        let badgeText: NSColor = model.settings.notificationBadgeColorHex == nil
            ? palette.chrome.ns.surfaceBase
            : .white
        let badgeFont = model.font(.count, weight: .medium, countRow: .caption)

        leadingBadge.isHidden = !badgeVisible
        if !leadingBadge.isHidden {
            leadingBadge.configure(count: model.unreadCount, fillColor: badgeFill, textColor: badgeText, font: badgeFont)
        }
    }

    /// After a close click the next row slides under the parked pointer. Like macOS, its X
    /// stays hidden until the pointer moves, so a second click cannot close another row.
    static var closeRevealHeld = false

    func refreshCloseReveal() { updateCloseVisibility() }

    private var showsCloseNow: Bool {
        guard let model, !Self.closeRevealHeld else { return false }
        return isPointerHovering
            && !contextMenuVisible
            && model.canCloseWorkspace
            && !(model.showsShortcutHints || model.settings.alwaysShowShortcutHints)
    }

    private func updateCloseVisibility() {
        let revealed = showsCloseNow
#if DEBUG
        if closeButton.isHidden == revealed {
            breeDebugLog("sidebar.card.close hover=\(revealed ? 1 : 0) ws=\(model?.workspaceId.uuidString.prefix(8) ?? "-") frame=\(NSStringFromRect(closeButton.frame))")
        }
#endif
        closeButton.setRevealed(revealed)
        ageView.alphaValue = (revealed && model?.canCloseWorkspace == true) ? 0 : 1
        closeButton.setAccessibilityElement(revealed)
    }

    /// Authoritative hover enforcement: the controller sweeps visible cells
    /// so hover-revealed chrome cannot strand on rows the pointer left
    /// (row-index/id races during churn made per-transition repaints miss).
    func enforcePointerHovering(_ hovering: Bool) {
        guard isPointerHovering != hovering else { return }
        isPointerHovering = hovering
        // Full re-apply: hover gates more than the close button (the
        // trailing badge and spinner hide while the close button shows), and
        // re-deriving that subset here would drift from applyModel.
        if let model {
            applyModel(paintedModel(model))
            needsLayout = true
        } else {
            updateCloseVisibility()
        }
    }

    private func configureCompactStatusGlyph(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let glyph = model.snapshot.compactStatusGlyph?.applyingUnread(
            model.unreadCount,
            latestNotificationText: model.latestNotificationText
        )
        compactStatusGlyphView.isPresentationActive = isPresentationActive
        compactStatusGlyphView.isHidden = glyph?.isDrawn != true
        guard let glyph, glyph.isDrawn else { return }
        compactStatusGlyphView.configure(
            glyph,
            pointSize: model.scaled(11),
            color: glyph.color(
                isActive: model.isActive,
                selected: palette.selectedForeground(0.95),
                secondary: palette.secondary(0.8)
            )
        )
    }

    private func configureMetadata(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        // The agent line already states the session state; the hook-published
        // agent status pill (bell, "Needs input", "Running") would repeat it.
        let allEntries = model.settings.visibleAuxiliaryDetails.showsMetadata
            ? model.snapshot.metadataEntries.filter {
                model.agentLine == nil
                    || !(AgentHibernationLifecycleStatusKeys.isAllowed($0.key)
                        || FeedCoordinator.isAttentionStatusKey($0.key))
            } : []
        let visible = model.isMetadataExpanded ? allEntries : Array(allEntries.prefix(3))
        Self.pool(&metadataRows, count: visible.count, parent: contentContainer) { SidebarRowIconTextLine() }
        for (index, entry) in visible.enumerated() {
            // Legacy parity: on the selected row an explicit entry color
            // yields to the selected foreground — otherwise agent-status
            // tints (blue "Running") vanish into the blue selection
            // highlight. Explicit colors only apply on unselected rows.
            let explicitColor = palette.accent.statusEntryColor(
                hex: entry.color,
                isDark: palette.colorScheme == .dark
            )
            let entryColor: NSColor
            if model.isActive {
                entryColor = explicitColor != nil
                    ? palette.selectedForeground(1.0)
                    : palette.secondary(0.95)
            } else {
                entryColor = explicitColor ?? palette.secondary()
            }
            metadataRows[index].configureMetadataEntry(
                entry,
                model: model,
                color: entryColor
            ) { [weak self] url in
                self?.actions?.commands.updateSelection()
                self?.actions?.onOpenStatusURL(url)
            }
        }
        let toggleFont = model.font(.secondary, weight: .medium)
        let toggleColor = palette.secondary(0.9, inactiveOpacity: 0.9)
        metadataToggleButton.isHidden = allEntries.count <= 3
        if !metadataToggleButton.isHidden {
            metadataToggleButton.configure(
                title: model.isMetadataExpanded
                    ? String(localized: "sidebar.metadata.showLess", defaultValue: "Show less")
                    : String(localized: "sidebar.metadata.showMore", defaultValue: "Show more"),
                font: toggleFont, color: toggleColor, underlined: false, toolTip: nil,
                onClick: { [weak self] in self?.actions?.onToggleMetadataExpansion() }
            )
        }
        let allBlocks = model.settings.visibleAuxiliaryDetails.showsMetadata
            ? model.snapshot.metadataBlocks : []
        let blocks = model.isMarkdownExpanded ? allBlocks : Array(allBlocks.prefix(1))
        markdownToggleButton.isHidden = allBlocks.count <= 1
        if !markdownToggleButton.isHidden {
            markdownToggleButton.configure(
                title: model.isMarkdownExpanded
                    ? String(localized: "sidebar.metadata.showLessDetails", defaultValue: "Show less details")
                    : String(localized: "sidebar.metadata.showMoreDetails", defaultValue: "Show more details"),
                font: toggleFont, color: toggleColor, underlined: false, toolTip: nil,
                onClick: { [weak self] in self?.actions?.onToggleMarkdownExpansion() }
            )
        }
        Self.pool(&markdownBlocks, count: blocks.count, parent: contentContainer) { SidebarRowTextView(lines: 12) }
        for (index, block) in blocks.enumerated() {
            let view = markdownBlocks[index]
            view.onOpenLink = { [weak self] url in
                guard let self else { return }
                self.actions?.commands.updateSelection()
                self.actions?.onOpenStatusURL(url)
            }
            let display = block.markdown.sidebarBoundedDisplayString(maxDisplayedLines: 12, maxDisplayedCharacters: 4096)
            if let rendered = SidebarMetadataMarkdownRenderer.rendered(display) {
                view.configureAttributedText(
                    rendered,
                    font: model.font(.secondary),
                    color: palette.secondary(0.8),
                    linkColor: palette.linkText
                )
            } else {
                view.configurePlainText(
                    display,
                    font: model.font(.secondary),
                    color: palette.secondary(0.8)
                )
            }
        }
    }

    private func configureLogAndProgress(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let log = model.settings.visibleAuxiliaryDetails.showsLog ? model.snapshot.latestLog : nil
        logLine.isHidden = log == nil
        if let log {
            logLine.configureLog(log, model: model, palette: palette)
        }
        let progress = model.settings.visibleAuxiliaryDetails.showsProgress ? model.snapshot.progress : nil
        progressView.isHidden = progress == nil
        if let progress {
            let labelFont = model.font(.caption)
            progressView.configure(
                fraction: CGFloat(progress.value),
                barHeight: max(3, 3 * model.fontScale),
                trackColor: model.isActive
                    ? palette.selectedForeground(0.15)
                    : palette.chrome.ns.separator,
                fillColor: model.isActive
                    ? palette.selectedForeground(0.8)
                    : palette.accentColor,
                labelText: progress.label,
                labelFont: labelFont,
                labelColor: palette.secondary(0.6)
            )
        }
    }

    private func configureBranchDirectory(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let snapshot = model.snapshot
        let settings = model.settings
        // Line 2 carries branch and directory, so this section would repeat it.
        let showsSection = model.agentLine == nil && settings.visibleAuxiliaryDetails.showsBranchDirectory
        var lines: [SidebarRowIconTextLine.BranchLineContent] = []
        if showsSection {
            if settings.branchDirectory.branchLayout == .vertical {
                for line in snapshot.branchDirectoryLines {
                    lines.append(.init(
                        branch: settings.showsGitBranch ? line.branch : nil,
                        directoryCandidates: line.directoryCandidates,
                        stacked: settings.branchDirectory.branchDirectoryPlacement == .stacked
                    ))
                }
            } else if settings.branchDirectory.branchDirectoryPlacement == .stacked {
                if snapshot.compactGitBranchSummaryText != nil || !snapshot.compactDirectoryCandidates.isEmpty {
                    lines.append(.init(
                        branch: snapshot.compactGitBranchSummaryText,
                        directoryCandidates: snapshot.compactDirectoryCandidates,
                        stacked: true
                    ))
                }
            } else if !snapshot.compactBranchDirectoryCandidates.isEmpty {
                lines.append(.init(
                    branch: nil,
                    directoryCandidates: snapshot.compactBranchDirectoryCandidates,
                    stacked: false
                ))
            }
        }
        let showsIcon = showsSection && settings.showsGitBranchIcon
            && (settings.branchDirectory.branchLayout == .vertical
                ? snapshot.branchLinesContainBranch
                : snapshot.compactGitBranchSummaryText != nil || !snapshot.compactBranchDirectoryCandidates.isEmpty)
        branchIconView.isHidden = !(showsIcon && !lines.isEmpty)
        if !branchIconView.isHidden {
            branchIconView.image = RenderableSystemSymbol.configuredAppKitImage(
                systemName: "arrow.triangle.branch", pointSize: model.glyphSize, weight: nil
            )
            branchIconView.contentTintColor = palette.secondary(0.6)
        }
        Self.pool(&branchLines, count: lines.count, parent: contentContainer) { SidebarRowIconTextLine() }
        for (index, content) in lines.enumerated() {
            branchLines[index].configureBranchLine(content, model: model, palette: palette)
        }
    }

    private func configurePorts(model: SidebarWorkspaceRowModel, palette: SidebarRowPalette) {
        let snapshot = model.snapshot
        let settings = model.settings
        let ports = settings.visibleAuxiliaryDetails.showsPorts ? snapshot.listeningPorts : []
        Self.pool(&portButtons, count: ports.count, parent: contentContainer) { SidebarRowLinkButton() }
        for (index, port) in ports.enumerated() {
            portButtons[index].configure(
                title: SidebarPortDisplayText.label(for: port),
                font: model.font(.mono),
                color: palette.secondary(0.75),
                underlined: true,
                toolTip: String(localized: "sidebar.port.openTooltip", defaultValue: "Open localhost port")
            ) { [weak self] in
                self?.actions?.commands.updateSelection()
                self?.actions?.onOpenPort(port)
            }
        }
    }

    private static func pool<View: NSView>(
        _ views: inout [View],
        count: Int,
        parent: NSView,
        make: () -> View
    ) {
        while views.count < count {
            let view = make()
            parent.addSubview(view)
            views.append(view)
        }
        for (index, view) in views.enumerated() {
            view.isHidden = index >= count
        }
    }

    // MARK: Interaction

    @objc private func didClickReconnect() {
        actions?.commands.reconnectRemoteConnection()
    }

    // MARK: Status popover + compact status menu

    private func statusPopoverModel() -> SidebarWorkspaceStatusPopoverModel? {
        guard let menuModel = model?.snapshot.todoStatusMenuModel else { return nil }
        return SidebarWorkspaceStatusPopoverModel(
            inferred: menuModel.inferred,
            activeOverride: menuModel.activeOverride
        )
    }

    private func statusPopoverContent(_ popoverModel: SidebarWorkspaceStatusPopoverModel) -> AnyView {
        AnyView(SidebarWorkspaceStatusPopover(
            model: popoverModel,
            onSelectLane: { [weak self] status in
                self?.actions?.applyTodoStatus(status)
            },
            onSelectNone: { [weak self] in
                self?.actions?.hideTodoStatus()
            },
            onClose: { [weak self] in
                self?.statusPopoverPresenter.close()
            }
        ).breePaletteEnvironment())
    }

    /// Glyph click toggles the status popover (min width 200, max height
    /// 400). Presented to the RIGHT of the glyph: the glyph hugs the
    /// sidebar's left edge, so a below-the-anchor popover puts its arrow
    /// into the rounded corner and renders a deformed beak — `.maxX`
    /// matches the checklist popover's clean left-edge arrow.
    private func toggleStatusPopover() {
        if statusPopoverPresenter.isShown {
            statusPopoverPresenter.close()
            return
        }
        guard let popoverModel = statusPopoverModel(), window != nil else { return }
        lastStatusPopoverModel = popoverModel
        statusPopoverPresenter.present(
            statusPopoverContent(popoverModel),
            relativeTo: statusGlyphButton.bounds,
            of: statusGlyphButton,
            preferredEdge: .maxX
        )
    }

    /// Live refresh while shown: status mutations flow through the normal
    /// configure pass; repaint the open popover instead of showing
    /// creation-time lanes.
    private func reconcileStatusPopover(model: SidebarWorkspaceRowModel, showsAnchor: Bool) {
        guard statusPopoverPresenter.isShown else { return }
        guard showsAnchor, let popoverModel = statusPopoverModel() else {
            statusPopoverPresenter.close()
            return
        }
        if lastStatusPopoverModel != popoverModel {
            lastStatusPopoverModel = popoverModel
            statusPopoverPresenter.update(statusPopoverContent(popoverModel))
        }
    }

    func beginInlineRename() {
        guard let model, renameSession == nil else { return }
        let session = SidebarRowInlineRenameSession(
            baselineTitle: model.snapshot.title,
            baselineHadUserCustomTitle: model.hasUserCustomTitle,
            onResolve: { [weak self] title in
                if let title { self?.actions?.commitRename(title) }
                self?.removeInlineRenameSession()
            }
        )
        session.field.font = model.font(.title)
        session.field.inlineRenameTextColor = palette(model).selectedForeground(1.0)
        renameSession = session
        titleView.isHidden = true
#if DEBUG
        breeDebugLog("sidebar.card.rename begin ws=\(model.workspaceId.uuidString.prefix(8))")
#endif
        // Give the field its title-slot frame BEFORE it enters the window:
        // the attach-time focus grab sizes the field editor from the current
        // frame, and a zero-frame grab mis-sizes the editor's dark box (same
        // lifecycle as SidebarRowChecklistItemLine's edit field).
        needsLayout = true
        layoutSubtreeIfNeeded()
        // Entering the window-attached hierarchy makes the field first
        // responder and selects the whole title (the engine shared with the
        // SwiftUI sidebar); no follow-up selection call may run, because
        // `selectText(_:)` after focus restarts the field-editor session and
        // synchronously commits the untouched title (#9495).
        contentContainer.addSubview(session.field)
        SidebarRowChecklistFieldBridge.clearFieldEditorBackground(session.field)
#if DEBUG
        breeDebugLog(
            "sidebar.row.beginInlineRename tookFocus=\(session.field.currentEditor() != nil ? 1 : 0) window=\(window == nil ? 0 : 1)"
        )
#endif
    }

    /// Cancels any active rename without a write (the workspace changed
    /// under the cell).
    private func cancelInlineRename() {
        guard let session = renameSession else { return }
        _ = session.resolveForSuspension()
        removeInlineRenameSession()
    }

    /// Tears down the session UI; resolution has already happened.
    private func removeInlineRenameSession() {
        guard let session = renameSession else { return }
        renameSession = nil
        session.field.removeFromSuperview()
        titleView.isHidden = false
#if DEBUG
        breeDebugLog("sidebar.card.rename end ws=\(model?.workspaceId.uuidString.prefix(8) ?? "-")")
#endif
        if let model { applyModel(paintedModel(model)) }
        needsLayout = true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let actions else { return nil }
        // The menu owns its tracking lifetime; row retirement clears the
        // cell's live callbacks before AppKit sends menuDidClose.
        let didOpen = contextMenuDidOpen
        let didClose = contextMenuDidClose
        return actions.commands.makeContextMenu(
            onOpen: { [weak self] in
                self?.contextMenuVisible = true
                self?.updateCloseVisibility()
                didOpen?()
            },
            onClose: { [weak self] in
                self?.contextMenuVisible = false
                self?.updateCloseVisibility()
                didClose?()
            },
            beginInlineRename: { [weak self] in
                self?.beginInlineRename()
            }
        )
    }

    // MARK: Layout + measurement

    override func layout() {
        super.layout()
        guard let model else { return }
        // No implicit actions during manual layout: sublayer frame moves
        // otherwise animate when layout runs inside an animation context
        // (legacy parity — geometry snaps, never interpolates).
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        _ = layoutContent(model: model, width: bounds.width, apply: true)
        CATransaction.commit()
    }

    /// Places (or measures) every slot top-down; single source of truth for
    /// row height. Returns total height including vertical padding.
    @discardableResult
    func layoutContent(model: SidebarWorkspaceRowModel, width: CGFloat, apply: Bool) -> CGFloat {
        let outerPad = SidebarWorkspaceListMetrics.rowOuterHorizontalPadding
        let contentPad = SidebarWorkspaceListMetrics.rowContentHorizontalPadding
        let leading = outerPad + contentPad + (model.isGrouped ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
        let trailing = width - outerPad - contentPad
        let contentWidth = max(10, trailing - leading)
        var y: CGFloat = 8
        let spacing: CGFloat = 4

        // Title line
        let titleRowSpacing: CGFloat = 8
        var x = leading
        let badgeSide = 16 * model.fontScale
        let firstLineCenter = model.font(.title).pointSize * 0.6 + y

        func place(_ view: NSView, size: NSSize, centerY: CGFloat) {
            guard apply else { return }
            view.frame = NSRect(
                x: x, y: centerY - size.height / 2,
                width: size.width, height: size.height
            )
        }

        // Fixed leading status slot: reserved on every card so names align.
        let markerSlot = SidebarRowStatusMarkerView.side
        let markerGap: CGFloat = 6
        let lineInset = markerSlot + markerGap
        place(markerView, size: NSSize(width: markerSlot, height: markerSlot), centerY: firstLineCenter)
        let markerX = x
        x += lineInset

        let leadingSlotActive = !leadingBadge.isHidden
        if leadingSlotActive {
            place(leadingBadge, size: NSSize(width: badgeSide, height: badgeSide), centerY: firstLineCenter)
            x += badgeSide + titleRowSpacing
        }
        if !pinImageView.isHidden {
            let side = model.glyphSize + 4
            place(pinImageView, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x += side + titleRowSpacing
        }
        if !muteImageView.isHidden {
            let side = model.glyphSize + 4
            place(muteImageView, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x += side + titleRowSpacing
        }
        for view in [mediaAudioView, mediaMicView, mediaCameraView] where !view.isHidden {
            let side = model.glyphSize + 4
            place(view, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x += side + titleRowSpacing
        }
        if !statusGlyphButton.isHidden {
            let glyphSize = SidebarRowTaskStatusGlyphButton.occupiedSize(fontScale: model.fontScale)
            place(statusGlyphButton, size: glyphSize, centerY: firstLineCenter)
            x += glyphSize.width + titleRowSpacing
        }
        if !compactStatusGlyphView.isHidden {
            // Sits partly in the row's leading padding, with a tighter gap
            // to the title, so the glyph does not push the title far right.
            // Drawn in the reserved status slot so the name never shifts.
            let side = min(model.scaled(11), lineInset)
            let slotX = x
            x = markerX + (markerSlot - side) / 2
            place(compactStatusGlyphView, size: NSSize(width: side, height: side), centerY: firstLineCenter)
            x = slotX
        }

        // Trailing slot
        // The age and the hover close button share the trailing slot: the age
        // gives way to the close button on hover (same place, >= 20 pt hit).
        let closeHit = max(20, 20 * model.fontScale)
        let closeWidth = max(20, closeHit)
        let trailingSlotActive = model.canCloseWorkspace
        var slotWidth = trailingSlotActive ? closeWidth : 0
        if !ageView.isHidden {
            let ageSize = ageView.sidebarNaturalCellSize
            let ageWidth = ceil(ageSize.width)
            if apply {
                ageView.frame = NSRect(
                    x: trailing - ageWidth, y: firstLineCenter - ageSize.height / 2,
                    width: ageWidth, height: ageSize.height
                )
                ageView.alphaValue = (trailingSlotActive && showsCloseNow) ? 0 : 1
            }
            slotWidth = max(slotWidth, ageWidth)
        }
        // The mod attention dot sits just left of the slot, never over the hover close button.
        let dotSide: CGFloat = 10
        let dotReserve: CGFloat = modAttention == nil ? 0 : dotSide + 4
        if apply, modAttention != nil {
            modDotView.frame = NSRect(
                x: trailing - slotWidth - dotReserve, y: firstLineCenter - dotSide / 2,
                width: dotSide, height: dotSide)
        }
        slotWidth += dotReserve
        let titleMaxX = slotWidth > 0 ? (trailing - slotWidth - titleRowSpacing) : trailing
        let titleWidth = max(10, titleMaxX - x)
        let renameField = renameSession?.field
        let titleHeight = renameField.map { ceil($0.intrinsicContentSize.height) }
            ?? titleView.measuredHeight(width: titleWidth)
        if apply {
            let frame = NSRect(x: x, y: y, width: titleWidth, height: titleHeight)
            if let renameField {
                renameField.frame = frame
            } else {
                titleView.frame = frame
            }
            if trailingSlotActive {
                let slotX = trailing - closeWidth
                closeButton.frame = NSRect(
                    x: slotX, y: firstLineCenter - closeHit / 2, width: closeWidth, height: closeHit
                )
            }
        }
        y += max(titleHeight, leadingSlotActive ? badgeSide : 0)

        func placeBlock(_ view: SidebarRowTextView, inset: CGFloat = 0) {
            guard !view.isHidden else { return }
            y += spacing
            let height = view.measuredHeight(width: contentWidth - inset)
            if apply {
                view.frame = NSRect(x: leading + inset, y: y, width: contentWidth - inset, height: height)
            }
            y += height
        }

        placeBlock(descriptionView)
        placeBlock(subtitleView)
        placeBlock(agentLineView, inset: lineInset)

        if !remoteTargetView.isHidden {
            y += model.latestNotificationText == nil ? 1 : 2
            y += spacing
            let statusSize = remoteStatusView.isHidden ? .zero : remoteStatusView.sidebarNaturalCellSize
            let reconnectSize = remoteReconnectButton.isHidden ? .zero : remoteReconnectButton.intrinsicContentSize
            let rightWidth = statusSize.width + (reconnectSize.width > 0 ? reconnectSize.width + 6 : 0)
            let targetWidth = max(10, contentWidth - rightWidth - 6)
            let lineHeight = max(remoteTargetView.sidebarNaturalCellSize.height, statusSize.height, reconnectSize.height)
            if apply {
                remoteTargetView.frame = NSRect(x: leading, y: y, width: targetWidth, height: lineHeight)
                var rightX = trailing - statusSize.width
                if !remoteReconnectButton.isHidden {
                    rightX = trailing - reconnectSize.width
                    remoteReconnectButton.frame = NSRect(x: rightX, y: y, width: reconnectSize.width, height: lineHeight)
                    rightX -= statusSize.width + 6
                }
                remoteStatusView.frame = NSRect(x: rightX, y: y, width: statusSize.width, height: lineHeight)
            }
            y += lineHeight
        }

        for row in metadataRows where !row.isHidden {
            y += 2
            let height = row.measuredHeight(width: contentWidth)
            if apply { row.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        if !metadataToggleButton.isHidden {
            y += 2
            let size = metadataToggleButton.intrinsicContentSize
            if apply {
                metadataToggleButton.frame = NSRect(
                    x: leading, y: y, width: min(size.width, contentWidth), height: size.height
                )
            }
            y += size.height
        }
        for block in markdownBlocks where !block.isHidden {
            y += 3
            let height = block.measuredHeight(width: contentWidth)
            if apply { block.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        if !markdownToggleButton.isHidden {
            y += 2
            let size = markdownToggleButton.intrinsicContentSize
            if apply {
                markdownToggleButton.frame = NSRect(
                    x: leading, y: y, width: min(size.width, contentWidth), height: size.height
                )
            }
            y += size.height
        }
        if !logLine.isHidden {
            y += spacing
            let height = logLine.measuredHeight(width: contentWidth)
            if apply { logLine.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }
        if !progressView.isHidden {
            y += spacing
            let height = SidebarRowProgressView.height(
                barHeight: max(3, 3 * model.fontScale),
                labelText: model.snapshot.progress?.label,
                labelFont: model.font(.caption)
            )
            if apply { progressView.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
            y += height
        }

        let visibleBranchLines = branchLines.filter { !$0.isHidden }
        if !visibleBranchLines.isEmpty {
            y += spacing
            var lineX = leading
            if !branchIconView.isHidden {
                let side = model.glyphSize + 3
                if apply {
                    branchIconView.frame = NSRect(x: leading, y: y, width: side, height: side)
                }
                lineX += side + 3
            }
            let lineWidth = max(10, trailing - lineX)
            for line in visibleBranchLines {
                let height = line.measuredHeight(width: lineWidth)
                if apply { line.frame = NSRect(x: lineX, y: y, width: lineWidth, height: height) }
                y += height + 1
            }
            y -= 1
        }

        let visiblePorts = portButtons.filter { !$0.isHidden }
        if !visiblePorts.isEmpty {
            y += spacing
            var portX = leading
            var lineHeight: CGFloat = 0
            for button in visiblePorts {
                let size = button.intrinsicContentSize
                if portX > leading, portX + size.width > trailing {
                    // Wrap to a new line instead of laying ports past the
                    // row's trailing edge (unbounded growth with many ports).
                    y += lineHeight + 4
                    portX = leading
                    lineHeight = 0
                }
                if apply { button.frame = NSRect(x: portX, y: y, width: size.width, height: size.height) }
                portX += size.width + 4
                lineHeight = max(lineHeight, size.height)
            }
            y += lineHeight
        }

        if !checklistSection.isHidden {
            let height = checklistSection.measuredHeight(width: contentWidth)
            if height > 0 {
                y += spacing
                if apply { checklistSection.frame = NSRect(x: leading, y: y, width: contentWidth, height: height) }
                y += height
            } else if apply {
                // Anchor-only mount (zero-item popover style): the section
                // stays mounted so the open checklist popover keeps its
                // anchor, but it must not reserve any row height — opening
                // the first-item popover previously nudged the row taller.
                // 1pt tall (overlapping the row's bottom padding, drawing
                // nothing): a zero-height view has an empty visibleRect,
                // which NSPopover can refuse to anchor to.
                checklistSection.frame = NSRect(x: leading, y: y, width: contentWidth, height: 1)
            }
        }

        y = max(y + 8, BreeMetrics.rowHeight)

        if apply {
            contentContainer.frame = NSRect(x: 0, y: 0, width: width, height: y)
            // Legacy parity: the SwiftUI row applies the group-member indent
            // OUTSIDE the row (padding before TabItemView), so the selection
            // and hover background shift right with the content. Indenting
            // only the content left the full-width highlight hiding the
            // nesting ("can't tell when a workspace is in a group").
            let bgX = outerPad + (model.isGrouped ? SidebarWorkspaceGroupingMetrics.memberIndent : 0)
            backgroundView.frame = NSRect(x: bgX, y: 0, width: max(0, width - outerPad - bgX), height: y)
            railView.frame = NSRect(x: bgX + 4 - 1, y: 5, width: 3, height: max(0, y - 10))
            railView.layer?.cornerRadius = 1.5
            let indicatorBounds = NSRect(x: 0, y: 0, width: width, height: y)
            topDropIndicator.position(in: indicatorBounds, at: model.isFirstRow ? 0 : -(model.rowSpacing / 2))
            bottomDropIndicator.position(in: indicatorBounds, at: y - SidebarReorderIndicatorView.thickness + model.rowSpacing / 2)
            let pillSize = hintPill.fittingPillSize()
            hintPill.frame = NSRect(
                x: width - pillSize.width - 10 + ShortcutHintDebugSettings.clamped(model.settings.sidebarShortcutHintXOffset),
                y: 6 + ShortcutHintDebugSettings.clamped(model.settings.sidebarShortcutHintYOffset),
                width: pillSize.width, height: pillSize.height
            )
        }
        return ceil(y)
    }
}
