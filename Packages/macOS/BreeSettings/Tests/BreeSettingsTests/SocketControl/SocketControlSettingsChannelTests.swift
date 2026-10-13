import Foundation
import Testing

@testable import BreeSettings

/// Channel/override/startup rules for the control socket path.
///
/// These moved out of the app-host `breeTests` bundle: every assertion here is
/// on `BreeSettings` value types only, so the app host bought nothing.
/// ``SocketControlSettingsTests`` covers mode resolution and the XCTest socket
/// fallback; this suite covers bundle-channel defaults, override refusal, and
/// the pre-listener startup probe.
@Suite struct SocketControlSettingsChannelTests {
    // MARK: - Mode and permissions

    @Test func migrateModeAcceptsEveryCanonicalSpelling() {
        #expect(SocketControlSettings.migrateMode("off") == .off)
        #expect(SocketControlSettings.migrateMode("breeOnly") == .breeOnly)
        #expect(SocketControlSettings.migrateMode("automation") == .automation)
        #expect(SocketControlSettings.migrateMode("password") == .password)
        #expect(SocketControlSettings.migrateMode("allow-all") == .allowAll)
    }

    @Test func socketFilePermissionsAreRestrictiveExceptForAllowAll() {
        #expect(SocketControlMode.off.socketFilePermissions == 0o600)
        #expect(SocketControlMode.breeOnly.socketFilePermissions == 0o600)
        #expect(SocketControlMode.automation.socketFilePermissions == 0o600)
        #expect(SocketControlMode.password.socketFilePermissions == 0o600)
        #expect(SocketControlMode.allowAll.socketFilePermissions == 0o666)
    }

    @Test func invalidEnvSocketModeDoesNotOverrideUserMode() {
        #expect(
            SocketControlSettings.envOverrideMode(
                environment: ["BREE_SOCKET_MODE": "definitely-not-a-mode"]
            ) == nil
        )
        #expect(
            SocketControlSettings.effectiveMode(
                userMode: .password,
                environment: ["BREE_SOCKET_MODE": "definitely-not-a-mode"]
            ) == .password
        )
    }

    // MARK: - Ambient override handling per channel

    @Test func stableReleaseIgnoresAmbientSocketOverrideByDefault() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_TAG": "stray-tag",
                "BREE_SOCKET_PATH": "/tmp/bree-debug-issue-153-tmux-compat.sock",
            ],
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == SocketControlSettings.stableDefaultSocketPath)
    }

    @Test func taggedDebugLaunchUsesTagDefaultWhenNoOverrideIsProvided() {
        let path = SocketControlSettings.socketPath(
            environment: ["BREE_TAG": "my-tag"],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true
        )

        #expect(path == "/tmp/bree-debug-my-tag.sock")
    }

    @Test func taggedDebugLaunchStillHonorsSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_TAG": "my-tag",
                "BREE_SOCKET_PATH": "/tmp/bree-debug-forced.sock",
            ],
            bundleIdentifier: "com.bree.app.debug",
            isDebugBuild: true
        )

        #expect(path == "/tmp/bree-debug-forced.sock")
    }

    @Test func nightlyReleaseUsesDedicatedDefaultAndIgnoresAmbientSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: ["BREE_SOCKET_PATH": "/tmp/bree-debug-issue-153-tmux-compat.sock"],
            bundleIdentifier: "com.bree.app.nightly",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == "/tmp/bree-nightly.sock")
    }

    @Test func taggedDebugBundleKeepsMatchingSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: ["BREE_SOCKET_PATH": "/tmp/bree-debug-my-tag.sock"],
            bundleIdentifier: "com.bree.app.debug.my-tag",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-my-tag.sock")
    }

    @Test func taggedDebugBundleIgnoresSocketOverrideInheritedFromDifferentBreeBundle() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_BUNDLE_ID": "com.bree.app.nightly",
                "BREE_SOCKET_PATH": "/tmp/bree-nightly.sock",
            ],
            bundleIdentifier: "com.bree.app.debug.issue.4355.bree.themes.set.state.dependent",
            isDebugBuild: true
        )

        #expect(path == "/tmp/bree-debug-issue-4355-bree-themes-set-state-dependent.sock")
    }

    @Test func taggedDebugBundleIgnoresMismatchedInheritedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/tmp/bree-nightly.sock",
                "BREE_BUNDLE_ID": "com.bree.app.nightly",
            ],
            bundleIdentifier: "com.bree.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-fix-grok-notifications.sock")
    }

    @Test func taggedDebugBundleCanOptInToMismatchedSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/tmp/bree-nightly.sock",
                "BREE_BUNDLE_ID": "com.bree.app.nightly",
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.fix-grok-notifications",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-nightly.sock")
    }

    @Test func stagingBundleHonorsSocketOverrideWithoutOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: ["BREE_SOCKET_PATH": "/tmp/bree-staging-my-tag.sock"],
            bundleIdentifier: "com.bree.app.staging.my-tag",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-staging-my-tag.sock")
    }

    @Test func stableReleaseCanOptInToSocketOverride() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/tmp/bree-debug-forced.sock",
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            probeStableDefaultPathEntry: { _ in .missing }
        )

        #expect(path == "/tmp/bree-debug-forced.sock")
    }

    // MARK: - Stable-socket hijack refusal

    @Test func taggedDebugBundleRefusesStableSocketOverrideEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": SocketControlSettings.stableDefaultSocketPath,
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-sockguard.sock")
    }

    @Test func taggedDebugBundleRefusesUserScopedStableSocketOverrideEvenWithOptInFlag() {
        let aliases = [
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501),
            "/private/tmp/bree-501.sock",
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "BREE_SOCKET_PATH": alias,
                    "BREE_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.bree.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            #expect(path == "/tmp/bree-debug-sockguard.sock", "alias: \(alias)")
        }
    }

    @Test func taggedDebugBundleRefusesCanonicalLegacyStableSocketAliasEvenWithOptInFlag() {
        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": "/private/tmp/bree.sock",
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-sockguard.sock")
    }

    @Test func socketPathMatchingTreatsPrivateTmpLegacyStableAliasAsSamePath() {
        #expect(
            SocketControlSettings.pathsMatch(
                SocketControlSettings.legacyStableDefaultSocketPath,
                "/private/tmp/bree.sock"
            )
        )
    }

    @Test func taggedDebugBundleRefusesCaseVariantStableSocketAliasesEvenWithOptInFlag() {
        let aliases = [
            "/tmp/BREE.sock",
            "/private/tmp/BREE.sock",
            SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "bree-501.sock", with: "BREE-501.sock"),
            SocketControlSettings.legacyUserScopedStableSocketPath(currentUserID: 501)
                .replacingOccurrences(of: "bree-501.sock", with: "BREE-501.sock"),
        ]

        for alias in aliases {
            let path = SocketControlSettings.socketPath(
                environment: [
                    "BREE_SOCKET_PATH": alias,
                    "BREE_ALLOW_SOCKET_OVERRIDE": "1",
                ],
                bundleIdentifier: "com.bree.app.debug.sockguard",
                isDebugBuild: false,
                currentUserID: 501
            )

            #expect(path == "/tmp/bree-debug-sockguard.sock", "alias: \(alias)")
        }
    }

    @Test func taggedDebugBundleRefusesLeafSymlinkToStableSocketEvenWithOptInFlag() throws {
        let alias = "/tmp/bree-stable-alias-\(UUID().uuidString).sock"
        try? FileManager.default.removeItem(atPath: alias)
        try FileManager.default.createSymbolicLink(
            atPath: alias,
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        defer { try? FileManager.default.removeItem(atPath: alias) }

        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": alias,
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-sockguard.sock")
    }

    @Test func taggedDebugBundleRefusesExcessiveSymlinkChainEvenWithOptInFlag() throws {
        let root = "/tmp/bree-stable-chain-\(UUID().uuidString)"
        let aliases = (0...64).map { "\(root)-\($0).sock" }
        for alias in aliases {
            try? FileManager.default.removeItem(atPath: alias)
        }
        defer {
            for alias in aliases {
                try? FileManager.default.removeItem(atPath: alias)
            }
        }

        try FileManager.default.createSymbolicLink(
            atPath: aliases[64],
            withDestinationPath: SocketControlSettings.stableDefaultSocketPath
        )
        for index in stride(from: 63, through: 0, by: -1) {
            try FileManager.default.createSymbolicLink(
                atPath: aliases[index],
                withDestinationPath: aliases[index + 1]
            )
        }

        let path = SocketControlSettings.socketPath(
            environment: [
                "BREE_SOCKET_PATH": aliases[0],
                "BREE_ALLOW_SOCKET_OVERRIDE": "1",
            ],
            bundleIdentifier: "com.bree.app.debug.sockguard",
            isDebugBuild: false
        )

        #expect(path == "/tmp/bree-debug-sockguard.sock")
    }

    // MARK: - Default path per channel

    @Test func defaultSocketPathByChannel() {
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.bree.app",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == SocketControlSettings.stableDefaultSocketPath
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.bree.app.nightly",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/bree-nightly.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.bree.app.nightly.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/bree-nightly-tag.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.bree.app.debug.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/bree-debug-tag.sock"
        )
        #expect(
            SocketControlSettings.defaultSocketPath(
                bundleIdentifier: "com.bree.app.staging.tag",
                isDebugBuild: false,
                probeStableDefaultPathEntry: { _ in .missing }
            ) == "/tmp/bree-staging-tag.sock"
        )
    }

    @Test func stableReleaseFallsBackToUserScopedSocketWhenStablePathOwnedByDifferentUser() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 0) }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func stableReleaseFallsBackToUserScopedSocketWhenStablePathIsBlockedByNonSocketEntry() {
        let path = SocketControlSettings.defaultSocketPath(
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .other(ownerUserID: 501) }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    // MARK: - Pre-listener startup path

    @Test func initialStableLaunchFallsBackToUserScopedSocketWhenSameUserStablePathIsLive() {
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in false }
        )

        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchTreatsPrivateTmpLegacyStableAliasAsStablePath() {
        var probedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: "/private/tmp/bree.sock",
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { socketPath in
                probedPath = socketPath
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { _ in false }
        )

        #expect(probedPath == "/private/tmp/bree.sock")
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchUsesTransportReclaimabilityForSameUserSocket() {
        var didProbe = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { _ in
                didProbe = true
                return false
            }
        )

        #expect(didProbe)
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialStableLaunchKeepsStablePathWhenTransportReclaimsSameUserSocket() {
        var reclaimedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .socket(ownerUserID: 501) },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                reclaimedPath = socketPath
                return true
            }
        )

        #expect(reclaimedPath == SocketControlSettings.stableDefaultSocketPath)
        #expect(path == SocketControlSettings.stableDefaultSocketPath)
    }

    @Test func initialStableLaunchKeepsUserScopedPreferredPathWithoutProbing() {
        let userScopedPath = SocketControlSettings.userScopedStableSocketPath(currentUserID: 501)
        var didInspect = false
        var didReclaim = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: userScopedPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                didInspect = true
                return .socket(ownerUserID: 501)
            },
            stableDefaultSocketCanBeReclaimed: { _ in
                didReclaim = true
                return false
            }
        )

        #expect(!didInspect, "User-scoped startup path must not be re-inspected")
        #expect(!didReclaim, "User-scoped startup path must not be reclaimed")
        #expect(path == userScopedPath)
    }

    @Test func initialStableLaunchFallsBackToUserScopedSocketWhenMissingStablePathCannotBeReserved() {
        var reclaimedPath: String?
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: SocketControlSettings.stableDefaultSocketPath,
            bundleIdentifier: "com.bree.app",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in .missing },
            stableDefaultSocketCanBeReclaimed: { socketPath in
                reclaimedPath = socketPath
                return false
            }
        )

        #expect(reclaimedPath == SocketControlSettings.stableDefaultSocketPath)
        #expect(path == SocketControlSettings.userScopedStableSocketPath(currentUserID: 501))
    }

    @Test func initialSocketPathDoesNotProbeForTaggedDebugBuild() {
        let debugPath = "/tmp/bree-debug-tag.sock"
        var didInspect = false
        let path = SocketControlSettings.initialSocketPathBeforeListenerStart(
            preferredPath: debugPath,
            bundleIdentifier: "com.bree.app.debug.tag",
            isDebugBuild: false,
            currentUserID: 501,
            probeStableDefaultPathEntry: { _ in
                didInspect = true
                return .socket(ownerUserID: 501)
            }
        )

        #expect(!didInspect, "Tagged debug builds must not inspect the stable socket")
        #expect(path == debugPath)
    }

    // MARK: - Untagged-debug launch gate

    @Test func untaggedDebugBundleAllowedWithLaunchTag() {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: ["BREE_TAG": "tests-v1"],
                bundleIdentifier: "com.bree.app.debug",
                isDebugBuild: true
            )
        )
    }

    @Test func releaseBuildOfADebugBundleIgnoresLaunchTagGate() {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: [:],
                bundleIdentifier: "com.bree.app.debug",
                isDebugBuild: false
            )
        )
    }

    @Test(arguments: [
        ["XCTestConfigurationFilePath": "/tmp/fake.xctestconfiguration"],
        ["XCInjectBundle": "/tmp/fake.xctest"],
        ["DYLD_INSERT_LIBRARIES": "/usr/lib/libXCTestBundleInject.dylib"],
        // XCUITest launches the app as a separate process without XCTest env
        // vars; the app receives BREE_UI_TEST_* via XCUIApplication.launchEnvironment.
        ["BREE_UI_TEST_MODE": "1"],
    ])
    func testHarnessLaunchesIgnoreLaunchTagGate(environment: [String: String]) {
        #expect(
            !SocketControlSettings.shouldBlockUntaggedDebugLaunch(
                environment: environment,
                bundleIdentifier: "com.bree.app.debug",
                isDebugBuild: true
            )
        )
    }
}
