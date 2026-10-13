import SwiftUI
import Testing
@testable import BreeSettingsUI

/// Progressive section mounting for the settings window
/// (https://github.com/ecyx00/bree/issues/12134): one section in the
/// first pass, one more per appearance, navigation mounts on demand.
@MainActor
@Suite("SettingsSectionMountModel")
struct SettingsSectionMountModelTests {
    private let order: [SettingsSectionID] = [.themes, .app, .terminal, .browser, .reset]

    @Test func displayOrderGivesEveryHostASlotAndHostedSectionsNone() {
        let slots = Set(SettingsSectionMountModel.displayOrder)
        #expect(slots.count == SettingsSectionMountModel.displayOrder.count)
        for section in SettingsSectionID.allCases {
            #expect(slots.contains(SettingsSectionMountModel.hostSection(for: section)))
        }
        #expect(SettingsSectionMountModel.hostSection(for: .globalHotkey) == .app)
        #expect(SettingsSectionMountModel.hostSection(for: .settingsJSON) == .advanced)
        #expect(SettingsSectionMountModel.hostSection(for: .advanced) == .advanced)
    }

    @Test func firstPassMountsOnlyTheInitialSection() {
        let model = SettingsSectionMountModel(initial: .terminal, order: order)
        #expect(model.mounted == [.terminal])
        #expect(model.isMounted(.terminal))
        #expect(!model.isMounted(.themes))
        #expect(!model.isComplete)
    }

    @Test func eachAppearanceMountsExactlyOneMoreSectionInDisplayOrder() {
        let model = SettingsSectionMountModel(initial: .terminal, order: order)
        var mountedInOrder: [SettingsSectionID] = []
        var current: SettingsSectionID? = .terminal
        while let section = current {
            current = model.sectionDidAppear(section)
            if let current { mountedInOrder.append(current) }
        }
        #expect(mountedInOrder == [.themes, .app, .browser, .reset])
        #expect(model.isComplete)
        #expect(model.mounted == Set(order))
        #expect(model.sectionDidAppear(.reset) == nil)
    }

    @Test func appearanceOfASectionThatIsNotTheChainHeadDoesNotAdvance() {
        let model = SettingsSectionMountModel(initial: .themes, order: order)
        // Navigation mounts .browser out of band; its appearance must not
        // start a second chain (two sections per turn).
        #expect(model.ensureMounted(.browser) == false)
        #expect(model.sectionDidAppear(.browser) == nil)
        #expect(model.mounted == [.themes, .browser])
        #expect(model.sectionDidAppear(.themes) == .app)
        #expect(model.sectionDidAppear(.app) == .terminal)
        // .browser is already mounted, so the chain skips it.
        #expect(model.sectionDidAppear(.terminal) == .reset)
        // Everything is mounted, but the last mount is still under
        // construction until it appears.
        #expect(!model.isComplete)
        #expect(model.sectionDidAppear(.reset) == nil)
        #expect(model.isComplete)
    }

    @Test func ensureMountedReportsAlreadyMountedSections() {
        let model = SettingsSectionMountModel(initial: .themes, order: order)
        #expect(model.ensureMounted(.themes))
        #expect(model.ensureMounted(.browser) == false)
        #expect(model.ensureMounted(.browser))
    }

    @Test func browserImportResolvesToTheBrowserSlot() {
        let model = SettingsSectionMountModel(initial: .browserImport, order: order)
        #expect(model.mounted == [.browser])
        #expect(model.isMounted(.browserImport))
        #expect(model.ensureMounted(.browserImport))
    }

    @Test func sectionsOutsideTheOrderCountAsMounted() {
        let model = SettingsSectionMountModel(initial: .themes, order: [.themes, .app])
        #expect(model.isMounted(.cloudMachines))
        #expect(model.ensureMounted(.cloudMachines))
        #expect(model.mounted == [.themes])
    }

    @Test func initialSectionOutsideTheOrderFallsBackToTheFirstSlot() {
        let model = SettingsSectionMountModel(initial: .cloudMachines, order: [.themes, .app])
        #expect(model.mounted == [.themes])
        #expect(model.sectionDidAppear(.themes) == .app)
    }

    @Test func completionWaitsForTheFinalSectionToAppear() {
        let model = SettingsSectionMountModel(initial: .themes, order: [.themes, .app])
        #expect(!model.isComplete)
        #expect(model.sectionDidAppear(.themes) == .app)
        #expect(model.mounted == Set([.themes, .app]))
        #expect(!model.isComplete, "the App section is mounted but has not appeared yet")
        #expect(model.sectionDidAppear(.app) == nil)
        #expect(model.isComplete)
    }

    @Test func deferredScrollIsOwedToItsSectionOnly() {
        let model = SettingsSectionMountModel(initial: .themes, order: order)
        let target = SettingsSectionScrollTarget(
            section: .browserImport, anchorID: "section:browserImport", anchor: .top, generation: 3
        )
        model.deferScroll(target)
        #expect(model.takeDeferredScroll(for: .app) == nil)
        #expect(model.takeDeferredScroll(for: .browser) == target)
        #expect(model.takeDeferredScroll(for: .browser) == nil)
        model.deferScroll(target)
        model.cancelDeferredScroll()
        #expect(model.deferredScroll == nil)
    }

    @Test func pinnedScrollTracksTheLatestNavigation() {
        let model = SettingsSectionMountModel(initial: .themes, order: order)
        let first = SettingsSectionScrollTarget(section: .reset, anchorID: "section:reset", anchor: .top, generation: 1)
        let second = SettingsSectionScrollTarget(section: .app, anchorID: "row:app", anchor: .center, generation: 2)
        model.pin(first)
        model.pin(second)
        #expect(model.pinnedScroll == second)
    }
}
