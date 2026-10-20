import BreeBrowser
import BreeCore
import BreeRemoteWorkspace
import BreeSettings
import Foundation
import Testing
#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif
/// Each resource owner receives its own forced-preference resolver. No test
/// can replace another test's policy, or bypass the production resolver.
@MainActor
struct ManagedCapabilityPolicyGateTests {
    private func policy(_ key: ManagedDevicePolicyKey, disabled: Bool) -> ManagedDevicePolicy {
        ManagedDevicePolicy(releaseDomainDefaults: nil, forcedObject: { _, candidate in
            candidate == key.rawValue ? disabled : nil
        })
    }
    private func remoteConfiguration() -> WorkspaceRemoteConfiguration {
        WorkspaceRemoteConfiguration(
            destination: "vm:managed-policy-test",
            port: nil,
            identityFile: nil,
            sshOptions: [],
            localProxyPort: nil,
            relayPort: nil,
            relayID: nil,
            relayToken: nil,
            localSocketPath: nil,
            terminalStartupCommand: "bree vm-pty-attach --id managed-policy-test"
        )
    }

    @Test(arguments: [false, true])
    func remoteConnectionsHonorForcedPreferences(disabled: Bool) {
        let workspace = Workspace(managedDevicePolicy: policy(.disableRemoteConnections, disabled: disabled))
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true) == !disabled)
        #expect((workspace.remoteConfiguration != nil) == !disabled)
    }

    @Test func liftingThePolicyRestoresRemoteConnectionsWithoutARelaunch() throws {
        let suite = "ManagedCapabilityPolicyGateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let workspace = Workspace(managedDevicePolicy: resolver)
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(!workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
    }

    @Test func aRetainedConfigurationCannotRedialUnderThePolicy() throws {
        let suite = "ManagedCapabilityPolicyGateTests.reconnect.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let workspace = Workspace(managedDevicePolicy: resolver)
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
        // A user-initiated disconnect keeps the configuration for "Reconnect".
        workspace.disconnectRemoteConnection(clearConfiguration: false)
        #expect(workspace.remoteConfiguration != nil)
        #expect(workspace.remoteConnectionState == .disconnected)

        // The policy lands while the workspace is disconnected: the retained
        // configuration must not dial, whichever affordance asks.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(!workspace.reconnectRemoteConnection())
        #expect(workspace.remoteConnectionState == .disconnected)

        // The enforcement path drops the configuration and says why.
        workspace.disconnectRemoteConnection(
            clearConfiguration: true,
            disconnectedDetail: ManagedRemoteConnectionsPolicy.disabledMessage
        )
        #expect(workspace.remoteConfiguration == nil)
        #expect(workspace.remoteConnectionDetail == ManagedRemoteConnectionsPolicy.disabledMessage)

        // Lifting the policy restores the reconnect path without a relaunch.
        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        #expect(workspace.configureRemoteConnection(remoteConfiguration(), autoConnect: true))
        workspace.disconnectRemoteConnection(clearConfiguration: false)
        _ = workspace.reconnectRemoteConnection()
        // The websocket transport with no daemon endpoint reports connected
        // as soon as it is configured; the point is that it dialed at all.
        #expect(workspace.remoteConnectionState != .disconnected)
    }
    @Test func theObserverEndsLiveRemoteConnectionsOnActivationOnly() throws {
        let suite = "ManagedCapabilityPolicyGateTests.observer.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let center = NotificationCenter()
        let recorder = RemoteConnectionsEnforcementRecorder()
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        var socketPolicy = SocketControlPolicyResolution(mode: .allowAll, configuredMode: .allowAll, source: .userDefaults)
        var socketReconciliations = 0
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            isBrowserDisabledByPolicy: { false },
            socketControlPolicy: { socketPolicy },
            capabilityPolicy: resolver,
            enforceBrowserPolicy: {},
            enforceBrowserURLAllowlistPolicy: {},
            enforceRemoteConnectionsPolicy: { recorder.recordEnforcement() },
            enforceSocketControlPolicy: { socketReconciliations += 1 }
        )
        #expect(recorder.enforcements == 0)

        defaults.set(true, forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        observer.reevaluate()
        #expect(recorder.enforcements == 1)
        #expect(recorder.changeSignals == 1)
        observer.reevaluate()
        #expect(recorder.enforcements == 1)

        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableRemoteConnections.rawValue)
        observer.reevaluate()
        #expect(recorder.enforcements == 1)
        #expect(recorder.changeSignals == 2)

        defaults.set(true, forKey: ManagedDevicePolicyKey.disableFileTransfer.rawValue)
        observer.reevaluate()
        #expect(recorder.enforcements == 1)
        #expect(recorder.changeSignals == 3)
        socketPolicy = SocketControlPolicyResolution(mode: .breeOnly, configuredMode: .allowAll, source: .managedReleaseDomain, forcedValueStatus: "valid")
        observer.reevaluate()
        #expect(socketReconciliations == 1)
        #expect(recorder.changeSignals == 4)
        observer.reevaluate(); #expect(socketReconciliations == 1)
        withExtendedLifetime(observer) {}
    }
    @Test func aProfileForcedBeforeLaunchEndsRemoteConnectionsAtConstruction() {
        let recorder = RemoteConnectionsEnforcementRecorder()
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: NotificationCenter(),
            isBrowserDisabledByPolicy: { false },
            capabilityPolicy: policy(.disableRemoteConnections, disabled: true),
            enforceBrowserPolicy: {},
            enforceBrowserURLAllowlistPolicy: {},
            enforceRemoteConnectionsPolicy: { recorder.recordEnforcement() }
        )
        #expect(recorder.enforcements == 1)
        observer.reevaluate()
        #expect(recorder.enforcements == 1)
        withExtendedLifetime(observer) {}
    }

    @Test func aCustomUploadCommandCannotBypassTheFileTransferGate() async throws {
        // A `terminal.uploadCommands` rule takes ownership of detected-SSH
        // uploads before the built-in transport. Under the policy it must
        // refuse — without consulting rules, and without spawning anything.
        let spawned = SpawnRecorder()
        let runner = TerminalCustomUploadRunner(
            runProcess: { _, _, _, _ in
                spawned.record()
                return (status: 0, stdout: "", stderr: "")
            },
            isFileTransferDisabled: { true }
        )
        let session = DetectedSSHSession(
            destination: "user@example.com",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )
        let operation = TerminalImageTransferOperation()
        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<Result<String, Error>, Never>) in
            let handled = runner.handleIfMatched(
                plan: .uploadFiles([URL(fileURLWithPath: "/tmp/managed-policy-payload.txt")], .detectedSSH(session)),
                operation: operation,
                cleanup: { _ in },
                completion: { continuation.resume(returning: $0) }
            )
            #expect(handled)
        }
        guard case .failure(let error) = outcome else {
            Issue.record("custom upload ran under DisableFileTransfer")
            return
        }
        #expect(ManagedFileTransferPolicy.isRefusal(error))
        #expect(spawned.count == 0)

        // With the policy off and no rule configured, the runner declines and
        // the built-in transport keeps ownership, exactly as before.
        let permissive = TerminalCustomUploadRunner(
            runProcess: { _, _, _, _ in (status: 0, stdout: "", stderr: "") },
            isFileTransferDisabled: { false }
        )
        #expect(!permissive.handleIfMatched(
            plan: .uploadFiles([URL(fileURLWithPath: "/tmp/managed-policy-payload.txt")], .detectedSSH(session)),
            operation: TerminalImageTransferOperation(),
            cleanup: { _ in },
            completion: { _ in }
        ))
    }

    @Test func tlsTrustBypassIsNeitherOfferedNorHonoredUnderThePolicy() throws {
        let allowed = PolicyFlag(value: true)
        let state = BrowserSSLTrustBypassState(isBypassAllowed: { allowed.value })
        let url = try #require(URL(string: "https://self-signed.internal/report"))
        let scope = try #require(BrowserSSLTrustScope(url: url))
        let fingerprint = BrowserServerTrustFingerprint(sha256: Data("leaf-a".utf8))
        state.recordObservedServerTrustFingerprint(fingerprint, for: scope)

        // A grant taken before the profile landed is not honored after it.
        let action = try #require(state.createPendingBypassAction(for: URLRequest(url: url)))
        #expect(state.consumePendingBypassAction(action) != nil)
        #expect(state.isBypassed(scope: scope, fingerprint: fingerprint))
        allowed.value = false
        #expect(!state.isBypassed(scope: scope, fingerprint: fingerprint))
        #expect(state.createPendingBypassAction(for: URLRequest(url: url)) == nil)

        // Lifting the policy restores the user's earlier grant.
        allowed.value = true
        #expect(state.isBypassed(scope: scope, fingerprint: fingerprint))
    }

    @Test func automationWebhooksFailClosedWithoutTouchingTheNetwork() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("managed-webhook-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutomationConfigStore(fileURL: directory.appendingPathComponent("automations.json"))
        try store.save(AutomationConfiguration(rules: [
            AutomationRule(
                id: "webhook-policy",
                when: AutomationWhen(event: "workspace.created"),
                actions: [AutomationAction(
                    action: "webhook",
                    parameters: ["url": .string("https://hooks.example.test/bree")]
                )]
            )
        ]))
        let bus = BreeEventBus(retainedEventLimit: 32)
        let calls = SpawnRecorder()
        let engine = AutomationEngine(
            configStore: store,
            eventBus: bus,
            webhookRunner: { _, _, _ in
                calls.record()
                return .success()
            },
            isWebhookDisabledByPolicy: { true }
        )
        defer { engine.stop() }
        engine.start()
        var loaded = false
        for _ in 0..<250 {
            if engine.rule(withID: "webhook-policy") != nil { loaded = true; break }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(loaded)

        bus.publish(name: "workspace.created", category: "workspace", source: "managed-policy-test")

        var refused = false
        for _ in 0..<250 {
            refused = engine.logsPayload(limit: 32).contains {
                ($0["rule_id"] as? String) == "webhook-policy" && ($0["status"] as? String) == "error"
            }
            if refused { break }
            try await ContinuousClock().sleep(for: .milliseconds(20))
        }
        #expect(refused)
        #expect(calls.count == 0)
    }

    @Test func settingsVisiblePoliciesPostChangeSignals() throws {
        let suite = "ManagedCapabilityPolicyGateTests.visible.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let resolver = ManagedDevicePolicy(defaults: defaults, releaseDomainDefaults: nil, forcedObject: { store, key in
            store.object(forKey: key)
        })
        let center = NotificationCenter()
        let recorder = RemoteConnectionsEnforcementRecorder()
        let token = center.addObserver(
            forName: ManagedDevicePolicy.didChangeNotification,
            object: nil,
            queue: nil
        ) { _ in recorder.recordChangeSignal() }
        defer { center.removeObserver(token) }
        let observer = ManagedPolicyEnforcementObserver(
            notificationCenter: center,
            isBrowserDisabledByPolicy: { false },
            capabilityPolicy: resolver,
            enforceBrowserPolicy: {},
            enforceBrowserURLAllowlistPolicy: {}
        )

        // An automation-webhook push is Settings-visible only.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableAutomationWebhooks.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 1)

        // Custom sidebars signal on both directions.
        defaults.set(true, forKey: ManagedDevicePolicyKey.disableCustomSidebars.rawValue)
        observer.reevaluate()
        #expect(recorder.changeSignals == 2)
        defaults.removeObject(forKey: ManagedDevicePolicyKey.disableCustomSidebars.rawValue)
        observer.reevaluate()
        observer.reevaluate()
        #expect(recorder.changeSignals == 3)
        withExtendedLifetime(observer) {}
    }

    @Test func remoteDropUploadFailsClosedUnderThePolicy() throws {
        let workspace = Workspace(managedDevicePolicy: policy(.disableFileTransfer, disabled: true))
        var outcome: Result<[String], Error>?
        workspace.uploadDroppedFilesForRemoteTerminal(
            [URL(fileURLWithPath: "/tmp/managed-policy-payload.txt")],
            operation: TerminalImageTransferOperation()
        ) { outcome = $0 }
        let result = try #require(outcome)
        guard case .failure(let error) = result else {
            Issue.record("upload succeeded under DisableFileTransfer")
            return
        }
        #expect((error as NSError).localizedDescription == ManagedFileTransferPolicy.disabledMessage)
    }

    @Test func detectedSSHUploadRefusesBeforeRunningAnyProcess() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("managed-file-transfer-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("payload.txt")
        try Data("payload".utf8).write(to: fileURL)

        let session = DetectedSSHSession(
            destination: "user@example.com",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: []
        )

        do {
            _ = try session.uploadDroppedFilesSync(
                [fileURL],
                operation: TerminalImageTransferOperation(),
                managedDevicePolicy: policy(.disableFileTransfer, disabled: true)
            )
            Issue.record("detected SSH upload succeeded under DisableFileTransfer")
        } catch {
            #expect((error as NSError).domain == "bree.managedPolicy.fileTransfer")
            #expect(error.localizedDescription == ManagedFileTransferPolicy.disabledMessage)
        }
    }

}

/// A policy switch a test flips between calls of an injected resolver.
private final class PolicyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(value: Bool) { stored = value }
    var value: Bool {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Counts process spawns the custom upload runner attempted.
private final class SpawnRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var spawnCount = 0
    var count: Int { lock.withLock { spawnCount } }
    func record() { lock.withLock { spawnCount += 1 } }
}

/// Counts remote-connections enforcement runs and Settings change signals.
private final class RemoteConnectionsEnforcementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var enforcementCount = 0
    private var changeSignalCount = 0

    var enforcements: Int { lock.withLock { enforcementCount } }
    var changeSignals: Int { lock.withLock { changeSignalCount } }

    func recordEnforcement() { lock.withLock { enforcementCount += 1 } }
    func recordChangeSignal() { lock.withLock { changeSignalCount += 1 } }
}
