public import AppKit
public import WebKit

extension WKWebView {
    public func breeOwnsKeyEvent(_ event: NSEvent) -> Bool {
        guard let eventWindow = event.window ?? window,
              eventWindow === window,
              let responder = eventWindow.firstResponder else { return false }
        if responder === self { return true }
        return (responder as? NSView)?.isDescendant(of: self) == true
    }

    nonisolated private static var breeSetPageMutedSelector: Selector {
        NSSelectorFromString("_setPageMuted:")
    }

    nonisolated private static var breeMediaMutedStateAudio: Int {
        1 << 0
    }

    @discardableResult
    public func breeSetPageAudioMuted(_ muted: Bool) -> Bool {
        let selector = Self.breeSetPageMutedSelector
        guard responds(to: selector),
              let implementation = method(for: selector) else {
            return false
        }

        typealias SetPageMutedFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        let function = unsafeBitCast(implementation, to: SetPageMutedFunction.self)
        function(self, selector, muted ? Self.breeMediaMutedStateAudio : 0)
        return true
    }

    /// Whether the page is capturing the camera, microphone, a display or
    /// system audio, counting muted capture as capture.
    public var breeIsCapturingMedia: Bool {
        cameraCaptureState != .none
            || microphoneCaptureState != .none
            || breeCaptureState(selectorName: "_displayCaptureState")
            || breeCaptureState(selectorName: "_systemAudioCaptureState")
    }

    /// Reads a capture state WebKit exposes only as SPI, such as the display
    /// capture behind screen sharing. Zero means none.
    private func breeCaptureState(selectorName: String) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        guard responds(to: selector),
              let implementation = method(for: selector) else {
            return true
        }

        typealias CaptureStateFunction = @convention(c) (AnyObject, Selector) -> Int
        let function = unsafeBitCast(implementation, to: CaptureStateFunction.self)
        return function(self, selector) != 0
    }

    public var breeIsElementFullscreenActiveOrTransitioning: Bool {
        switch fullscreenState {
        case .notInFullscreen:
            return false
        case .enteringFullscreen, .inFullscreen, .exitingFullscreen:
            return true
        @unknown default:
            return true
        }
    }

    public func breeIsManagedByExternalFullscreenWindow(relativeTo expectedWindow: NSWindow?) -> Bool {
        guard breeIsElementFullscreenActiveOrTransitioning else { return false }
        guard let expectedWindow else { return true }
        return window !== expectedWindow
    }
}
