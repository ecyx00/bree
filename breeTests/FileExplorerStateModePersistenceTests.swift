import Foundation
import XCTest
import BreeSettings

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class FileExplorerStateModePersistenceTests: XCTestCase {
    private let modeKey = "rightSidebar.mode"
    private let customSidebarNameKey = "rightSidebar.customSidebarName"
    private let legacyDockBetaKey = "rightSidebar.beta.dock.enabled"

    func testStoredLegacyFindModeMapsToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set("find", forKey: modeKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
        }
    }

    func testStoredLegacyDockModeFallsBackToFiles() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            defaults.set("dock", forKey: modeKey)
            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
        }
    }

    func testStoredCustomSidebarModeFallsBackToFilesWhenBetaDisabled() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
            let previous = defaults.object(forKey: customSidebarsKey)
            defaults.set(false, forKey: customSidebarsKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: customSidebarsKey)
                } else {
                    defaults.removeObject(forKey: customSidebarsKey)
                }
            }
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .files)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.files.rawValue)
        }
    }

    func testStoredCustomSidebarModePersistsWhenAvailable() {
        withSavedRightSidebarModeDefaults {
            let defaults = UserDefaults.standard
            let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
            let previous = defaults.object(forKey: customSidebarsKey)
            defaults.set(true, forKey: customSidebarsKey)
            defer {
                if let previous {
                    defaults.set(previous, forKey: customSidebarsKey)
                } else {
                    defaults.removeObject(forKey: customSidebarsKey)
                }
            }
            defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
            defaults.set("status-board", forKey: customSidebarNameKey)

            let state = FileExplorerState()

            XCTAssertEqual(state.mode, .customSidebar)
            XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.customSidebar.rawValue)
        }
    }

    func testInjectedDefaultsOwnCustomSidebarAvailabilityAndPersistence() throws {
        let suiteName = "FileExplorerStateModePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let customSidebarsKey = BetaFeaturesCatalogSection().customSidebars.userDefaultsKey
        defaults.set(true, forKey: customSidebarsKey)
        defaults.set(RightSidebarMode.customSidebar.rawValue, forKey: modeKey)
        defaults.set("status-board", forKey: customSidebarNameKey)

        let state = FileExplorerState(defaults: defaults)

        XCTAssertEqual(state.mode, .customSidebar)
        XCTAssertTrue(RightSidebarMode.availableModes(defaults: defaults).contains(.customSidebar))
        state.selectCustomSidebar(name: "next-board")
        state.mode = .customSidebar
        XCTAssertEqual(state.customSidebarName, "next-board")
        XCTAssertEqual(defaults.string(forKey: customSidebarNameKey), "next-board")
        XCTAssertEqual(defaults.string(forKey: modeKey), RightSidebarMode.customSidebar.rawValue)
    }

    func testCLIArgumentNormalizerMapsVaultAndSessionsToSessions() {
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "files"), .files)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "find"), .files)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "vault"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "sessions"), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "activity"), .activity)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "feed"))
        XCTAssertNil(RightSidebarMode.from(cliArgument: "dock"))
        XCTAssertEqual(RightSidebarMode.from(cliArgument: " Vault "), .sessions)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "custom-sidebar"), .customSidebar)
        XCTAssertEqual(RightSidebarMode.from(cliArgument: "custom"), .customSidebar)
        XCTAssertNil(RightSidebarMode.from(cliArgument: "unknown"))
    }

    private func withSavedRightSidebarModeDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previousMode = defaults.object(forKey: modeKey)
        let previousCustomSidebarName = defaults.object(forKey: customSidebarNameKey)
        let previousLegacyDockBeta = defaults.object(forKey: legacyDockBetaKey)
        defer {
            restore(previousMode, forKey: modeKey)
            restore(previousCustomSidebarName, forKey: customSidebarNameKey)
            restore(previousLegacyDockBeta, forKey: legacyDockBetaKey)
        }
        body()
    }

    private func restore(_ value: Any?, forKey key: String) {
        let defaults = UserDefaults.standard
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
