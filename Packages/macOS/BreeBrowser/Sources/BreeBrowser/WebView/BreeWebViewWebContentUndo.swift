public import AppKit
import BREEDebugLog
public import WebKit

/// Base class for every WebKit view that bree embeds in an app window.
///
/// WebKit registers page edit commands through the view's `undoManager`.
/// `NSResponder` otherwise resolves that property to the window's shared
/// manager, which lets commands from a closed web view remain in a different
/// object's undo stack and later message a dangling target.
open class BreeUndoableWebView: WKWebView {
    public let webContentUndoManager = UndoManager()

    open override var undoManager: UndoManager? { webContentUndoManager }

    /// Whether `event` is the keyboard-layout-aware Cmd+Z or Cmd+Shift+Z
    /// chord this view completes. The keyboard layout lookup lives in the
    /// app, so each concrete web view class overrides this; the base class
    /// recognizes no chord.
    open func isWebContentUndoRedoCommandEquivalent(_ event: NSEvent) -> Bool {
        false
    }

    /// Completes a routed WebKit undo command after the page declines it.
    open override func keyDown(with event: NSEvent) {
        if performWebContentUndoRedo(for: event) {
            return
        }
        super.keyDown(with: event)
    }
}

extension NSWindow {
    /// Finds an embedded WebKit view from a responder without depending on
    /// browser-only panel state. Agent-session and Markdown views use this
    /// path when their web content owns first responder.
    public func breeOwningUndoableWebView(for responder: NSResponder) -> BreeUndoableWebView? {
        if let webView = responder as? BreeUndoableWebView {
            return webView
        }
        if let view = responder as? NSView {
            var current: NSView? = view.superview
            while let candidate = current {
                if let webView = candidate as? BreeUndoableWebView {
                    return webView
                }
                current = candidate.superview
            }
        }
        var current = responder.nextResponder
        var hops = 0
        while let next = current, hops < 64 {
            if let webView = next as? BreeUndoableWebView {
                return webView
            }
            current = next.nextResponder
            hops += 1
        }
        return nil
    }
}

// Cmd+Z / Cmd+Shift+Z for embedded WebKit views.
//
// WebKit registers every web-content edit command on the web view's
// `undoManager` (`WebViewImpl::registerEditCommand` calls
// `[m_view undoManager]`). NSResponder's default implementation resolves that
// to the window's shared undo manager, which mixes edit commands from every
// web view in the window into one stack whose registered targets can outlive
// their web view — the stale-target crash behind
// https://github.com/ecyx00/bree/issues/7272. The fix for that crash
// routes the undo/redo chords away from the AppKit Edit menu whenever a
// browser web view is focused, which also silenced in-page undo/redo because
// nothing performed the command anymore
// (https://github.com/ecyx00/bree/issues/9677).
//
// Owning an undo manager per WebKit view restores both invariants:
// - web-content edit commands never reach the window's shared undo manager
//   and never outlive their web view, so the stale-target class of crashes is
//   impossible by construction;
// - the routed chords can perform undo/redo directly on the focused web
//   view's own stack, matching Safari's Edit-menu behavior.
extension BreeUndoableWebView {
    /// Performs the page's native editing undo/redo for a routed
    /// Cmd+Z / Cmd+Shift+Z chord.
    ///
    /// Returns `false` when `event` is not an undo/redo command equivalent.
    /// Otherwise the chord is consumed even when the relevant stack is empty,
    /// mirroring a disabled Edit-menu item rather than re-forwarding the key.
    public func performWebContentUndoRedo(for event: NSEvent) -> Bool {
        guard isWebContentUndoRedoCommandEquivalent(event) else { return false }
        let isRedo = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .contains(.shift)
#if DEBUG
        BREEDebugLog.logDebugEvent(
            "browser.webContentUndoRedo \(isRedo ? "redo" : "undo") " +
            "web=\(ObjectIdentifier(self)) " +
            "canUndo=\(webContentUndoManager.canUndo ? 1 : 0) " +
            "canRedo=\(webContentUndoManager.canRedo ? 1 : 0)"
        )
#endif
        if isRedo {
            if webContentUndoManager.canRedo {
                webContentUndoManager.redo()
            }
        } else if webContentUndoManager.canUndo {
            webContentUndoManager.undo()
        }
        return true
    }
}
