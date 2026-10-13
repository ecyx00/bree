import XCTest

private func helpMenuPollUntil(
    timeout: TimeInterval,
    pollInterval: TimeInterval = 0.05,
    condition: () -> Bool
) -> Bool {
    let start = ProcessInfo.processInfo.systemUptime
    while true {
        if condition() {
            return true
        }
        if (ProcessInfo.processInfo.systemUptime - start) >= timeout {
            return false
        }
        RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
    }
}

private func helpMenuResetMenuBarOnlyDefault() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["write", "com.bree.app.debug", "menuBarOnly", "-bool", "false"]
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return
    }
}

private let helpMenuMainWindowLaunchArguments = [
    "-AppleLanguages", "(en)",
    "-AppleLocale", "en_US",
    "-ApplePersistenceIgnoreState", "YES",
    "-NSQuitAlwaysKeepsWindows", "NO",
    "-menuBarOnly", "false",
]

final class HelpMenuUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testMainHelpMenuHasOnlyLocalItemsAndOpensKeyboardShortcuts() {
        let app = XCUIApplication.breeTestApplication()
        helpMenuResetMenuBarOnlyDefault()
        addTeardownBlock {
            app.terminate()
            helpMenuResetMenuBarOnlyDefault()
        }
        app.launchArguments += helpMenuMainWindowLaunchArguments
        app.launchEnvironment["BREE_UI_TEST_MODE"] = "1"
        launchAndActivate(app)

        XCTAssertTrue(waitForWindowCount(atLeast: 1, app: app, timeout: 6.0))

        let helpMenu = requireElement(
            candidates: [
                app.menuBars.menuBarItems["Help"],
                app.menuBars.menuItems["Help"],
            ],
            timeout: 4.0,
            description: "main Help menu"
        )
        helpMenu.click()

        XCTAssertTrue(app.menuItems["Check for Updates"].waitForExistence(timeout: 2.0))
        XCTAssertFalse(app.menuItems["Send Feedback"].exists)
        XCTAssertFalse(app.menuItems["Getting Started"].exists)
        XCTAssertFalse(app.menuItems["Changelog"].exists)

        let keyboardShortcutsItem = requireElement(
            candidates: [
                app.menuItems["Keyboard Shortcuts Settings…"],
                app.buttons["Keyboard Shortcuts Settings…"],
            ],
            timeout: 2.0,
            description: "Keyboard Shortcuts Settings Help menu item"
        )
        keyboardShortcutsItem.click()

        XCTAssertTrue(app.staticTexts["ShortcutRecordingHint"].waitForExistence(timeout: 6.0))
    }

    private func waitForWindowCount(atLeast count: Int, app: XCUIApplication, timeout: TimeInterval) -> Bool {
        helpMenuPollUntil(timeout: timeout) {
            app.windows.count >= count
        }
    }

    private func requireElement(
        candidates: [XCUIElement],
        timeout: TimeInterval,
        description: String
    ) -> XCUIElement {
        var match: XCUIElement?
        let found = helpMenuPollUntil(timeout: timeout) {
            for candidate in candidates where candidate.exists {
                match = candidate
                return true
            }
            return false
        }
        XCTAssertTrue(found, "Expected \(description) to exist")
        return match ?? candidates[0]
    }

    private func launchAndActivate(_ app: XCUIApplication, activateTimeout: TimeInterval = 2.0) {
        app.launch()

        XCTAssertTrue(
            helpMenuPollUntil(timeout: 10.0) {
                app.state == .runningForeground || app.state == .runningBackground
            },
            "App failed to launch. state=\(app.state.rawValue)"
        )

        if app.state != .runningForeground {
            let activated = helpMenuPollUntil(timeout: activateTimeout) {
                guard app.state != .runningForeground else {
                    return true
                }
                app.activate()
                return app.state == .runningForeground
            }
            if !activated {
                app.activate()
            }
        }

        XCTAssertTrue(
            helpMenuPollUntil(timeout: 6.0) {
                app.state == .runningForeground
            },
            "App did not become foreground before menu interactions. state=\(app.state.rawValue)"
        )
    }
}
