import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
private typealias NavStoredShortcut = cmux_DEV.StoredShortcut
#elseif canImport(cmux)
@testable import cmux
private typealias NavStoredShortcut = cmux.StoredShortcut
#endif

/// Defaults added for keyboard-first navigation must stay conflict-free.
@Suite("Keyboard navigation shortcuts")
@MainActor
struct KeyboardNavigationShortcutTests {
    private static let newActions: [(KeyboardShortcutSettings.Action, NavStoredShortcut)] = [
        (.focusLeftSidebar, NavStoredShortcut(key: "1", command: true, shift: false, option: false, control: true)),
        (.focusTerminal, NavStoredShortcut(key: "2", command: true, shift: false, option: false, control: true)),
        (.focusRightSidebarRegion, NavStoredShortcut(key: "3", command: true, shift: false, option: false, control: true)),
        (.cycleFocusRegionForward, NavStoredShortcut(key: "f6", command: false, shift: false, option: false, control: false)),
        (.cycleFocusRegionBackward, NavStoredShortcut(key: "f6", command: false, shift: true, option: false, control: false)),
        (.toggleQuickView, NavStoredShortcut(key: "y", command: true, shift: false, option: false, control: false)),
        (.toggleArchitecture, NavStoredShortcut(key: "a", command: true, shift: false, option: true, control: false)),
        (.toggleWiki, NavStoredShortcut(key: "k", command: true, shift: false, option: true, control: false)),
        (.showKeyboardShortcuts, NavStoredShortcut(key: "/", command: true, shift: false, option: false, control: true)),
        (.reopenClosedWorkspace, NavStoredShortcut(key: "t", command: true, shift: true, option: true, control: false)),
    ]

    @Test("new defaults match the expected chords in both registries")
    func defaultsMatchInBothRegistries() throws {
        for (action, expected) in Self.newActions {
            #expect(action.defaultShortcut == expected, "\(action.rawValue)")
            let shared = try #require(ShortcutAction(rawValue: action.rawValue))
            let sharedStroke = try #require(shared.defaultStroke, "\(action.rawValue)")
            #expect(sharedStroke.key == expected.firstStroke.key, "\(action.rawValue)")
            #expect(sharedStroke.command == expected.firstStroke.command, "\(action.rawValue)")
            #expect(sharedStroke.shift == expected.firstStroke.shift, "\(action.rawValue)")
            #expect(sharedStroke.option == expected.firstStroke.option, "\(action.rawValue)")
            #expect(sharedStroke.control == expected.firstStroke.control, "\(action.rawValue)")
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
        }
    }

    @Test("new defaults do not conflict with any other action's default")
    func newDefaultsDoNotConflictWithOtherDefaults() {
        for (action, shortcut) in Self.newActions {
            for other in KeyboardShortcutSettings.Action.allCases where other != action {
                let conflicts = other.conflicts(
                    with: shortcut,
                    proposedAction: action,
                    configuredShortcut: other.defaultShortcut
                )
                #expect(!conflicts, "\(action.rawValue) conflicts with \(other.rawValue)")
            }
        }
    }

    @Test("new defaults do not collide with reserved macOS shortcuts")
    func newDefaultsAvoidSystemShortcuts() throws {
        for (action, _) in Self.newActions {
            let shared = try #require(ShortcutAction(rawValue: action.rawValue))
            let stored = try #require(shared.defaultShortcut)
            #expect(MacOSSystemShortcut.conflicts(with: stored, for: shared).isEmpty, "\(action.rawValue)")
        }
    }

    @Test("focus region cycle follows the documented order and skips unavailable regions")
    func focusRegionCycleOrder() {
        let all: (KeyboardFocusRegion) -> Bool = { $0 != .bottomPanel }
        #expect(KeyboardFocusRegion.next(after: .leftSidebar, forward: true, isAvailable: all) == .terminal)
        #expect(KeyboardFocusRegion.next(after: .terminal, forward: true, isAvailable: all) == .rightSidebar)
        #expect(KeyboardFocusRegion.next(after: .rightSidebar, forward: true, isAvailable: all) == .quickView)
        #expect(KeyboardFocusRegion.next(after: .quickView, forward: true, isAvailable: all) == .leftSidebar)
        #expect(KeyboardFocusRegion.next(after: .leftSidebar, forward: false, isAvailable: all) == .quickView)

        let withPanel: (KeyboardFocusRegion) -> Bool = { _ in true }
        #expect(KeyboardFocusRegion.next(after: .terminal, forward: true, isAvailable: withPanel) == .bottomPanel)

        let terminalOnly: (KeyboardFocusRegion) -> Bool = { $0 == .terminal }
        #expect(KeyboardFocusRegion.next(after: .terminal, forward: true, isAvailable: terminalOnly) == .terminal)
    }
}
