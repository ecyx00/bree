import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class RightSidebarArchitectureWidthTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "RightSidebarArchitectureWidthTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testArchitectureDefaultsToWideAndOtherModesKeepSharedDefault() {
        XCTAssertEqual(FileExplorerState.persistedWidth(for: .architecture, defaults: defaults), 520)
        XCTAssertEqual(FileExplorerState.persistedWidth(for: .files, defaults: defaults), 220)
        XCTAssertEqual(FileExplorerState.persistedWidth(for: .sessions, defaults: defaults), 220)
    }

    // Architecture is a popup, not a sidebar mode (FileExplorerState.setMode ignores it),
    // so selecting it never changes the mode, width or stored keys.
    func testSelectingArchitectureIsIgnoredAndWidthStaysShared() {
        let state = FileExplorerState(defaults: defaults)
        state.mode = .files
        state.width = 300

        state.mode = .architecture
        XCTAssertEqual(state.mode, .files)
        XCTAssertEqual(state.width, 300)
        XCTAssertNil(defaults.object(forKey: "fileExplorer.width.architecture"))
        XCTAssertEqual(defaults.double(forKey: "fileExplorer.width"), 300)
    }

    func testWidthSurvivesRelaunch() {
        let first = FileExplorerState(defaults: defaults)
        first.mode = .files
        first.width = 280

        let relaunched = FileExplorerState(defaults: defaults)
        XCTAssertEqual(relaunched.mode, .files)
        XCTAssertEqual(relaunched.width, 280)
    }

    func testArchitectureModeParsesButStoredArchitectureFallsBackToFiles() {
        XCTAssertEqual(RightSidebarMode(rawValue: "architecture"), .architecture)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Architecture "), .architecture)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "not-a-mode"))

        defaults.set("not-a-mode", forKey: "rightSidebar.mode")
        XCTAssertEqual(FileExplorerState(defaults: defaults).mode, .files)

        defaults.set("architecture", forKey: "rightSidebar.mode")
        XCTAssertEqual(FileExplorerState(defaults: defaults).mode, .files)
    }

    func testUnknownEntriesInTabOrderAreIgnoredAndArchitectureIsAppended() {
        defaults.set(["activity", "removed-mode", "files"], forKey: RightSidebarTabPreferences.orderKey)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.activity, .files, .sessions, .architecture]
        )
    }
}
