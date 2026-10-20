import AppKit
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
final class QuickViewWindowSpaceTests: XCTestCase {
    func testQuickViewWindowCanJoinNativeFullScreenSpace() {
        let window = QuickViewWindowController().makeWindow()
        defer { window.close() }
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }
}
