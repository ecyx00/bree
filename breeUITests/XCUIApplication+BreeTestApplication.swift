import XCTest

extension XCUIApplication {
    static func breeTestApplication() -> XCUIApplication {
        let application = XCUIApplication()
        application.launchEnvironment["BREE_UI_TEST_PROCESS"] = "1"
        return application
    }
}
