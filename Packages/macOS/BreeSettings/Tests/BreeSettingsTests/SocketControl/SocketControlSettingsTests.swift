import Foundation
import Testing

import BreeSettings

@Suite struct SocketControlSettingsTests {
    @Test func migrateModeMapsLegacyAndUnknownValues() {
        #expect(SocketControlSettings.migrateMode("off") == .off)
        #expect(SocketControlSettings.migrateMode("bree_only") == .breeOnly)
        #expect(SocketControlSettings.migrateMode("ALLOW-ALL") == .allowAll)
        // Legacy aliases.
        #expect(SocketControlSettings.migrateMode("notifications") == .automation)
        #expect(SocketControlSettings.migrateMode("full") == .allowAll)
        // Unknown falls back to the default.
        #expect(SocketControlSettings.migrateMode("bogus") == .breeOnly)
    }

    @Test func effectiveModeHonorsEnableOverride() {
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["BREE_SOCKET_ENABLE": "0"]
            ) == .off
        )
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .off,
                environment: ["BREE_SOCKET_ENABLE": "1"]
            ) == .breeOnly
        )
    }

    @Test func effectiveModeHonorsModeOverride() {
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .breeOnly,
                environment: ["BREE_SOCKET_MODE": "allowall"]
            ) == .allowAll
        )
    }

    @Test func effectiveModeFallsBackToUserMode() {
        #expect(
            SocketControlSettings.effectiveMode(userMode: .automation, environment: [:]) == .automation
        )
    }

    @Test(arguments: [SocketControlMode.breeOnly, .off])
    func forcedRestrictiveModeWinsOverDefaultsAndEnvironment(mode: SocketControlMode) throws {
        let suiteName = "SocketControlSettingsTests.forced.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SocketControlMode.allowAll.rawValue, forKey: SocketControlSettings.appStorageKey)
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: { store, key in
                key == ManagedDevicePolicyKey.socketControlMode.rawValue
                    ? store.object(forKey: key)
                    : nil
            }
        )
        defaults.set(mode.rawValue, forKey: ManagedDevicePolicyKey.socketControlMode.rawValue)
        let resolution = SocketControlPolicyResolver(
            defaults: defaults,
            environment: [
                "BREE_SOCKET_ENABLE": "1",
                "BREE_SOCKET_MODE": "password",
                "BREE_SOCKET_PASSWORD": "secret",
            ],
            bundleIdentifier: suiteName,
            managedPolicy: policy
        ).resolve()
        #expect(resolution.mode == mode)
        #expect(resolution.configuredMode == .allowAll)
        #expect(resolution.isManaged)
        #expect(resolution.forcedValueStatus == "valid")
    }

    @Test func malformedForcedModeFailsClosedAndProfileRemovalRestoresUserMode() throws {
        let suiteName = "SocketControlSettingsTests.malformed.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(SocketControlMode.allowAll.rawValue, forKey: SocketControlSettings.appStorageKey)
        let policy = ManagedDevicePolicy(
            defaults: defaults,
            releaseDomainDefaults: nil,
            forcedObject: { store, key in
                guard key == ManagedDevicePolicyKey.socketControlMode.rawValue else { return nil }
                return store.object(forKey: "forced.SocketControlMode")
            }
        )
        defaults.set("allowAll", forKey: "forced.SocketControlMode")
        let resolver = SocketControlPolicyResolver(
            defaults: defaults,
            environment: [:],
            managedPolicy: policy
        )
        let malformed = resolver.resolve()
        #expect(malformed.mode == .off)
        #expect(malformed.isManaged)
        #expect(malformed.forcedValueStatus == "invalid")
        defaults.removeObject(forKey: "forced.SocketControlMode")
        let removed = resolver.resolve()
        #expect(removed.mode == .allowAll)
        #expect(!removed.isManaged)
    }

    @Test func truthyParsing() {
        for value in ["1", "true", "YES", "on"] {
            #expect(SocketControlSettings.isTruthy(value))
        }
        for value in ["0", "false", "", "nope"] {
            #expect(!SocketControlSettings.isTruthy(value))
        }
    }

    @Test func taggedDevBuildDetection() {
        #expect(SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.bree.app.debug.my-tag"))
        #expect(!SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.bree.app.debug"))
        #expect(!SocketControlSettings.isTaggedDevBuild(bundleIdentifier: "com.bree.app"))
    }

    @Test func untaggedDebugLaunchIsBlockedOnlyForBareDebugBundle() {
        // Bare debug bundle, no tag, not under test => blocked.
        #expect(
            SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.bree.app.debug",
                isDebugBuild: true
            )
        )
        // XCUITest launches the app as a separate process without XCTest env vars,
        // so any BREE_UI_TEST_ marker must bypass blocking for a bare debug bundle.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["BREE_UI_TEST_RUN": "1"],
                bundleIdentifier: "com.bree.app.debug",
                isDebugBuild: true
            )
        )
        // Tagged debug bundle => allowed.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.bree.app.debug.tag",
                isDebugBuild: true
            )
        )
        // Release build => never blocked.
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.bree.app",
                isDebugBuild: false
            )
        )
    }

    @Test func socketPathHonorsOverrideForTaggedDevWhenAllowed() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/tmp/bree-custom.sock",
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.tag",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path == "/tmp/bree-custom.sock")
    }

    @Test func bareDebugXCTestLaunchUsesScopedSocketFallback() {
        let environment = [
            "XCTestConfigurationFilePath": "/tmp/Test-bree-unit-2026.06.17.xctestconfiguration",
        ]
        let path = SocketControlSettings.socketPath(
            environment: environment,
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        let defaultPath = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.bree.app.debug",
            environment: environment,
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path.hasPrefix("/tmp/bree-xctest-"))
        #expect(path.hasSuffix(".sock"))
        #expect(path != "/tmp/bree-debug.sock")
        #expect(path == defaultPath)
    }

    @Test func explicitSocketOverrideStillWinsUnderXCTest() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/tmp/bree-forced.sock",
                "XCTestConfigurationFilePath": "/tmp/Test-bree-unit-2026.06.17.xctestconfiguration",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path == "/tmp/bree-forced.sock")
    }

    @Test func dyldOnlyXCTestLaunchUsesScopedSocketFallback() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/Contents/Developer/usr/lib/libXCTestSwiftSupport.dylib",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path.hasPrefix("/tmp/bree-xctest-"))
        #expect(path.hasSuffix(".sock"))
        #expect(path != "/tmp/bree-debug.sock")
    }

    @Test func xctestSocketFallbackHashesFullPath() {
        let first = SocketControlSettings.socketPath(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/first/Test-bree-unit.xctestconfiguration",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        let second = SocketControlSettings.socketPath(
            environment: [
                "XCTestConfigurationFilePath": "/tmp/second/Test-bree-unit.xctestconfiguration",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(first.hasPrefix("/tmp/bree-xctest-"))
        #expect(second.hasPrefix("/tmp/bree-xctest-"))
        #expect(first != second)
    }

    @Test func taggedDebugXCTestLaunchStillUsesTaggedSocket() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_TAG": "ci-split-theme",
                "XCTestConfigurationFilePath": "/tmp/Test-bree-unit-2026.06.17.xctestconfiguration",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing }
        )
        #expect(path == "/tmp/bree-debug-ci-split-theme.sock")
    }

    @Test func initialStableLaunchReclaimsSameUserStaleSocketWhenLockIsFree() {
        var didProbeReclaimability = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in
                didProbeReclaimability = true
                return true
            }
        )

        #expect(didProbeReclaimability)
        #expect(path == SocketControlSettings.stableDefaultSocketPath)
    }

    @Test func initialStableLaunchFailsClosedWithoutReclaimabilityProbe() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }
}
