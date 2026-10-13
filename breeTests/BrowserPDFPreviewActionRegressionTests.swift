import Foundation
import Testing
import WebKit

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite
struct BrowserPDFPreviewActionRegressionTests {
    @Test func browserPanelUIDelegateRespondsToPDFPreviewDownloadSelector() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? NSObject)
        let selector = NSSelectorFromString("_webView:saveDataToFile:suggestedFilename:mimeType:originatingURL:")

        #expect(
            delegate.responds(to: selector),
            "WebKit checks this exact selector before delivering the PDF HUD download click; when the delegate does not respond, the button does nothing."
        )
    }

    @Test func browserPanelUIDelegateRespondsToPDFPreviewPrintSelector() throws {
        let panel = BrowserPanel(workspaceId: UUID())
        let delegate = try #require(panel.webView.uiDelegate as? NSObject)
        let selector = NSSelectorFromString("_webView:printFrame:pdfFirstPageSize:completionHandler:")

        #expect(
            delegate.responds(to: selector),
            "WebKit checks this exact selector before delivering the PDF HUD print click; when the delegate does not respond, the button does nothing."
        )
    }
}
