public import AppKit
public import ObjectiveC.runtime
public import WebKit

private final class BrowserViewportWeakHostBox: NSObject {
    weak var value: BrowserViewportHostView?
}

private enum BrowserViewportAssociatedKeys {
    nonisolated(unsafe) static var host: UInt8 = 0
    nonisolated(unsafe) static var externalRenderHostDepth: UInt8 = 0
}

extension WKWebView {
    public var breeBrowserViewportHostView: BrowserViewportHostView? {
        get {
            (objc_getAssociatedObject(self, &BrowserViewportAssociatedKeys.host)
                as? BrowserViewportWeakHostBox)?.value
        }
        set {
            if let box = objc_getAssociatedObject(
                self,
                &BrowserViewportAssociatedKeys.host
            ) as? BrowserViewportWeakHostBox {
                box.value = newValue
            } else {
                let box = BrowserViewportWeakHostBox()
                box.value = newValue
                objc_setAssociatedObject(
                    self,
                    &BrowserViewportAssociatedKeys.host,
                    box,
                    .OBJC_ASSOCIATION_RETAIN_NONATOMIC
                )
            }
        }
    }

    public var breeBrowserViewportUsesHost: Bool {
        guard let host = breeBrowserViewportHostView else { return false }
        return superview === host
    }

    public var breeBrowserViewportPresentationView: NSView {
        guard breeBrowserViewportUsesHost, let host = breeBrowserViewportHostView else {
            return self
        }
        return host
    }

    public var breeBrowserViewportAttachmentSuperview: NSView? {
        breeBrowserViewportPresentationView.superview
    }

    public var breeBrowserViewportAttachmentWindow: NSWindow? {
        breeBrowserViewportPresentationView.window ?? window
    }

    public var breeBrowserViewportExternalRenderHostIsActive: Bool {
        ((objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0) > 0
    }

    func breeBeginBrowserViewportExternalRenderHost() {
        let depth = (objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0
        objc_setAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth,
            NSNumber(value: depth + 1),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func breeEndBrowserViewportExternalRenderHost() {
        let depth = (objc_getAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth
        ) as? NSNumber)?.intValue ?? 0
        let nextDepth = max(0, depth - 1)
        objc_setAssociatedObject(
            self,
            &BrowserViewportAssociatedKeys.externalRenderHostDepth,
            nextDepth > 0 ? NSNumber(value: nextDepth) : nil,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    public func breeIsManagedByExternalRenderHost(relativeTo expectedSuperview: NSView?) -> Bool {
        breeBrowserViewportExternalRenderHostIsActive &&
            breeBrowserViewportPresentationView.superview !== expectedSuperview
    }

    public var breeBrowserViewportContainerBounds: CGRect? {
        breeBrowserViewportAttachmentSuperview?.bounds
    }

    var breeBrowserViewportLayoutMode: BrowserViewportLayout.Mode {
        (self as? BreeWebView)?.browserViewportModel?.viewport == nil ? .native : .emulated
    }

    var breeBrowserViewportAutoresizingMask: NSView.AutoresizingMask {
        breeBrowserViewportLayoutMode == .native ? [.width, .height] : []
    }

    public func breeBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        BrowserViewportLayout(
            containerBounds: containerBounds,
            viewport: (self as? BreeWebView)?.browserViewportModel?.viewport,
            pageZoom: Double(pageZoom)
        )
    }

    public func breeBrowserViewportLayoutMatches(_ containerBounds: CGRect, epsilon: Double = 0.5) -> Bool {
        guard let layout = breeBrowserViewportLayout(in: containerBounds) else {
            return false
        }
        if breeBrowserViewportUsesHost, let host = breeBrowserViewportHostView {
            return host.matches(layout, epsilon: epsilon)
        }
        return Self.breeBrowserViewportRect(frame, matches: layout.frame, epsilon: epsilon) &&
            Self.breeBrowserViewportRect(bounds, matches: layout.webViewBounds, epsilon: epsilon) &&
            autoresizingMask == breeBrowserViewportAutoresizingMask
    }

    @discardableResult
    public func breeApplyBrowserViewportLayout(in containerBounds: CGRect) -> BrowserViewportLayout? {
        guard let layout = breeBrowserViewportLayout(in: containerBounds) else {
            return nil
        }
        breeApplyBrowserViewportLayout(layout)
        return layout
    }

    public func breeApplyBrowserViewportLayout(_ layout: BrowserViewportLayout) {
        if breeBrowserViewportUsesHost, let host = breeBrowserViewportHostView {
            host.apply(layout)
            return
        }
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = breeBrowserViewportAutoresizingMask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Self.breeBrowserViewportRect(frame, matches: layout.frame) {
            frame = layout.frame
        }
        if !Self.breeBrowserViewportRect(bounds, matches: layout.webViewBounds) {
            bounds = layout.webViewBounds
        }
        CATransaction.commit()
    }

    func breeApplyRawBrowserViewportGeometry(_ rawBounds: CGRect) {
        translatesAutoresizingMaskIntoConstraints = true
        autoresizingMask = breeBrowserViewportAutoresizingMask

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if !Self.breeBrowserViewportRect(frame, matches: rawBounds) {
            frame = rawBounds
        }
        if !Self.breeBrowserViewportRect(bounds, matches: rawBounds) {
            bounds = rawBounds
        }
        CATransaction.commit()
    }

    @discardableResult
    public func breeRestoreIntoBrowserViewportHostIfNeeded() -> Bool {
        breeBrowserViewportHostView?.restoreWebViewIfNeeded() ?? false
    }

    @discardableResult
    public func breeRestoreIntoBrowserViewportHostAfterExternalGeometryIfSafe() -> Bool {
        breeBrowserViewportHostView?.restoreWebViewAfterExternalGeometryIfSafe() ?? false
    }

    private static func breeBrowserViewportRect(
        _ lhs: CGRect,
        matches rhs: CGRect,
        epsilon: Double = 0.5
    ) -> Bool {
        abs(lhs.minX - rhs.minX) <= epsilon &&
            abs(lhs.minY - rhs.minY) <= epsilon &&
            abs(lhs.width - rhs.width) <= epsilon &&
            abs(lhs.height - rhs.height) <= epsilon
    }
}
