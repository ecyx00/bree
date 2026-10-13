import BreeCloud
import BreeFoundation
import BREEAuthCore
import BreeAuthRuntime
import AppKit
import Foundation
import Network
import StackAuth

/// The macOS auth composition root.
///
/// Constructs the de-singletonized auth graph once at app startup, mirroring
/// the iOS `MobileAuthComposition`: the keychain/file fallback token store, a
/// `StackClientApp` over it (wrapped in ``BreeAuthRuntime/StackAuthClient``),
/// the shared ``BreeAuthRuntime/AuthCoordinator`` bound to the historical mac
/// defaults keys, and the ``HostBrowserSignInFlow``. Replaces
/// `AuthManager.shared`.
@MainActor
struct MacAuthComposition {
    /// The shared auth orchestrator (session state, tokens, teams).
    let coordinator: AuthCoordinator
    /// Recognizes/parses auth callback URLs (AppDelegate URL routing).
    let callbackRouter: AuthCallbackRouter
    /// The token store the Stack client persists through.
    let tokenStore: any StackAuthTokenStoreProtocol
    /// The hosted-browser sign-in flow used by app-session recovery.
    let browserSignIn: HostBrowserSignInFlow
    /// Bridges the native Stack session into explicitly opened bree web panes.
    let browserAppSession: BrowserAppSessionController
    /// Shared observable account projection used by Settings and sidebar UI.
    let accountFlow: HostAccountFlow
    /// Reconciles Cloud transports with the coordinator's selected team.
    let cloudTeamScopeObserver: CloudTeamScopeObserver
    let teamScopeRecoveryTriggers: MacAuthTeamScopeRecoveryTriggers

    /// Build the auth graph.
    /// - Parameters:
    ///   - environment: The process environment (UI-test launch options).
    ///   - defaults: Persistence for the cached user / has-tokens flag /
    ///     selected team (historical `bree.auth.*` keys).
    init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        defaults: UserDefaults = .standard
    ) {
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let resolvedAuthEnvironment = AuthEnvironment.resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackProjectID = AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let stackPublishableClientKey = AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: Self.isDebugBuild
        )
        let tokenStore = FallbackTokenStore(
            primary: KeychainStackTokenStore(
                service: KeychainStackTokenStore.serviceName(bundleIdentifier: bundleIdentifier)
            ),
            fallback: FileStackTokenStore(directory: Self.credentialsDirectory(bundleIdentifier: bundleIdentifier))
        )
        self.tokenStore = tokenStore

        // Auth starts and stays signed out: drop any cached identity so the
        // coordinator primes as signed out and nothing tries to restore it.
        for key in ["bree.auth.cachedUser", "bree.auth.hasTokens", "bree.auth.selectedTeamID"] {
            defaults.removeObject(forKey: key)
        }
        let userCache = BREEAuthIdentityStore(
            keyValueStore: defaults,
            key: "bree.auth.cachedUser"
        )
        let sessionCache = BREEAuthSessionCache(
            keyValueStore: defaults,
            key: "bree.auth.hasTokens"
        )

        let config = AuthConfig(
            stack: BREEAuthConfig(
                projectId: stackProjectID,
                publishableClientKey: stackPublishableClientKey
            ),
            magicLinkCallbackURL: AuthEnvironment.websiteOrigin
                .appendingPathComponent("auth/callback", isDirectory: false)
                .absoluteString,
            apiBaseURL: AuthEnvironment.apiBaseURL.absoluteString
        )
        // Bree is local-only: auth stays signed out and never builds a Stack
        // client, so nothing here can read a stored token or touch the network.
        let client: any AuthClient = SignedOutAuthClient()
        let resolvedEnvironment: [String: String] = [:]
        let authProjectSwitched = Self.detectAuthProjectSwitch(
            resolvedProjectID: stackProjectID,
            buildDefaultProjectID: AuthEnvironment.resolvedStackProjectID(
                environment: [:],
                isDebugBuild: Self.isDebugBuild
            ),
            defaults: defaults
        )
        let includesDevAuth = Self.includesDevAuth(
            resolvedAuthEnvironment: resolvedAuthEnvironment
        )
        let replacesStoredDevSession = includesDevAuth
            && resolvedEnvironment["BREE_DEV_AUTH_CREDENTIALS_RESOLVED"] == "1"
        let launch = AuthLaunchOptions(
            clearAuthRequested: resolvedEnvironment["BREE_UITEST_CLEAR_AUTH"] == "1",
            mockDataEnabled: false,
            environment: resolvedEnvironment,
            includesDevAuth: includesDevAuth,
            clearStaleAuthOnLaunch: authProjectSwitched,
            replaceStoredSessionWithAutoLogin: replacesStoredDevSession
        )

        let anchor = AuthPresentationContextProvider()
        let browserAppSessionSignInRelay = BrowserAppSessionSignInRelay()
        let coordinator = AuthCoordinator(
            client: client,
            sessionCache: sessionCache,
            userCache: userCache,
            teamSelection: BREEAuthTeamSelectionStore(
                keyValueStore: defaults,
                key: "bree.auth.selectedTeamID"
            ),
            anchor: anchor,
            config: config,
            launch: launch,
            onSessionWillTransition: {
                browserAppSessionSignInRelay.sessionWillTransition()
            },
            onSignedIn: {
                await BreeTuiSurfaceProviderRegistry.shared.resumeAfterSignIn()
                await browserAppSessionSignInRelay.signedIn()
            }
        )
        self.coordinator = coordinator
        let browserAppSession = BrowserAppSessionController(
            coordinator: coordinator,
            webOrigin: AuthEnvironment.appSessionHandoffOrigin,
            projectID: stackProjectID,
            defaults: defaults
        )
        self.browserAppSession = browserAppSession
        browserAppSessionSignInRelay.bind(
            beginTransition: { [weak browserAppSession] in
                browserAppSession?.beginAuthTransition()
            },
            resume: { [weak browserAppSession] in
                await browserAppSession?.resumeAfterSignIn()
            }
        )
        let callbackRouter = AuthCallbackRouter(
            extraAllowedScheme: AuthEnvironment.callbackScheme
        )
        self.callbackRouter = callbackRouter
        let browserSignIn = HostBrowserSignInFlow(
            coordinator: coordinator,
            tokenStore: tokenStore,
            sessionFactory: ASWebBrowserAuthSessionFactory(anchor: anchor),
            callbackRouter: callbackRouter,
            makeSignInURL: { AuthEnvironment.signInURL(callbackState: $0) },
            callbackScheme: { AuthEnvironment.callbackScheme },
            // Single chokepoint for every sign-in entry point (settings, menu,
            // auth.* socket, `bree auth`): Bree never opens a sign-in page.
            openExternalURL: { _ in false },
            approveUnsolicitedCallback: { _ in false },
            beginSignOut: {
                // Tell surface observers to drop account-scoped state
                // before the coordinator clears auth.
                NotificationCenter.default.post(name: .breeCloudVMAccessDidEnd, object: AppDelegate.shared)
                browserAppSession.beginAuthTransition()
            },
            localSignOut: {
                await browserAppSession.clearBreeWebSession()
            }
        )
        self.browserSignIn = browserSignIn
        self.accountFlow = HostAccountFlow(
            coordinator: coordinator,
            browserSignIn: browserSignIn
        )
        self.teamScopeRecoveryTriggers = MacAuthTeamScopeRecoveryTriggers(coordinator: coordinator)
        self.cloudTeamScopeObserver = CloudTeamScopeObserver(auth: coordinator) { isSameAccount in
            // Same-account team switches keep Cloud state; an account change drops it.
            guard !isSameAccount else { return }
            NotificationCenter.default.post(name: .breeCloudVMAccessDidEnd, object: AppDelegate.shared)
        }
    }

    /// Intentionally empty: Bree never restores a session at launch.
    func start() {}

    /// Where the file-fallback token store persists, namespaced by bundle id
    /// (matching the pre-package layout so existing sessions survive).
    private static func credentialsDirectory(bundleIdentifier: String?) -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return BreeIdentity.current.applicationSupportDirectory(in: support)
            .appendingPathComponent(bundleIdentifier ?? "bree", isDirectory: true)
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    private static func includesDevAuth(
        resolvedAuthEnvironment: BREEAuthEnvironment
    ) -> Bool {
        isDebugBuild && resolvedAuthEnvironment == .development
    }

    nonisolated static let storedStackProjectIDKey = "bree.auth.stackProjectID"

    /// Keep cached identities and Stack tokens from crossing projects when one
    /// tagged Debug bundle is rebuilt with `--prod-auth`, or switched back.
    nonisolated static func detectAuthProjectSwitch(
        resolvedProjectID: String,
        buildDefaultProjectID: String,
        defaults: UserDefaults
    ) -> Bool {
        let previous = defaults.string(forKey: storedStackProjectIDKey) ?? buildDefaultProjectID
        defaults.set(resolvedProjectID, forKey: storedStackProjectIDKey)
        return previous != resolvedProjectID
    }
}

/// Auth client for a local-only app: no session, no tokens, no network.
struct SignedOutAuthClient: AuthClient {
    func accessToken() async -> String? { nil }
    func resolvedAccessToken(forceRefresh: Bool) async throws -> String? { nil }
    func refreshToken() async -> String? { nil }
    func forceRefreshAccessToken() async -> String? { nil }
    func currentUser(throwOnMissing: Bool) async throws -> BREEAuthUser? { nil }
    func listTeams() async throws -> [BREEAuthTeam] { [] }
    func sendMagicLinkEmail(email: String, callbackURL: String) async throws -> String {
        throw AuthClientError.unsupported
    }
    func signInWithMagicLink(code: String) async throws { throw AuthClientError.unsupported }
    func signInWithCredential(email: String, password: String) async throws {
        throw AuthClientError.unsupported
    }
    func signInWithOAuth(provider: String, anchor: any AuthPresentationAnchoring) async throws {
        throw AuthClientError.unsupported
    }
    func storedAccessToken() async -> String? { nil }
    func clearLocalSession() async {}
    func clearLocalSession(ifRefreshTokenMatches refreshToken: String) async {}
    func revokeSession(accessToken: String?, refreshToken: String?) async throws {}
    func freshAccessToken(accessToken: String?, refreshToken: String) async -> String? { nil }
}

/// Retries a missing team scope when a retry is likely to succeed.
///
/// macOS has no foreground revalidation like iOS, and a login-item launch
/// often runs before the network is up. The coordinator's backoff loop is the
/// guarantee; these signals (network path restored, system wake, app
/// activation) only shorten the wait. Each call is a no-op for a healthy
/// session.
@MainActor
final class MacAuthTeamScopeRecoveryTriggers {
    private let coordinator: AuthCoordinator
    private let pathMonitor = NWPathMonitor()
    private var tasks: [Task<Void, Never>] = []

    init(coordinator: AuthCoordinator) {
        self.coordinator = coordinator
    }

    func start() {
        guard tasks.isEmpty else { return }
        let notifications: [(NotificationCenter, Notification.Name)] = [
            (NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification),
            (NotificationCenter.default, NSApplication.didBecomeActiveNotification),
        ]
        for (center, name) in notifications {
            tasks.append(Task { @MainActor [weak self] in
                for await _ in center.notifications(named: name) {
                    await self?.coordinator.recoverTeamScopeIfNeeded()
                }
            })
        }
        let (pathSatisfied, continuation) = AsyncStream<Bool>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        pathMonitor.pathUpdateHandler = { path in
            continuation.yield(path.status == .satisfied)
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.bree.auth.team-scope-path"))
        tasks.append(Task { @MainActor [weak self] in
            var wasSatisfied = false
            for await satisfied in pathSatisfied {
                defer { wasSatisfied = satisfied }
                guard satisfied, !wasSatisfied else { continue }
                await self?.coordinator.recoverTeamScopeIfNeeded()
            }
        })
    }
}

/// Native confirmation shown before a stateless auth callback that bree did
/// not request (for example a `bree://auth-callback` link opened by a web
/// page) may sign the app in. Declining is the default action.
@MainActor
enum UnsolicitedAuthCallbackApprovalPrompt {
    static func present(_ request: UnsolicitedAuthCallbackApprovalRequest) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = request.replacesSignedInSession ? .critical : .warning
        alert.messageText = title(for: request)
        alert.informativeText = message(for: request)
        // The first button is the default (Return) action, so declining is the
        // path of least resistance.
        alert.addButton(withTitle: String(
            localized: "account.callbackApproval.cancel",
            defaultValue: "Don\u{2019}t Sign In"
        ))
        alert.addButton(withTitle: request.replacesSignedInSession
            ? String(localized: "account.callbackApproval.replace.confirm", defaultValue: "Switch Account")
            : String(localized: "account.callbackApproval.confirm", defaultValue: "Sign In"))
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    private static func title(for request: UnsolicitedAuthCallbackApprovalRequest) -> String {
        if request.replacesSignedInSession {
            return String(
                localized: "account.callbackApproval.replace.title",
                defaultValue: "Switch Bree to another account?"
            )
        }
        return String(
            localized: "account.callbackApproval.title",
            defaultValue: "Sign in to Bree from a link?"
        )
    }

    private static func message(for request: UnsolicitedAuthCallbackApprovalRequest) -> String {
        let account = String(
            localized: "account.callbackApproval.message.unknown",
            defaultValue: "A link is asking Bree to sign in to an account. Continue only if you just signed in to Bree in your browser."
        )
        guard request.replacesSignedInSession else { return account }
        let warning = String(
            localized: "account.callbackApproval.replace.generic",
            defaultValue: "You\u{2019}re already signed in. Continuing replaces that session, and new Bree activity will belong to the account in the link. If you didn\u{2019}t just choose this account yourself, click Don\u{2019}t Sign In."
        )
        return "\(account)\n\n\(warning)"
    }
}
