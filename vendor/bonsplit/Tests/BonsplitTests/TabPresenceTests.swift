import XCTest
@testable import Bonsplit
import AppKit
import SwiftUI

final class TabPresenceTests: XCTestCase {
    private func samplePresence(mode: TabPresence.SizeMode = .priority, canDisconnect: Bool = false, alone: Bool = false) -> TabPresence {
        TabPresence(
            participants: alone ? [] : [
                .init(id: "user:u_maya", initials: "MO", isOwner: true, accessibilityName: "Maya Ortiz"),
                .init(id: "device:iphone", initials: "", symbolName: "iphone", isOwner: false, accessibilityName: "iPhone"),
            ],
            sizeMode: mode,
            canDisconnectOthers: canDisconnect,
            accessibilityLabel: "Size set by Maya's Mac · 118×38"
        )
    }

    func testAccessoryShowsOnlyWithParticipants() {
        XCTAssertTrue(samplePresence().showsAccessory)
        XCTAssertFalse(samplePresence(alone: true).showsAccessory)
    }

    func testTabItemCodableRoundTripsPresence() throws {
        let presence = samplePresence()
        let item = TabItem(title: "zsh", presence: presence)
        let decoded = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(decoded.presence, presence)

        let legacy = try JSONDecoder().decode(TabItem.self, from: JSONEncoder().encode(TabItem(title: "zsh")))
        XCTAssertNil(legacy.presence)
    }

    @MainActor
    func testUpdateTabSetsKeepsAndClearsPresence() throws {
        let controller = BonsplitController()
        let tabId = try XCTUnwrap(controller.createTab(title: "zsh"))
        XCTAssertNil(controller.tab(tabId)?.presence)

        let presence = samplePresence()
        controller.updateTab(tabId, presence: .some(presence))
        XCTAssertEqual(controller.tab(tabId)?.presence, presence)

        controller.updateTab(tabId, title: "renamed")
        XCTAssertEqual(controller.tab(tabId)?.presence, presence)

        controller.updateTab(tabId, presence: .some(nil))
        XCTAssertNil(controller.tab(tabId)?.presence)
    }

    func testSizeModeActionsRoundTrip() {
        for mode in TabPresence.SizeMode.allCases {
            XCTAssertEqual(TabContextAction.sizeMode(mode).sizeMode, mode)
        }
        XCTAssertNil(TabContextAction.toggleSizePanel.sizeMode)
    }

    @MainActor
    func testPopoverAnchorPrefersVisibleAccessoryOverTabItem() {
        let controller = BonsplitController()
        let tabId = TabID()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [], backing: .buffered, defer: true)
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content

        let item = TabPopoverAnchorView.AnchorNSView(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        content.addSubview(item)
        item.configure(tabId: tabId.id, kind: .tabItem)
        XCTAssertTrue(controller.popoverAnchorView(for: tabId) === item)

        let accessory = TabPopoverAnchorView.AnchorNSView(frame: NSRect(x: 80, y: 5, width: 30, height: 18))
        content.addSubview(accessory)
        accessory.configure(tabId: tabId.id, kind: .presenceAccessory)
        XCTAssertTrue(controller.popoverAnchorView(for: tabId) === accessory)

        accessory.removeFromSuperview()
        XCTAssertTrue(controller.popoverAnchorView(for: tabId) === item)
        item.isHidden = true
        XCTAssertNil(controller.popoverAnchorView(for: tabId))
    }

    func testParticipantDecodesPayloadWithoutSymbolName() throws {
        let json = ##"{"id":"c3","initials":"MO","colorHex":"#3CC2B0","isOwner":true,"accessibilityName":"Maya"}"##
        let decoded = try JSONDecoder().decode(TabPresence.Participant.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.initials, "MO")
        XCTAssertNil(decoded.symbolName)
        XCTAssertTrue(decoded.isOwner)
    }
}
