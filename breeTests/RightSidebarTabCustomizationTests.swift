import BreeSidebar
import Foundation
import BreeSidebar
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Behavior of the customizable right-sidebar tabs: user-defined order and
/// visibility, and the positional `ctrl+digit` shortcut defaults that follow
/// the visible order (the Nth visible tab answers ctrl+N).
@MainActor
final class RightSidebarTabCustomizationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var savedCloudRemoteOverride: Bool?

    override func setUp() {
        super.setUp()
        suiteName = "RightSidebarTabCustomizationTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        let flag = BreeFeatureFlags.cloudMachinesFlag
        savedCloudRemoteOverride = BreeFeatureFlags.shared.overrideValue(for: flag)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        BreeFeatureFlags.shared.setOverride(savedCloudRemoteOverride, for: BreeFeatureFlags.cloudMachinesFlag)
        savedCloudRemoteOverride = nil
        defaults = nil
        super.tearDown()
    }

    private func enableAllModeGates() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
        // An explicit empty hidden set shows every tab.
        defaults.set([String](), forKey: RightSidebarTabPreferences.hiddenKey)
    }

    private func enableMachinesGate() {
        defaults.set(true, forKey: RightSidebarBetaFeatureSettings.cloudMachinesEnabledKey)
    }

    // MARK: - Ordering and visibility

    func testDefaultOrderIsCanonical() {
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .sessions, .activity, .architecture]
        )
    }

    func testNoTabIsHiddenByDefault() {
        XCTAssertEqual(RightSidebarTabPreferences.hiddenModes(defaults: defaults), [])
        XCTAssertEqual(RightSidebarMode.visibleModes(defaults: defaults), [.files, .sessions, .activity, .architecture])
    }

    func testStoredOrderIgnoresUnknownEntriesAndAppendsMissingModes() {
        defaults.set(["activity", "bogus", "files", "custom-sidebar"], forKey: RightSidebarTabPreferences.orderKey)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.activity, .files, .sessions, .architecture]
        )
    }

    func testVisibleModesDropUserHiddenTabs() {
        BreeFeatureFlags.shared.setOverride(true, for: BreeFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults))
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .activity, .architecture]
        )
    }

    func testHidingLastVisibleTabIsRefused() {
        // Hide every tab except Sessions through the regular tab-visibility control.
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .files, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .activity, defaults: defaults))
        XCTAssertTrue(RightSidebarTabPreferences.setHidden(true, mode: .architecture, defaults: defaults))
        XCTAssertFalse(
            RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults),
            "the last visible tab must stay visible"
        )
        XCTAssertEqual(RightSidebarMode.visibleModes(defaults: defaults), [.sessions])
    }

    func testMoveReordersAndClampsAtEdges() {
        RightSidebarTabPreferences.move(.activity, offset: -5, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.activity, .files, .sessions, .architecture]
        )
        RightSidebarTabPreferences.move(.activity, offset: -1, defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults).first,
            .activity,
            "moving past the front clamps"
        )
    }

    func testSetDisplayedOrderPermutesOnlyTheDisplayedSlots() {
        // Hide Sessions; it keeps its slot in the full order. Dragging Activity
        // before Files must not move Sessions.
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults)
        RightSidebarTabPreferences.setDisplayedOrder(
            [.activity, .files, .architecture],
            defaults: defaults
        )
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.activity, .sessions, .files, .architecture],
            "hidden Sessions keeps its 2nd slot while the displayed tabs permute around it"
        )
    }

    /// Four tabs: 40, 60, 40, 50 wide, 4pt apart, from x = 0.
    private func modeBarFrames() -> [CGRect] {
        var x: CGFloat = 0
        return [40, 60, 40, 50].map { width in
            defer { x += width + 4 }
            return CGRect(x: x, y: 0, width: width, height: 24)
        }
    }

    func testModeBarDragLayoutAtRestMovesNothing() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 1))
        XCTAssertEqual(layout.slot(translation: 0), 1)
        XCTAssertEqual(layout.draggedOffset(translation: 0), 0)
        XCTAssertEqual(layout.offsets(slot: 1), [0, 0, 0, 0])
        XCTAssertEqual(layout.reordered(["a", "b", "c", "d"], slot: 1), ["a", "b", "c", "d"])
    }

    func testModeBarDragLayoutNeighbourGivesWayAtHalfTheNarrowerTab() throws {
        // Dragging the 60pt tab right over the 40pt one: it moves once 20pt is covered.
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 1))
        XCTAssertEqual(layout.slot(translation: 23), 1, "covers 19pt of the 40pt neighbour")
        XCTAssertEqual(layout.slot(translation: 25), 2, "covers 21pt")
        let offsets = layout.offsets(slot: 2)
        XCTAssertEqual(offsets[2], -64, "the neighbour shifts left by the dragged tab plus a gap")
        XCTAssertEqual(offsets[1], 44, "the dragged tab would land after the neighbour")
        XCTAssertEqual(offsets[0], 0)
        XCTAssertEqual(offsets[3], 0)
        XCTAssertEqual(layout.draggedOffset(translation: 25), 25, "the tab stays under the pointer")
        XCTAssertEqual(
            layout.reordered([RightSidebarMode.files, .activity, .sessions, .customSidebar], slot: 2),
            [.files, .sessions, .activity, .customSidebar]
        )
    }

    func testModeBarDragLayoutDraggingLeftShiftsTheTabsBefore() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 3))
        XCTAssertEqual(layout.slot(translation: -200), 0)
        let offsets = layout.offsets(slot: 0)
        XCTAssertEqual(offsets[3], -152, "the last tab lands at the bar's start")
        XCTAssertEqual(offsets[0], 54)
        XCTAssertEqual(offsets[1], 54)
        XCTAssertEqual(offsets[2], 54)
    }

    func testModeBarDragLayoutResistsPastTheBarEnds() throws {
        let layout = try XCTUnwrap(RightSidebarModeBarDragLayout(frames: modeBarFrames(), source: 0))
        let left = layout.draggedOffset(translation: -100)
        XCTAssertLessThan(left, 0)
        XCTAssertGreaterThan(left, -RightSidebarModeBarDragLayout.overscrollLimit)
        let right = layout.draggedOffset(translation: 1000)
        XCTAssertGreaterThan(right, 162, "held at the bar's end (162pt) plus some give")
        XCTAssertLessThan(right, 162 + RightSidebarModeBarDragLayout.overscrollLimit)
        XCTAssertEqual(layout.slot(translation: 1000), 3)
    }

    func testModeBarDragLayoutLeavesTheBarOnlyWellOutsideIt() {
        let tab = CGRect(x: 0, y: 7, width: 40, height: 24)
        XCTAssertFalse(RightSidebarModeBarDragLayout.leavesBar(pointerY: 40, tabFrame: tab, barHeight: 38))
        XCTAssertTrue(RightSidebarModeBarDragLayout.leavesBar(pointerY: 51, tabFrame: tab, barHeight: 38))
        XCTAssertTrue(RightSidebarModeBarDragLayout.leavesBar(pointerY: -13, tabFrame: tab, barHeight: 38))
        XCTAssertNil(RightSidebarModeBarDragLayout(frames: [], source: 0))
    }

    func testResetRestoresCanonicalOrderAndVisibility() {
        RightSidebarTabPreferences.move(.activity, offset: -5, defaults: defaults)
        RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults)
        RightSidebarTabPreferences.resetToDefaults(defaults: defaults)
        XCTAssertEqual(
            RightSidebarTabPreferences.orderedModes(defaults: defaults),
            [.files, .sessions, .activity, .architecture]
        )
        XCTAssertEqual(RightSidebarTabPreferences.hiddenModes(defaults: defaults), [])
    }

    // MARK: - Positional shortcut defaults

    /// Activity is the 3rd visible tab, so ctrl+3 must focus it.
    func testActivityDefaultsToControlThree() {
        XCTAssertEqual(
            RightSidebarMode.visibleModes(defaults: defaults),
            [.files, .sessions, .activity, .architecture]
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .activity, defaults: defaults),
            StoredShortcut(key: "3", command: false, shift: false, option: false, control: true)
        )
    }

    func testAllTabsVisibleKeepsHistoricDigits() {
        BreeFeatureFlags.shared.setOverride(true, for: BreeFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        let expected: [(RightSidebarMode, String)] = [
            (.files, "1"), (.sessions, "2"), (.activity, "3"),
        ]
        for (mode, digit) in expected {
            XCTAssertEqual(
                KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: mode, defaults: defaults),
                StoredShortcut(key: digit, command: false, shift: false, option: false, control: true),
                "\(mode) should default to ctrl+\(digit)"
            )
        }
    }

    func testHiddenTabDefaultsToUnboundAndLaterDigitsShift() {
        BreeFeatureFlags.shared.setOverride(true, for: BreeFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .sessions, defaults: defaults),
            .unbound
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .activity, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testReorderMovesDigitsWithTheTabs() {
        BreeFeatureFlags.shared.setOverride(true, for: BreeFeatureFlags.cloudMachinesFlag)
        enableAllModeGates()
        RightSidebarTabPreferences.move(.activity, offset: -5, defaults: defaults)
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .activity, defaults: defaults),
            StoredShortcut(key: "1", command: false, shift: false, option: false, control: true)
        )
        XCTAssertEqual(
            KeyboardShortcutSettings.rightSidebarPositionalDefaultShortcut(for: .files, defaults: defaults),
            StoredShortcut(key: "2", command: false, shift: false, option: false, control: true)
        )
    }

    func testPositionalDigitStopsAtNine() {
        enableAllModeGates()
        for (index, mode) in RightSidebarMode.visibleModes(defaults: defaults).enumerated() {
            XCTAssertEqual(
                RightSidebarMode.positionalDigit(for: mode, defaults: defaults),
                index < 9 ? index + 1 : nil
            )
        }
    }

    // MARK: - Activity mode (Artifact Shelf and Timeline)

    func testTimelineIsNewestFirstAndCappedAt200() {
        var activity = WorkspaceActivity()
        for index in 0..<(WorkspaceActivity.eventCap + 25) {
            activity.record(WorkspaceActivityEvent(kind: .portOpened, detail: String(index), at: TimeInterval(index)))
        }
        XCTAssertEqual(activity.events.count, WorkspaceActivity.eventCap)
        XCTAssertEqual(activity.events.first?.detail, String(WorkspaceActivity.eventCap + 24))
        XCTAssertEqual(activity.events.last?.detail, "25")
    }

    func testShelfListsOnlyThisWorkspacesClaudeEditsNewestFirstDeduped() {
        let ws = UUID(), other = UUID()
        func card(_ id: String, _ workspace: UUID, _ age: TimeInterval, _ files: [String]) -> AgentLensCard {
            AgentLensCard(
                id: id, workspaceID: workspace, surfaceID: nil, project: "p", state: .idle,
                startedAt: Date(timeIntervalSince1970: 0), lastEventAt: Date(timeIntervalSince1970: age),
                step: nil, todos: nil, files: files, usage: nil)
        }
        let cards = [
            card("a", ws, 100, ["/w/a.swift", "/w/b.swift"]),
            card("b", ws, 200, ["/w/b.swift", "/w/c.swift"]),
            card("c", other, 300, ["/w/x.swift"]),
        ]
        let shelf = WorkspaceActivityRules.claudeEditedFiles(cards: cards, workspaceId: ws, dismissed: [:])
        XCTAssertEqual(shelf.map(\.path), ["/w/b.swift", "/w/c.swift", "/w/a.swift"])
        let dismissed = WorkspaceActivityRules.claudeEditedFiles(cards: cards, workspaceId: ws, dismissed: ["/w/c.swift": 250])
        XCTAssertEqual(dismissed.map(\.path), ["/w/b.swift", "/w/a.swift"])
    }

    func testActivityPrunesWorkspacesUntouchedForFourteenDays() {
        let now: TimeInterval = 100 * 86_400
        let fresh = UUID(), stale = UUID()
        let all = [
            fresh: WorkspaceActivity(touched: now - 13 * 86_400),
            stale: WorkspaceActivity(touched: now - 15 * 86_400),
        ]
        XCTAssertEqual(Set(WorkspaceActivity.pruned(all, now: now).keys), [fresh])
    }

    func testAgentNotificationsMapToTimelineKinds() {
        XCTAssertEqual(WorkspaceActivityRules.agentKind(isAgentEvent: true, category: "turn-complete", isError: false), .agentFinished)
        XCTAssertEqual(WorkspaceActivityRules.agentKind(isAgentEvent: true, category: "needs-permission", isError: false), .agentNeedsInput)
        XCTAssertEqual(WorkspaceActivityRules.agentKind(isAgentEvent: true, category: "turn-complete", isError: true), .agentFailed)
        XCTAssertNil(WorkspaceActivityRules.agentKind(isAgentEvent: false, category: nil, isError: false))
    }

    func testMutationsPostShortcutSettingsDidChange() {
        enableAllModeGates()
        let expectation = expectation(
            forNotification: KeyboardShortcutSettings.didChangeNotification,
            object: nil
        )
        RightSidebarTabPreferences.setHidden(true, mode: .sessions, defaults: defaults)
        wait(for: [expectation], timeout: 1)
    }
}
