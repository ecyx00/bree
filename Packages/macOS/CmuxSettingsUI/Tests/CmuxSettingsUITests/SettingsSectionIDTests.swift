import Testing
@testable import CmuxSettingsUI

@Suite("SettingsSectionID")
struct SettingsSectionIDTests {
    @Test func everyCaseHasNonEmptyTitleAndSymbol() {
        for section in SettingsSectionID.allCases {
            #expect(!section.title.isEmpty)
            #expect(!section.symbolName.isEmpty)
        }
    }

    @Test func titlesAreUnique() {
        let titles = SettingsSectionID.allCases.map(\.title)
        #expect(titles.count == Set(titles).count)
    }

    @Test(arguments: SettingsSectionID.allCases)
    func missingAnchorLandsOnTheRequestedSectionHeader(section: SettingsSectionID) {
        let destination = section.navigationDestination(providedAnchor: nil)
        #expect(destination.section == section)
        #expect(destination.anchorID == "section:\(section.rawValue)")
    }

    @Test(arguments: [
        (SettingsSectionID.advanced, "setting:advanced:remoteTmux"),
        (.advanced, "section:advanced")
    ])
    func rowAnchorsArePreserved(section: SettingsSectionID, anchor: String) {
        let destination = section.navigationDestination(providedAnchor: anchor)
        #expect(destination.section == section)
        #expect(destination.anchorID == anchor)
    }

    @Test func notificationUserInfoResolvesTargetAndAnchor() throws {
        let destination = try #require(SettingsSectionID.navigationDestination(userInfo: ["target": "advanced", "anchor": "setting:advanced:remoteTmux"]))
        #expect(destination.section == .advanced)
        #expect(destination.anchorID == "setting:advanced:remoteTmux")
        #expect(SettingsSectionID.navigationDestination(userInfo: ["target": "notASection"]) == nil)
        #expect(SettingsSectionID.navigationDestination(userInfo: nil) == nil)
    }
}
