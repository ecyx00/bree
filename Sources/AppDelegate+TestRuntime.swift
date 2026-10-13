import Foundation

/// Shim: `AppDelegate.transportSentryReporter` still names this type so the
/// AppDelegate declaration does not change in the telemetry-removal phase.
/// Delete both together.
typealias TransportSentryReporter = AnyObject

enum TestProcessEnvironment {
    static func isRunningUnderXCTest(environment: [String: String]) -> Bool {
        // xcodebuild strips TEST_RUNNER_ from variables forwarded to the test
        // host, so the CI wrapper makes this available before XCTest connects.
        if environment["BREE_TEST_PROCESS"] == "1" { return true }
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestBundlePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        if environment["XCInjectBundleInto"] != nil { return true }
        if environment["DYLD_INSERT_LIBRARIES"]?.contains("libXCTest") == true { return true }
        if environment.keys.contains(where: { $0.hasPrefix("BREE_UI_TEST_") }) { return true }
        return false
    }
}

extension AppDelegate {
    func isRunningUnderXCTest(_ env: [String: String]) -> Bool {
        TestProcessEnvironment.isRunningUnderXCTest(environment: env)
    }
}
