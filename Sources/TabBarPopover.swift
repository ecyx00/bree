import AppKit
import Bonsplit
import BreeFoundation
import SwiftUI

/// One open popover anchored to a pane tab bar button (Architecture, Wiki). It owns the NSPopover, its anchor
/// view, the "close when the window changes" observers and the drag-to-resize handles. The content and what it
/// shows stay with the caller; closing is reported through `onWillClose` / `onClosed`.
///
/// Size: the caller gives a default (`preferredSize`); a size the user dragged, or one remembered for
/// `sizeName` (UserDefaults, saved when the popover closes), always wins, clamped to the visible screen.
@MainActor
final class TabBarPopoverSession: NSObject, NSPopoverDelegate {
    /// Bonsplit's `.global` space is the hosting view's top-left origin; tab bar button metrics
    /// (vendor/bonsplit TabBarStyling): 28 pt hit target, 8 pt trailing padding, 2 pt between buttons.
    private static let buttonSize: CGFloat = 28
    private static let trailingPadding: CGFloat = 8
    private static let buttonSpacing: CGFloat = 2
    /// Room the popover arrow and its gap take between the button and the content.
    private static let arrowAllowance: CGFloat = 18
    private static let textBoxClearance: CGFloat = 12
    /// Pane width from which the whole button lane is drawn (above bonsplit's compact bar threshold of 300 pt).
    private static let minimumPaneWidthWithButtons: CGFloat = 400

    /// Non-flipped so `preferredEdge: .minY` always means "below" regardless of the host view.
    private final class AnchorView: NSView {
        override var isFlipped: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    let popover = NSPopover()
    private let anchor: AnchorView
    private let host: NSHostingController<AnyView>
    private weak var parent: NSWindow?
    private let sizeName: String
    private let visible: CGRect
    private let maxWidth: CGFloat
    private let maxHeight: CGFloat
    private var observers: [NSObjectProtocol] = []
    private var userSize: CGSize?
    private var defaultSize = NSSize(width: 480, height: 360)
    private var closed = false
    var onWillClose: (() -> Void)?
    var onClosed: (() -> Void)?
    /// Esc while this popover (attached or detached) is the key window. nil: Esc closes it.
    var onEscape: (() -> Void)?
    var onDetached: (() -> Void)?
    /// Called once the popover is key, to put the keyboard focus on the right view.
    var focusInitial: (() -> Void)?
    /// True once the user dragged the popover out into its own panel. A detached popover stays open
    /// when the window changes or the user clicks elsewhere.
    private(set) var isDetached = false
    private var escapeMonitor: Any?
    private var clickMonitor: Any?
    /// A detached panel receives Esc with the main window as `event.window`, so the last click decides who owns it.
    private var detachedHasUserFocus = true

    /// `slot`: 0 is the right-most tab bar button, 1 the one to its left.
    init?<Content: View>(
        workspace: Workspace,
        parent: NSWindow,
        slot: Int,
        sizeName: String,
        preferredSize: (_ maxWidth: CGFloat, _ maxHeight: CGFloat) -> NSSize,
        content: Content
    ) {
        guard let root = parent.contentView else { return nil }
        self.parent = parent
        self.sizeName = sizeName
        let geometry = Self.geometry(workspace: workspace, parent: parent, slot: slot)
        let contentRect = parent.convertToScreen(parent.contentLayoutRect)
        let button = geometry?.button
            ?? NSRect(x: contentRect.maxX - 44 - CGFloat(slot) * (Self.buttonSize + Self.buttonSpacing),
                      y: contentRect.maxY - 44, width: Self.buttonSize, height: Self.buttonSize)
        let pane = geometry?.pane ?? contentRect
        let floorY = Self.floorY(pane: pane, parent: parent)
        maxHeight = button.minY - Self.arrowAllowance - floorY
        maxWidth = pane.width - 16
        visible = (parent.screen ?? NSScreen.main)?.visibleFrame ?? contentRect
        anchor = AnchorView(frame: root.convert(parent.convertFromScreen(button), from: nil))
        root.addSubview(anchor)

        host = NSHostingController(rootView: AnyView(content))
        host.sizingOptions = []
        super.init()
        host.rootView = AnyView(content.overlay {
            PopoverResizeHandles(
                onDrag: { [weak self] kind, target in self?.drag(kind, to: target) },
                gripColor: BreeChromePalette.currentSnapshot.ns.glyphTertiary.withAlphaComponent(0.7)
            )
        })
        popover.behavior = .transient
        popover.animates = true
        popover.appearance = BreeSurfaceAppearance.nsAppearance()
        popover.delegate = self
        popover.contentViewController = host

        if let saved = PopoverSizing.load(name: sizeName, visible: visible) {
            userSize = Self.limited(saved, visible: visible, room: maxHeight)
        }
        defaultSize = preferredSize(maxWidth, maxHeight)
        popover.contentSize = userSize.map { NSSize(width: $0.width, height: $0.height) } ?? defaultSize

        // Geometry is fixed at open time; a window resize or full screen change closes the popover.
        let center = NotificationCenter.default
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification, NSWindow.willCloseNotification,
        ]
        for name in names {
            observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // A detached panel only follows the window it belongs to when that window closes.
                    if self.isDetached && name != NSWindow.willCloseNotification { return }
                    self.popover.close()
                }
            })
        }
    }

    func show() {
        // NSPopover only keeps itself on the screen; keep it inside the window too. The arrow then points
        // at the anchor's centre, which stays on the button whenever the popover fits.
        if let parent, let root = parent.contentView {
            anchor.frame = BreeOverlays.clampedAnchor(anchor.frame, width: popover.contentSize.width, in: root)
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        installEscapeMonitor()
        // A transient popover is not key by itself: without this the keyboard stays with the terminal.
        DispatchQueue.main.async { [weak self] in self?.becomeKey() }
        // The focus code of the main window can take the key back while the popover and its page are still loading.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.closed, self.host.view.window?.isKeyWindow == false else { return }
            self.becomeKey()
        }
    }

    /// Makes the popover window key (no app activation) and lets the owner focus its first view.
    func becomeKey() {
        guard !closed, let window = host.view.window else { return }
        window.makeKey()
        focusInitial?()
    }

    private func installEscapeMonitor() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            self.detachedHasUserFocus = event.window != nil && event.window === self.host.view.window
            return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 53 else { return event }
            let popoverWindow = self.host.view.window
            guard event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  let window = popoverWindow,
                  (self.isDetached ? (event.window === window || self.detachedHasUserFocus) : (event.window === window || window.isKeyWindow || NSApp.keyWindow === window)) else { return event }
            // Esc while an input method is composing belongs to the input method.
            if (window.firstResponder as? NSTextView)?.hasMarkedText() == true { return event }
            if let onEscape = self.onEscape { onEscape() } else { self.popover.close() }
            return nil
        }
    }

    func close() { popover.close() }

    /// Sizes the content to `size` (width stays the user's when they dragged one, height is limited to the room);
    /// nil returns to the user's size, else the default of `init`. For a surface that fits its content (the Wiki topic list).
    func setSurfaceSize(_ size: NSSize?) {
        guard !closed else { return }
        let target: NSSize
        if let size {
            target = NSSize(width: userSize?.width ?? size.width, height: min(size.height, max(maxHeight, 120)))
        } else {
            target = userSize.map { NSSize(width: $0.width, height: $0.height) } ?? defaultSize
        }
        if popover.contentSize == target {
            // The content size can equal the target while the hosted view is still laid out at an earlier, smaller
            // size (the Wiki list measured 0 on first layout); NSPopover only re-lays out on a change, so nudge it.
            guard host.view.window != nil, host.view.frame.height < target.height - 1 else { return }
            popover.contentSize = NSSize(width: target.width, height: target.height - 1)
        }
        popover.contentSize = target
    }

    /// Content-driven default size. Ignored once the user has a size.
    func setPreferredSize(_ make: (_ maxWidth: CGFloat, _ maxHeight: CGFloat) -> NSSize) {
        guard userSize == nil else { return }
        popover.contentSize = make(maxWidth, maxHeight)
    }

    // MARK: Resize

    /// The size limits: the visible screen, and the room between the popover top and the screen bottom.
    private static func limited(_ size: CGSize, visible: CGRect, room: CGFloat) -> CGSize {
        PopoverSizing.clamp(size, visible: visible, maxHeight: max(room, PopoverSizing.minimum.height))
    }

    /// `target` is where the bottom-right corner of the content should be, in screen coordinates.
    /// The popover may shift while it grows; each drag event measures from the current frame, so it converges.
    private func drag(_ kind: PopoverResizeHandles.Kind, to target: NSPoint) {
        guard let window = host.view.window else { return }
        let frame = window.convertToScreen(host.view.convert(host.view.bounds, to: nil))
        let width = kind == .corner ? target.x - frame.minX : frame.width
        let room = frame.maxY - visible.minY - PopoverSizing.screenMargin
        let size = PopoverSizing.clamp(CGSize(width: width, height: frame.maxY - target.y), visible: visible, maxHeight: room)
        guard size != userSize else { return }
        userSize = size
        let animates = popover.animates
        popover.animates = false
        popover.contentSize = NSSize(width: size.width, height: size.height)
        popover.animates = animates
    }

    // MARK: NSPopoverDelegate

    func popoverWillClose(_ notification: Notification) { onWillClose?() }

    /// Drag the popover away to keep it open beside the terminal. It keeps its content and chrome.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool { true }

    func popoverDidDetach(_ popover: NSPopover) {
        isDetached = true
        detachedHasUserFocus = true
        onDetached?()
        DispatchQueue.main.async { [weak self] in self?.becomeKey() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        if let userSize { PopoverSizing.save(userSize, name: sizeName) }
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        anchor.removeFromSuperview()
        popover.contentViewController = nil
        onClosed?()
    }

    // MARK: Geometry

    private struct Geometry {
        /// Screen frames.
        var button: NSRect
        var pane: NSRect
    }

    /// Screen frames of the tab bar button in `slot` and its pane, derived from pane geometry (deterministic, no
    /// view lookup). The pane is the one under a mouse click in `parent`, else the focused pane.
    private static func geometry(workspace: Workspace, parent: NSWindow, slot: Int) -> Geometry? {
        guard let root = parent.contentView else { return nil }
        let snapshot = workspace.bonsplitController.layoutSnapshot()
        var target: PaneGeometry?
        if let event = NSApp.currentEvent, event.window === parent,
           [.leftMouseDown, .leftMouseUp].contains(event.type) {
            let x = event.locationInWindow.x
            let y = root.frame.maxY - event.locationInWindow.y // window (bottom-left) -> top-left
            target = snapshot.panes.first { pane in
                CGRect(x: pane.frame.x, y: pane.frame.y, width: pane.frame.width, height: pane.frame.height)
                    .contains(CGPoint(x: x, y: y))
            }
        }
        if target == nil, let focused = snapshot.focusedPaneId { target = snapshot.panes.first { $0.paneId == focused } }
        // Menu, shortcut and socket opens have no click. A pane narrower than the lane folds the button into
        // "...", so anchor to the widest pane instead, where the button is drawn.
        // ponytail: width heuristic, exact slot visibility would need bonsplit to publish it.
        if target == nil || target!.frame.width < minimumPaneWidthWithButtons,
           let widest = snapshot.panes.max(by: { $0.frame.width < $1.frame.width }),
           widest.frame.width > (target?.frame.width ?? 0) {
            target = widest
        }
        guard let pane = target else { return nil }
        func screenRect(_ topLeft: CGRect) -> NSRect {
            parent.convertToScreen(NSRect(
                x: topLeft.minX, y: root.frame.maxY - topLeft.maxY, width: topLeft.width, height: topLeft.height
            ))
        }
        let barHeight = max(workspace.bonsplitController.configuration.appearance.tabBarHeight, buttonSize)
        let right = pane.frame.x + pane.frame.width - trailingPadding - CGFloat(slot) * (buttonSize + buttonSpacing)
        let top = pane.frame.y + (barHeight - buttonSize) / 2
        let button = screenRect(CGRect(x: right - buttonSize, y: top, width: buttonSize, height: buttonSize))
        guard parent.frame.insetBy(dx: -1, dy: -1).contains(button) else { return nil }
        let paneRect = screenRect(CGRect(x: pane.frame.x, y: pane.frame.y, width: pane.frame.width, height: pane.frame.height))
        return Geometry(button: button, pane: paneRect)
    }

    /// Lowest screen y the popover content may reach: 12 pt above the shell editor textbox of
    /// the pane (or above the pane bottom when the textbox is hidden).
    /// Lowest screen y a popover may reach in `window`, clear of the bottom command bar.
    static func popoverFloorY(in window: NSWindow) -> CGFloat {
        floorY(pane: window.convertToScreen(window.contentLayoutRect), parent: window)
    }

    private static func floorY(pane: NSRect, parent: NSWindow) -> CGFloat {
        var floor = pane.minY + textBoxClearance
        guard let root = parent.contentView else { return floor }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if view is TextBoxInputTextView, !view.isHiddenOrHasHiddenAncestor, view.window === parent {
                let screen = parent.convertToScreen(view.convert(view.bounds, to: nil))
                if screen.midX >= pane.minX, screen.midX <= pane.maxX, screen.minY < pane.midY {
                    // Container padding and the attachment strip sit around the text view.
                    floor = max(floor, screen.maxY + textBoxClearance + 8)
                }
            }
            stack.append(contentsOf: view.subviews)
        }
        return floor
    }
}

// MARK: - Resize handles

/// Bottom edge (height) and bottom-right corner (both directions), over the popover content. Only the handles
/// take mouse events; everything else passes through to the content below.
private struct PopoverResizeHandles: NSViewRepresentable {
    enum Kind { case bottom, corner }

    let onDrag: (Kind, NSPoint) -> Void
    let gripColor: NSColor

    func makeNSView(context: Context) -> HandlesView {
        let view = HandlesView()
        view.onDrag = onDrag
        view.gripColor = gripColor
        return view
    }

    func updateNSView(_ view: HandlesView, context: Context) {
        view.onDrag = onDrag
        view.gripColor = gripColor
        view.needsDisplay = true
    }

    final class HandlesView: NSView {
        var onDrag: ((Kind, NSPoint) -> Void)?
        var gripColor = NSColor.tertiaryLabelColor
        private var active: Kind?
        private var grab = NSPoint.zero
        private var trackingAreas2: [NSTrackingArea] = []

        private static let cornerSize: CGFloat = 16
        private static let edgeThickness: CGFloat = 6

        override var isFlipped: Bool { false }
        override var isOpaque: Bool { false }

        private var cornerRect: NSRect { NSRect(x: bounds.maxX - Self.cornerSize, y: 0, width: Self.cornerSize, height: Self.cornerSize) }
        private var edgeRect: NSRect { NSRect(x: 0, y: 0, width: max(bounds.width - Self.cornerSize, 0), height: Self.edgeThickness) }

        private func kind(at point: NSPoint) -> Kind? {
            if cornerRect.contains(point) { return .corner }
            if edgeRect.contains(point) { return .bottom }
            return nil
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            kind(at: convert(point, from: superview)) == nil ? nil : self
        }

        private func cursor(for kind: Kind) -> NSCursor {
            switch kind {
            case .bottom: return .resizeUpDown
            case .corner:
                if #available(macOS 15.0, *) { return .frameResize(position: .bottomRight, directions: .all) }
                return .crosshair
            }
        }

        override func resetCursorRects() {
            addCursorRect(edgeRect, cursor: cursor(for: .bottom))
            addCursorRect(cornerRect, cursor: cursor(for: .corner))
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas2.forEach(removeTrackingArea)
            trackingAreas2 = [edgeRect, cornerRect].map {
                NSTrackingArea(rect: $0, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways], owner: self)
            }
            trackingAreas2.forEach(addTrackingArea)
        }

        override func layout() {
            super.layout()
            window?.invalidateCursorRects(for: self)
            updateTrackingAreas()
        }

        override func cursorUpdate(with event: NSEvent) { setCursor(at: convert(event.locationInWindow, from: nil)) }
        override func mouseEntered(with event: NSEvent) { setCursor(at: convert(event.locationInWindow, from: nil)) }
        override func mouseExited(with event: NSEvent) { if active == nil { NSCursor.arrow.set() } }

        private func setCursor(at point: NSPoint) {
            if let kind = kind(at: point) { cursor(for: kind).set() }
        }

        override func draw(_ dirtyRect: NSRect) {
            // Two short diagonal strokes in the bottom-right corner.
            gripColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1
            path.lineCapStyle = .round
            for inset: CGFloat in [4, 8] {
                path.move(to: NSPoint(x: bounds.maxX - 3, y: inset))
                path.line(to: NSPoint(x: bounds.maxX - inset, y: 3))
            }
            path.stroke()
        }

        override func mouseDown(with event: NSEvent) {
            guard let kind = kind(at: convert(event.locationInWindow, from: nil)), let window else { return }
            active = kind
            let corner = window.convertToScreen(NSRect(origin: convert(NSPoint(x: bounds.maxX, y: 0), to: nil), size: .zero)).origin
            let mouse = NSEvent.mouseLocation
            grab = NSPoint(x: mouse.x - corner.x, y: mouse.y - corner.y)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let active else { return }
            let mouse = NSEvent.mouseLocation
            onDrag?(active, NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
        }

        override func mouseUp(with event: NSEvent) {
            active = nil
            setCursor(at: convert(event.locationInWindow, from: nil))
        }
    }
}

/// D4: one overlay at a time across the command palette, Wiki, Architecture and Attention.
/// Each entry point calls `closeOthers(than:)` right before it shows itself.
@MainActor
enum BreeOverlays {
    enum Kind { case palette, wiki, architecture, attention, board }

    static func closeOthers(than kind: Kind) {
        if kind != .wiki { WikiPopoverController.shared.closeAllAttached() }
        if kind != .architecture { ArchitectureWindowController.shared.closeAllAttached() }
        if kind != .board { BoardPopoverController.shared.closeAllAttached() }
        if kind != .attention { _ = AppDelegate.shared?.dismissNotificationsPopoverIfShown() }
        if kind != .palette {
            // The palette lives in the window's SwiftUI tree; each ContentView ignores windows that are not its own.
            for window in NSApp.windows {
                NotificationCenter.default.post(name: .commandPaletteDismissRequested, object: window)
            }
        }
    }
}

extension BreeOverlays {
    /// Shifts `rect` (in `view` coordinates) sideways so a popover of `width`, centred on it, stays 12 pt inside the window.
    static func clampedAnchor(_ rect: NSRect, width: CGFloat, in view: NSView) -> NSRect {
        guard let window = view.window, width > 0 else { return rect }
        let bounds = window.contentLayoutRect
        let lower = bounds.minX + 12 + width / 2
        let upper = max(lower, bounds.maxX - 12 - width / 2)
        let center = min(max(rect.midX, lower), upper)
        var shifted = rect
        shifted.origin.x += center - rect.midX
        return shifted
    }
}
