import Foundation
import Testing
@testable import BreeSidebar

@Suite struct SidebarWireValueTests {
    /// Raw values arrive over the control socket; round-trips are frozen.
    @Test func metadataFormatRawValuesRoundTrip() {
        #expect(SidebarMetadataFormat(rawValue: "plain") == .plain)
        #expect(SidebarMetadataFormat(rawValue: "markdown") == .markdown)
        #expect(SidebarMetadataFormat(rawValue: "html") == nil)
    }

    @Test func logLevelRawValuesRoundTrip() {
        for (raw, level) in [("info", SidebarLogLevel.info), ("progress", .progress),
                             ("success", .success), ("warning", .warning), ("error", .error)] {
            #expect(SidebarLogLevel(rawValue: raw) == level)
            #expect(level.rawValue == raw)
        }
    }
}

@Suite struct SidebarBranchNameNormalizationTests {
    /// Parity with the legacy `normalizedSidebarBranchName(_:)` helper.
    @Test func trimsWhitespaceAndDropsEmpty() {
        #expect("  main \n".normalizedSidebarBranchName == "main")
        #expect("main".normalizedSidebarBranchName == "main")
        #expect("   ".normalizedSidebarBranchName == nil)
        #expect("".normalizedSidebarBranchName == nil)
        let none: String? = nil
        #expect(none?.normalizedSidebarBranchName == nil)
    }
}
