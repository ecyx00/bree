import AppKit
import BreeSettings
import Foundation

/// Applies MDM managed-policy transitions to a running app.
///
/// When the embedded-browser policy activates it runs the injected browser
/// enforcement (closing live browser panes) and posts
/// `BrowserAvailabilitySettings.didChangeNotification` so gated UI refreshes;
/// when the remote-connections
/// policy activates it runs the injected remote-connections enforcement
/// (disconnecting live remote workspaces and remote tmux mirrors), also at
/// construction. Every transition also posts
/// `ManagedDevicePolicy.didChangeNotification` so Settings UI re-reads the
/// resolver.
///
/// Managed-preference pushes do not reliably fire
/// `UserDefaults.didChangeNotification`, so the observer also re-evaluates on
/// app activation and on a periodic cadence (``recheckInterval``) — an MDM
/// push against a Mac that stays frontmost is enforced within one interval,
/// not only at the next activation.
@MainActor
final class ManagedPolicyEnforcementObserver {
    /// Upper bound on enforcement latency for out-of-band MDM pushes that
    /// fire no local notification. Justified periodic re-check: there is no
    /// callback API for managed-preference changes, and an enforcement
    /// deadline is the intended behavior (matches MDM check-in semantics).
    static let recheckInterval: Duration = .seconds(60)
    private let notificationCenter: NotificationCenter
    private let isBrowserDisabledByPolicy: () -> Bool
    private let browserURLAllowlistPolicy: () -> BrowserURLAllowlistPolicy
    private let socketControlPolicy: () -> SocketControlPolicyResolution
    private let capabilityPolicy: ManagedDevicePolicy
    private let enforceBrowserPolicy: () -> Void
    private let enforceBrowserURLAllowlistPolicy: () -> Void
    private let enforceRemoteConnectionsPolicy: () -> Void
    private let enforceSocketControlPolicy: () -> Void
    /// Keys whose runtime effect is a per-call read, a launch-time read, or a
    /// Settings lock: a transition only needs the change signal.
    private static let settingsVisibleKeys: [ManagedDevicePolicyKey] = [
        .disableAutomationWebhooks,
        .disableTLSTrustBypass, .disableCustomSidebars,
        .disableAICredentialUpload,
    ]
    private var settingsVisiblePolicyStates: [ManagedDevicePolicyKey: Bool]
    private var browserPolicyActive: Bool
    private var observedBrowserURLAllowlistPolicy: BrowserURLAllowlistPolicy
    private var remoteConnectionsPolicyActive: Bool
    private var fileTransferPolicyActive: Bool
    private var socketControlPolicyState: SocketControlPolicyResolution
    private var observationTasks: [Task<Void, Never>] = []

    init(
        notificationCenter: NotificationCenter = .default,
        isBrowserDisabledByPolicy: @escaping () -> Bool = {
            BrowserAvailabilitySettings.isManagedByPolicy
        },
        browserURLAllowlistPolicy: @escaping () -> BrowserURLAllowlistPolicy = {
            BrowserURLAllowlistPolicy(defaults: .standard)
        },
        socketControlPolicy: @escaping () -> SocketControlPolicyResolution = {
            SocketControlPolicyResolver().resolve()
        },
        capabilityPolicy: ManagedDevicePolicy = ManagedDevicePolicy(),
        enforceBrowserPolicy: @escaping () -> Void,
        enforceBrowserURLAllowlistPolicy: @escaping () -> Void,
        enforceRemoteConnectionsPolicy: @escaping () -> Void = {},
        enforceSocketControlPolicy: @escaping () -> Void = {}
    ) {
        self.notificationCenter = notificationCenter
        self.isBrowserDisabledByPolicy = isBrowserDisabledByPolicy
        self.browserURLAllowlistPolicy = browserURLAllowlistPolicy
        self.socketControlPolicy = socketControlPolicy
        self.capabilityPolicy = capabilityPolicy
        self.enforceBrowserPolicy = enforceBrowserPolicy
        self.enforceBrowserURLAllowlistPolicy = enforceBrowserURLAllowlistPolicy
        self.enforceRemoteConnectionsPolicy = enforceRemoteConnectionsPolicy
        self.enforceSocketControlPolicy = enforceSocketControlPolicy
        settingsVisiblePolicyStates = Self.settingsVisibleStates(capabilityPolicy)
        browserPolicyActive = isBrowserDisabledByPolicy()
        observedBrowserURLAllowlistPolicy = browserURLAllowlistPolicy()
        remoteConnectionsPolicyActive = capabilityPolicy.isEnforced(.disableRemoteConnections)
        fileTransferPolicyActive = capabilityPolicy.isEnforced(.disableFileTransfer)
        socketControlPolicyState = socketControlPolicy()
        if remoteConnectionsPolicyActive {
            // Same for remote connections: nothing bree created may stay dialed.
            enforceRemoteConnectionsPolicy()
        }
        observe(UserDefaults.didChangeNotification)
        observe(NSApplication.didBecomeActiveNotification)
        observationTasks.append(Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.recheckInterval)
                } catch {
                    break
                }
                guard let self else { break }
                self.reevaluate()
            }
        })
    }

    deinit {
        observationTasks.forEach { $0.cancel() }
    }

    private static func settingsVisibleStates(_ policy: ManagedDevicePolicy) -> [ManagedDevicePolicyKey: Bool] {
        Dictionary(uniqueKeysWithValues: settingsVisibleKeys.map { ($0, policy.isEnforced($0)) })
    }

    private func observe(_ name: Notification.Name) {
        let center = notificationCenter
        observationTasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: name) {
                guard let self else { break }
                self.reevaluate()
            }
        })
    }

    /// Compares the current policy state to the last-seen state and runs the
    /// matching enforcement on a transition. Exposed for tests and for the
    /// startup call after construction.
    func reevaluate() {
        var anyTransition = false
        let browserNow = isBrowserDisabledByPolicy()
        if browserNow != browserPolicyActive {
            browserPolicyActive = browserNow
            anyTransition = true
            if browserNow {
                enforceBrowserPolicy()
            }
            // Both directions change the effective availability of gated UI.
            notificationCenter.post(
                name: BrowserAvailabilitySettings.didChangeNotification,
                object: nil
            )
        }
        let browserURLAllowlistNow = browserURLAllowlistPolicy()
        if browserURLAllowlistNow != observedBrowserURLAllowlistPolicy {
            observedBrowserURLAllowlistPolicy = browserURLAllowlistNow
            anyTransition = true
            enforceBrowserURLAllowlistPolicy()
        }
        let remoteConnectionsNow = capabilityPolicy.isEnforced(.disableRemoteConnections)
        if remoteConnectionsNow != remoteConnectionsPolicyActive {
            remoteConnectionsPolicyActive = remoteConnectionsNow
            anyTransition = true
            // Activation ends every live bree-created remote connection; a
            // lift needs no enforcement because the per-call gates read the
            // resolver on the next connect.
            if remoteConnectionsNow { enforceRemoteConnectionsPolicy() }
        }
        let fileTransferNow = capabilityPolicy.isEnforced(.disableFileTransfer)
        if fileTransferNow != fileTransferPolicyActive {
            // Transfers are momentary: nothing live to tear down, the next
            // upload reads the resolver.
            fileTransferPolicyActive = fileTransferNow
            anyTransition = true
        }
        let socketControlPolicyNow = socketControlPolicy()
        if socketControlPolicyNow != socketControlPolicyState {
            socketControlPolicyState = socketControlPolicyNow
            anyTransition = true
            // Reconcile through the same app-owned path used by Settings,
            // bree.json reloads, and startup. SocketControlServer rotates its
            // authorization generation before accepting the new mode, which
            // revokes every old command and event-stream client.
            enforceSocketControlPolicy()
        }
        let settingsVisibleNow = Self.settingsVisibleStates(capabilityPolicy)
        if settingsVisibleNow != settingsVisiblePolicyStates {
            settingsVisiblePolicyStates = settingsVisibleNow
            anyTransition = true
        }
        if anyTransition {
            // Settings UI re-reads the resolver on this signal.
            notificationCenter.post(
                name: ManagedDevicePolicy.didChangeNotification,
                object: nil
            )
        }
    }
}
