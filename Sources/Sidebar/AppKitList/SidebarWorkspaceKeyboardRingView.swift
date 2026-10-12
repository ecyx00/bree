import AppKit
import CmuxFoundation

/// Visible keyboard selection ring drawn over one workspace row while the left
/// sidebar has keyboard focus. It never takes hit-tests, and it draws two
/// strokes (label colour outside, window background inside) so the ring keeps
/// at least 3:1 contrast on both the plain row and the selected accent fill.
@MainActor
final class SidebarWorkspaceKeyboardRingView: NSView {
    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let heavy = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let outerWidth: CGFloat = heavy ? 3 : 2
        let outer = bounds.insetBy(dx: outerWidth / 2, dy: outerWidth / 2)
        let outerPath = NSBezierPath(roundedRect: outer, xRadius: 8, yRadius: 8)
        outerPath.lineWidth = outerWidth
        BreeChromePalette.currentSnapshot.ns.focusRing.setStroke()
        outerPath.stroke()

        let inner = bounds.insetBy(dx: outerWidth + 0.5, dy: outerWidth + 0.5)
        let innerPath = NSBezierPath(roundedRect: inner, xRadius: 6, yRadius: 6)
        innerPath.lineWidth = 1
        BreeChromePalette.currentSnapshot.ns.surfaceBase.setStroke()
        innerPath.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
