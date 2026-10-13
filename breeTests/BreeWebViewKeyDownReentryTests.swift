import AppKit
import BreeBrowser
import Carbon.HIToolbox
import Testing
import WebKit
import ObjectiveC.runtime

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

private var breeUnitTestBreeWebViewKeyDownOriginalIMP: IMP?
private var breeUnitTestBreeWebViewKeyDownHook: ((BreeWebView, NSEvent) -> Bool)?

private final class FakeWKInspectorUndoResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private final class BrowserUndoMenuActionSpy: NSObject {
    private(set) var invoked = false

    @objc func didInvoke(_ sender: Any?) {
        _ = sender
        invoked = true
    }
}

/// Hooks `BreeWebView.keyDown(with:)` for the duration of one test window.
///
/// WHY scoped, not process-wide: other suites in the same app host (for
/// example `BreeWebViewWebContentUndoTests`) swizzle the same key path on
/// `WKWebView` and exercise `BreeWebView.keyDown` with no hook set. A
/// permanent swizzle left behind by this suite made those tests recurse until
/// the stack overflowed whenever the two suites shared a process. The hook
/// calls the captured original implementation directly and is removed again
/// in `uninstallBreeUnitTestBreeWebViewKeyDownOverride()`.
private func installBreeUnitTestBreeWebViewKeyDownOverride() {
    guard breeUnitTestBreeWebViewKeyDownOriginalIMP == nil else { return }

    let selector = #selector(BreeWebView.keyDown(with:))
    guard let method = class_getInstanceMethod(BreeWebView.self, selector) else {
        fatalError("Unable to locate BreeWebView keyDown method for swizzling")
    }

    typealias KeyDownIMP = @convention(c) (AnyObject, Selector, NSEvent) -> Void
    let originalIMP = method_getImplementation(method)
    let original = unsafeBitCast(originalIMP, to: KeyDownIMP.self)
    let hooked: @convention(block) (BreeWebView, NSEvent) -> Void = { webView, event in
        if breeUnitTestBreeWebViewKeyDownHook?(webView, event) == true {
            return
        }
        original(webView, selector, event)
    }
    breeUnitTestBreeWebViewKeyDownOriginalIMP = originalIMP
    method_setImplementation(method, imp_implementationWithBlock(hooked))
}

private func uninstallBreeUnitTestBreeWebViewKeyDownOverride() {
    guard let originalIMP = breeUnitTestBreeWebViewKeyDownOriginalIMP,
          let method = class_getInstanceMethod(
              BreeWebView.self,
              #selector(BreeWebView.keyDown(with:))
          ) else { return }
    method_setImplementation(method, originalIMP)
    breeUnitTestBreeWebViewKeyDownOriginalIMP = nil
}

@Suite(.serialized)
final class BreeWebViewKeyDownReentryTests {
    @Test
    @MainActor
    func printableOptionTextRoutesToBrowserKeyDownOnce() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(keyDownEvents().map(\.keyCode) == [0])
        }
    }

    @Test
    @MainActor
    func printableOptionTextDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "å",
                modifiers: [.option],
                keyCode: 0,
                windowNumber: window.windowNumber
            ))

            let webView = try #require(window.firstResponder as? WKWebView)
            let handled = webView.withBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserReturnDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "\r",
                modifiers: [],
                keyCode: 36,
                windowNumber: window.windowNumber
            ))

            let webView = try #require(window.firstResponder as? WKWebView)
            let handled = webView.withBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserArrowDoesNotReenterBrowserKeyDownDuringWebKitKeyDownDispatch() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            let event = try #require(makeKeyDownEvent(
                key: "\u{F701}",
                modifiers: [],
                keyCode: 125,
                windowNumber: window.windowNumber
            ))

            let webView = try #require(window.firstResponder as? WKWebView)
            let handled = webView.withBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(!handled)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserUndoRedoFallsBackToBrowserKeyDownWhenWebKitDeclines() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installBreeUnitTestWKWebViewPerformKeyEquivalentOverride()

            var performKeyEquivalentEvents: [NSEvent] = []
            breeUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView.window === window else { return nil }
                performKeyEquivalentEvents.append(event)
                return false
            }
            defer { breeUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(performKeyEquivalentEvents.map(\.keyCode) == [UInt16(kVK_ANSI_Z)])
            #expect(keyDownEvents().map(\.keyCode) == [UInt16(kVK_ANSI_Z)])
        }
    }

    @Test
    @MainActor
    func browserUndoRedoDoesNotRouteDuringWebKitKeyDownReentry() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installBreeUnitTestWKWebViewPerformKeyEquivalentOverride()

            var performKeyEquivalentEvents: [NSEvent] = []
            breeUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView.window === window else { return nil }
                performKeyEquivalentEvents.append(event)
                return false
            }
            defer { breeUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            let webView = try #require(window.firstResponder as? WKWebView)
            let handled = webView.withBrowserWebKitKeyDownDispatch {
                window.performKeyEquivalent(with: event)
            }

            #expect(handled)
            #expect(performKeyEquivalentEvents.isEmpty)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @Test
    @MainActor
    func browserUndoRedoDoesNotBypassMenuWhenWebInspectorResponderIsFocused() throws {
        try withHookedBrowserKeyDownWindow { window, keyDownEvents in
            installBreeUnitTestWKWebViewPerformKeyEquivalentOverride()

            let spy = BrowserUndoMenuActionSpy()
            let previousMenu = installUndoMenu(target: spy)
            defer { NSApp.mainMenu = previousMenu }

            let webView = try #require(window.contentView?.subviews.compactMap { $0 as? BreeWebView }.first)
            let inspectorView = FakeWKInspectorUndoResponderView(frame: NSRect(x: 0, y: 0, width: 32, height: 20))
            webView.addSubview(inspectorView)

            var performKeyEquivalentEvents: [NSEvent] = []
            breeUnitTestWKWebViewPerformKeyEquivalentHook = { currentWebView, event in
                guard currentWebView === webView else { return nil }
                performKeyEquivalentEvents.append(event)
                return true
            }
            defer { breeUnitTestWKWebViewPerformKeyEquivalentHook = nil }

            #expect(window.makeFirstResponder(inspectorView))
            let event = try #require(makeKeyDownEvent(
                key: "z",
                modifiers: [.command],
                keyCode: UInt16(kVK_ANSI_Z),
                windowNumber: window.windowNumber
            ))

            #expect(window.performKeyEquivalent(with: event))
            #expect(spy.invoked)
            #expect(performKeyEquivalentEvents.isEmpty)
            #expect(keyDownEvents().isEmpty)
        }
    }

    @MainActor
    private func withHookedBrowserKeyDownWindow(
        _ body: (NSWindow, () -> [NSEvent]) throws -> Void
    ) rethrows {
        _ = NSApplication.shared
        AppDelegate.installWindowResponderSwizzlesForTesting()
        installBreeUnitTestBreeWebViewKeyDownOverride()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = container

        let webView = BreeWebView(frame: container.bounds, configuration: WKWebViewConfiguration(), host: BreeWebViewAppHost())
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        var keyDownEvents: [NSEvent] = []
        breeUnitTestBreeWebViewKeyDownHook = { currentWebView, event in
            guard currentWebView === webView else { return false }
            keyDownEvents.append(event)
            return true
        }

        window.makeKeyAndOrderFront(nil)
        defer {
            breeUnitTestBreeWebViewKeyDownHook = nil
            window.orderOut(nil)
            uninstallBreeUnitTestBreeWebViewKeyDownOverride()
        }

        #expect(window.makeFirstResponder(webView))
        try body(window, { keyDownEvents })
    }

    private func installUndoMenu(target: NSObject) -> NSMenu? {
        let previousMenu = NSApp.mainMenu
        let mainMenu = NSMenu()
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        let undoItem = NSMenuItem(
            title: "Undo",
            action: #selector(BrowserUndoMenuActionSpy.didInvoke(_:)),
            keyEquivalent: "z"
        )
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = target
        editMenu.addItem(undoItem)
        mainMenu.addItem(editItem)
        mainMenu.setSubmenu(editMenu, for: editItem)
        _ = NSApplication.shared
        NSApp.mainMenu = mainMenu
        return previousMenu
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags,
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }
}
