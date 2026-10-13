import XCTest
import BreeSettings
@testable import BreeSettingsUI

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

private typealias ShortcutStroke = BreeSettings.ShortcutStroke

final class KeyboardShortcutSavedLayoutTemplateTests: XCTestCase {
    func testSaveLayoutTemplateSettingsPackageActionStaysAligned() {
        guard let settingsAction = ShortcutAction(
            rawValue: KeyboardShortcutSettings.Action.saveLayoutTemplate.rawValue
        ) else {
            XCTFail("Expected BreeSettings.ShortcutAction for saveLayoutTemplate")
            return
        }
        XCTAssertEqual(settingsAction.defaultStroke, ShortcutStroke(key: "s", command: true, control: true))
        XCTAssertEqual(settingsAction.displayName, KeyboardShortcutSettings.Action.saveLayoutTemplate.label)
    }
}
