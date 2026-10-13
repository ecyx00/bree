import AppKit
import BreeFoundation

final class FileExplorerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let style = FileExplorerStyle.current
        let focused = isKeyboardFocusActive
        let inset = style.selectionInset
        let insetRect = bounds.insetBy(dx: inset, dy: inset > 0 ? 1 : 0)
        let path = NSBezierPath(
            roundedRect: insetRect,
            xRadius: style.selectionRadius,
            yRadius: style.selectionRadius
        )

        selectionFillColor(isFocused: focused).setFill()
        path.fill()
    }

    private var isKeyboardFocusActive: Bool {
        guard let outlineView = enclosingOutlineView else { return false }
        return window?.isKeyWindow == true && window?.firstResponder === outlineView
    }

    private var enclosingOutlineView: NSOutlineView? {
        var view = superview
        while let candidate = view {
            if let outlineView = candidate as? NSOutlineView {
                return outlineView
            }
            view = candidate.superview
        }
        return nil
    }

    private func selectionFillColor(isFocused: Bool) -> NSColor {
        isFocused ? FileExplorerPalette.selectedFill : FileExplorerPalette.selectedQuiet
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        // Selection is a quiet neutral wash, so system text must not flip to white.
        .normal
    }
}
