import AppKit
import BreeTerminal
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

private final class ShortcutUnrelatedResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
@Suite(.serialized)
struct AppDelegateSurfaceShortcutRoutingTests {
    @Test func rightSidebarModeShortcutsDoNotFallThroughWhenResponderTemporarilyClears() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)

            let modeEvents: [(mode: RightSidebarMode, event: NSEvent)] = [
                (.files, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))),
                (.sessions, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: window.windowNumber))),
                (.activity, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: window.windowNumber)))
            ]

            for cycle in 0..<10 {
                for (mode, event) in modeEvents {
                    _ = window.makeFirstResponder(nil)
#if DEBUG
                    #expect(
                        appDelegate.debugHandleCustomShortcut(event: event),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should be handled on cycle \(cycle)"
                    )
#else
                    Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                    #expect(
                        appDelegate.fileExplorerState?.mode == mode,
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should keep routing as a right-sidebar mode shortcut on cycle \(cycle)"
                    )
                    #expect(
                        !terminalPanel.hostedView.isSurfaceViewFirstResponder(),
                        "Ctrl+\(event.charactersIgnoringModifiers ?? "?") should not refocus the terminal on cycle \(cycle)"
                    )
                }
            }
        }
    }

    @Test func keyboardCopyModeKeyClearsTerminalUnread() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        try await withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let previousSharedAppDelegate = AppDelegate.shared
            AppDelegate.shared = appDelegate
            defer { AppDelegate.shared = previousSharedAppDelegate }
            let previousNotificationStore = appDelegate.notificationStore
            defer { appDelegate.notificationStore = previousNotificationStore }
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            let terminalPanel = try #require(workspace.terminalPanel(for: panelId))
            let surfaceView = terminalPanel.hostedView.surfaceView
            let event = try #require(makeKeyDownEvent(
                key: "j",
                modifiers: [],
                keyCode: 38,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            terminalPanel.hostedView.setVisibleInUI(true)
            terminalPanel.hostedView.setActive(true)
            await startAndWaitForLiveSurface(terminalPanel.surface)
            try #require(await appDelegate.focusTerminalForTesting(
                terminalPanel, workspace: workspace, in: window
            ))
            #expect(surfaceView.prepareSurfaceForPaste(
                reason: "test.keyboardCopyModeKey"
            ))
            #expect(terminalPanel.surface.toggleKeyboardCopyMode())
            defer {
                if terminalPanel.surface.keyboardCopyModeActive {
                    _ = terminalPanel.surface.toggleKeyboardCopyMode()
                }
            }

            appDelegate.notificationStore = TerminalNotificationStore.shared
            workspace.markPanelUnread(panelId)
            #expect(workspace.manualUnreadPanelIds.contains(panelId))

            surfaceView.keyDown(with: event)

            #expect(!workspace.manualUnreadPanelIds.contains(panelId))
        }
        }
    }

    @Test func workspaceFontSizeShortcutPreservesBackgroundTerminalUnread() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
        try await withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)
            let previousSharedAppDelegate = AppDelegate.shared
            AppDelegate.shared = appDelegate
            defer { AppDelegate.shared = previousSharedAppDelegate }
            let previousNotificationStore = appDelegate.notificationStore
            defer { appDelegate.notificationStore = previousNotificationStore }
            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            let manager = try #require(appDelegate.tabManagerFor(windowId: windowId))
            let workspace = try #require(manager.selectedWorkspace)
            let foregroundPanelId = try #require(workspace.focusedPanelId)
            let foregroundPanel = try #require(workspace.terminalPanel(for: foregroundPanelId))
            let backgroundPanel = try #require(workspace.newTerminalSplit(
                from: foregroundPanelId,
                orientation: .horizontal,
                focus: false
            ))
            let event = try #require(makeKeyDownEvent(
                key: "-",
                modifiers: [.command, .control],
                keyCode: 27,
                windowNumber: window.windowNumber
            ))

            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            foregroundPanel.hostedView.setVisibleInUI(true)
            foregroundPanel.hostedView.setActive(true)
            backgroundPanel.hostedView.setVisibleInUI(true)
            backgroundPanel.hostedView.setActive(false)
            await startAndWaitForLiveSurface(foregroundPanel.surface)
            await startAndWaitForLiveSurface(backgroundPanel.surface)
            #expect(foregroundPanel.surface.hasLiveSurface)
            #expect(backgroundPanel.surface.hasLiveSurface)

            try #require(await appDelegate.focusTerminalForTesting(
                foregroundPanel, workspace: workspace, in: window
            ))
            appDelegate.notificationStore = TerminalNotificationStore.shared
            workspace.markPanelUnread(foregroundPanelId)
            workspace.markPanelUnread(backgroundPanel.id)
            #expect(workspace.manualUnreadPanelIds.contains(foregroundPanelId))
            #expect(workspace.manualUnreadPanelIds.contains(backgroundPanel.id))

#if DEBUG
            #expect(appDelegate.debugHandleCustomShortcut(event: event))
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(
                backgroundPanel.surface.fontSizeLineageSnapshot()?.isExplicitOverride == true,
                "The workspace-wide shortcut must reach the live background terminal"
            )
            #expect(
                !workspace.manualUnreadPanelIds.contains(foregroundPanelId),
                "The originating terminal must accept its handled shortcut"
            )
            #expect(
                workspace.manualUnreadPanelIds.contains(backgroundPanel.id),
                "Changing terminal configuration is not accepted terminal input"
            )
        }
        }
    }

    @Test func rightSidebarModeShortcutsDoNotUseStaleIntentForUnrelatedResponder() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let windowId = appDelegate.createMainWindow()
            defer { closeWindow(withId: windowId) }

            let window = try #require(mainWindow(for: windowId))
            window.makeKeyAndOrderFront(nil)
            window.displayIfNeeded()
            appDelegate.noteRightSidebarKeyboardFocusIntent(mode: .sessions, in: window)
            let fileExplorerState = try #require(appDelegate.fileExplorerState)
            fileExplorerState.mode = .sessions

            let unrelatedResponder = ShortcutUnrelatedResponderView(frame: NSRect(x: 0, y: 0, width: 8, height: 8))
            window.contentView?.addSubview(unrelatedResponder)
            defer { unrelatedResponder.removeFromSuperview() }
            #expect(window.makeFirstResponder(unrelatedResponder))
            #expect(window.firstResponder === unrelatedResponder)

            KeyboardShortcutSettings.clearShortcut(for: .selectSurfaceByNumber)
#if DEBUG
            appDelegate.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif

            let event = try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: window.windowNumber))
#if DEBUG
            _ = appDelegate.debugHandleCustomShortcut(event: event)
#else
            Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif

            #expect(
                fileExplorerState.mode == .sessions,
                "Ctrl+1 should not switch right-sidebar mode when a non-sidebar responder owns focus"
            )
            #expect(
                window.firstResponder === unrelatedResponder,
                "Ctrl+1 should not move focus away from the unrelated responder"
            )
        }
    }

    @Test func surfaceNumberShortcutsCycleInEventWindowWhenActiveManagerIsStale() throws {
        try withIsolatedShortcutSettings {
            let appDelegate = try #require(AppDelegate.shared)

            let firstWindowId = appDelegate.createMainWindow()
            let secondWindowId = appDelegate.createMainWindow()
            defer {
                closeWindow(withId: firstWindowId)
                closeWindow(withId: secondWindowId)
            }

            let firstManager = try #require(appDelegate.tabManagerFor(windowId: firstWindowId))
            let secondManager = try #require(appDelegate.tabManagerFor(windowId: secondWindowId))
            let secondWindow = try #require(mainWindow(for: secondWindowId))
            let firstWorkspace = try #require(firstManager.selectedWorkspace)
            let secondWorkspace = try #require(secondManager.selectedWorkspace)
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))
            _ = try #require(secondWorkspace.newTerminalSurfaceInFocusedPane(focus: true))

            let expectedSurfaceIds = Array(secondWorkspace.orderedPanelIds.prefix(3))
            #expect(expectedSurfaceIds.count == 3, "Test needs three ordered surfaces")
            #expect(firstWorkspace.id != secondWorkspace.id)

            appDelegate.tabManager = firstManager
            #expect(appDelegate.tabManager === firstManager)

            let digitEvents: [(digit: Int, event: NSEvent)] = [
                (1, try #require(makeKeyDownEvent(key: "1", keyCode: 18, windowNumber: secondWindow.windowNumber))),
                (2, try #require(makeKeyDownEvent(key: "2", keyCode: 19, windowNumber: secondWindow.windowNumber))),
                (3, try #require(makeKeyDownEvent(key: "3", keyCode: 20, windowNumber: secondWindow.windowNumber)))
            ]

            try withTemporaryShortcut(action: .selectSurfaceByNumber) {
                for cycle in 0..<10 {
                    for (digit, event) in digitEvents {
#if DEBUG
                        #expect(
                            appDelegate.debugHandleCustomShortcut(event: event),
                            "Ctrl+\(digit) should be handled on cycle \(cycle)"
                        )
#else
                        Issue.record("debugHandleCustomShortcut is only available in DEBUG")
#endif
                        #expect(
                            secondWorkspace.focusedPanelId == expectedSurfaceIds[digit - 1],
                            "Ctrl+\(digit) should focus surface \(digit) in the event window on cycle \(cycle)"
                        )
                    }
                }
            }
        }
    }

    private func makeKeyDownEvent(
        key: String,
        modifiers: NSEvent.ModifierFlags = [.control],
        keyCode: UInt16,
        windowNumber: Int
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: key,
            charactersIgnoringModifiers: key,
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private func withTemporaryShortcut(action: KeyboardShortcutSettings.Action, _ body: () throws -> Void) rethrows {
        let hadPersistedShortcut = UserDefaults.standard.object(forKey: action.defaultsKey) != nil
        let originalShortcut = KeyboardShortcutSettings.shortcut(for: action)
        defer {
            if hadPersistedShortcut {
                KeyboardShortcutSettings.setShortcut(originalShortcut, for: action)
            } else {
                KeyboardShortcutSettings.resetShortcut(for: action)
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        KeyboardShortcutSettings.setShortcut(action.defaultShortcut, for: action)
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        try body()
    }

    private func withIsolatedShortcutSettings(_ body: () throws -> Void) rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "bree-surface-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try body()
    }

    private func withIsolatedShortcutSettings(
        _ body: () async throws -> Void
    ) async rethrows {
        let actionsWithPersistedShortcut = Set(
            KeyboardShortcutSettings.Action.allCases.filter {
                UserDefaults.standard.object(forKey: $0.defaultsKey) != nil
            }
        )
        let savedShortcutsByAction = Dictionary(
            uniqueKeysWithValues: actionsWithPersistedShortcut.map { action in
                (action, KeyboardShortcutSettings.shortcut(for: action))
            }
        )
        let originalSettingsFileStore = KeyboardShortcutSettings.installIsolatedTestFileStore(
            prefix: "bree-surface-shortcut-routing"
        )
        KeyboardShortcutSettings.resetAll()
#if DEBUG
        AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        defer {
            KeyboardShortcutSettings.settingsFileStore = originalSettingsFileStore
            for action in KeyboardShortcutSettings.Action.allCases {
                if actionsWithPersistedShortcut.contains(action),
                   let savedShortcut = savedShortcutsByAction[action] {
                    KeyboardShortcutSettings.setShortcut(savedShortcut, for: action)
                } else {
                    KeyboardShortcutSettings.resetShortcut(for: action)
                }
            }
#if DEBUG
            AppDelegate.shared?.debugResetShortcutRoutingStateForTesting(clearFocusedWindowOverride: false)
#endif
        }
        try await body()
    }

    private func startAndWaitForLiveSurface(_ surface: TerminalSurface) async {
        guard !surface.hasLiveSurface else { return }
        let previousOnRuntimeReady = surface.onRuntimeReady
        defer { surface.onRuntimeReady = previousOnRuntimeReady }
        let readiness = AsyncStream<Void> { continuation in
            surface.onRuntimeReady = {
                previousOnRuntimeReady?()
                continuation.yield()
                continuation.finish()
            }
        }
        surface.requestInputDemandSurfaceStartIfNeeded()
        for await _ in readiness { break }
    }

    private func mainWindow(for windowId: UUID) -> NSWindow? {
        AppDelegate.shared?.windowForMainWindowId(windowId)
    }

    private func closeWindow(withId windowId: UUID) {
        guard let window = mainWindow(for: windowId) else { return }
        window.close()
    }
}
