import Foundation
import Testing
@testable import BreeBrowser

@Suite struct BrowserHistoryLocationTests {
    @Test func foldsDebugAndStagingNamespaces() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.bree.app.debug.my-tag") == "com.bree.app.debug")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.bree.app.staging.rc") == "com.bree.app.staging")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.bree.app") == "com.bree.app")
    }

    @Test func breeDevNamespaceIsNotTheBreeDebugNamespace() {
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.bree.app.debug.bree") == "com.bree.app.debug.bree")
        #expect(BrowserHistoryLocation.normalizedNamespace(bundleIdentifier: "com.bree.app") == "com.bree.app")
    }

    @Test func historyFileURLNestsUnderNamespace() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let location = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.bree.app.debug.tag")
        #expect(location.namespace == "com.bree.app.debug")
        #expect(location.historyFileURL.path == "/tmp/appsupport/com.bree.app.debug/browser_history.json")
    }

    @Test func legacyURLPresentOnlyWhenNamespaceDiffers() {
        let root = URL(fileURLWithPath: "/tmp/appsupport", isDirectory: true)
        let tagged = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.bree.app.debug.tag")
        #expect(tagged.legacyTaggedHistoryFileURL?.path == "/tmp/appsupport/com.bree.app.debug.tag/browser_history.json")

        let prod = BrowserHistoryLocation(applicationSupportDirectory: root, bundleIdentifier: "com.bree.app")
        #expect(prod.legacyTaggedHistoryFileURL == nil)
    }
}
