import AppKit
import BreeBrowser
import WebKit

extension BrowserPanel {
    /// Releases every app-owned attachment before a web view is replaced or closed.
    func tearDownWebViewBeforeReplacement(_ oldWebView: WKWebView, reason: String) {
        guard oldWebView === webView else { return }

        if let window = oldWebView.window,
           Self.responderChainContains(window.firstResponder, target: oldWebView) {
            window.makeFirstResponder(nil)
        }

        clearBrowserFocusMode(reason: reason)
        invalidateSearchFocusRequests(reason: reason)
        detachWebViewObservers()
        tearDownReactGrabMessageHandler(for: oldWebView, reason: reason)
        tearDownMediaPlaybackMessageHandler(for: oldWebView)
        tearDownPageRestoration(for: oldWebView)
        designModeController.webViewWillBeRemoved(oldWebView)
        webAuthnCoordinator.tearDown(from: oldWebView)
        oldWebView.configuration.userContentController.removeScriptMessageHandler(
            forName: BrowserSSLTrustBypassMessageHandler.name
        )
        sslTrustBypassMessageHandler = nil

        BrowserWindowPortalRegistry.detach(webView: oldWebView)
        oldWebView.stopLoading()
        oldWebView.navigationDelegate = nil
        oldWebView.uiDelegate = nil
        oldWebView.breeBrowserViewportHostView = nil

        if let oldBreeWebView = oldWebView as? BreeWebView {
            oldBreeWebView.breeDownloadDelegate = nil
            oldBreeWebView.clearBrowserDownloadCallbacks()
            oldBreeWebView.browserViewportModel = nil
            oldBreeWebView.onBrowserViewportHierarchyChanged = nil
            oldBreeWebView.onMouseBackButton = nil
            oldBreeWebView.onMouseForwardButton = nil
            oldBreeWebView.onContextMenuDownloadStateChanged = nil
            oldBreeWebView.onSessionDownloadEvent = nil
            oldBreeWebView.onScreenshotCopied = nil
            oldBreeWebView.onContextMenuOpenLinkInNewTab = nil
            oldBreeWebView.contextMenuLinkURLProvider = nil
            oldBreeWebView.contextMenuCanMoveTabToNewWorkspace = nil
            oldBreeWebView.contextMenuMoveTabToNewWorkspace = nil
            oldBreeWebView.onSubframeDownloadIntent = nil
        }
        oldWebView.removeFromSuperview()
    }
}
