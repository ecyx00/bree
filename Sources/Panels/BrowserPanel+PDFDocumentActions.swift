import AppKit
import BreeBrowser
import Foundation

extension BrowserPanel {
    func downloadRenderedPDFDocument() {
        guard let url = renderedPDFDocumentURL else {
            NSSound.beep()
            return
        }
        guard let webView = webView as? BreeWebView else {
            NSSound.beep()
            return
        }
        let traceID = BreeWebView.makeContextDownloadTraceID(prefix: "pdfdl")
        webView.downloadURLViaSession(
            url,
            suggestedFilename: nil,
            sender: nil,
            fallbackAction: nil,
            fallbackTarget: nil,
            traceID: traceID
        )
    }

    func printRenderedPDFDocument() {
        guard renderedPDFDocumentURL != nil else {
            NSSound.beep()
            return
        }
        webView.breeRunPrintOperation()
    }
}
