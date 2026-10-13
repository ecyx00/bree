import BREEAuthCore
import BreeFoundation
import Foundation

/// lint:allow namespace-type: moved unchanged from the app target, where it was an internal static namespace; reshaping it is a separate change from this package move.
public enum AuthEnvironment: Sendable {
    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static let developmentStackProjectID = "454ecd03-1db2-4050-845e-4ce5b0cd9895"
    private static let developmentStackPublishableClientKey = "pck_xb63160bwe9699vtxfzfj6emmxpafg5mkjrtp6ehzxv5g"
    private static let productionStackProjectID = "9790718f-14cd-4f7e-824d-eaf527a82b82"
    private static let productionStackPublishableClientKey = "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr"

    /// Debug-only values that may be changed after the app is built. The file
    /// is intentionally an allowlist of routing/channel knobs, never secrets.
    /// It wins over inherited process variables because launchers commonly
    /// inherit a stale port from another tagged bree process.
    private static let debugRuntimeOverrideKeys: [String] = [
        "BREE_API_BASE_URL",
        "BREE_VM_API_BASE_URL",
        "BREE_WWW_ORIGIN",
        "BREE_AUTH_WWW_ORIGIN",
        "BREE_BILLING_WWW_ORIGIN",
        "BREE_STACK_BASE_URL",
        "BREE_STACK_PROJECT_ID",
        "BREE_STACK_PUBLISHABLE_CLIENT_KEY",
        "BREE_AUTH_ENVIRONMENT",
        "BREE_AUTH_CALLBACK_SCHEME",
        "BREE_PORT",
        "PORT",
        "BREE_DEV_BACKEND_TAILSCALE_HOST",
        "BREE_DEV_BACKEND_TRANSPORT",
    ]

    /// The one runtime configuration surface for a Debug app. A file override
    /// is explicit operator state and therefore takes precedence over the
    /// parent process environment; Release never reads it.
    private static var runtimeEnvironment: [String: String] {
        #if DEBUG
        return mergedRuntimeEnvironment(
            environment: ProcessInfo.processInfo.environment,
            fileOverrides: debugRuntimeOverrides()
        )
        #else
        return ProcessInfo.processInfo.environment
        #endif
    }

    /// Merges only the allowlisted local routing/channel values. Keeping this
    /// pure makes the precedence rule testable without touching a developer's
    /// actual home directory or process environment.
    public static func mergedRuntimeEnvironment(
        environment: [String: String],
        fileOverrides: [String: String]
    ) -> [String: String] {
        var merged = environment
        for key in debugRuntimeOverrideKeys {
            if let value = fileOverrides[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                merged[key] = value
            }
        }
        return merged
    }

    private static func debugRuntimeOverrides() -> [String: String] {
        Dictionary(uniqueKeysWithValues: debugRuntimeOverrideKeys.compactMap { key in
            devOverride(key: key).map { (key, $0) }
        })
    }

    public static var callbackScheme: String {
        callbackScheme(
            environment: runtimeEnvironment,
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    public static func callbackScheme(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> String {
        #if DEBUG
        return callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier, isDebugBuild: true)
        #else
        return callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier, isDebugBuild: false)
        #endif
    }

    public static func callbackScheme(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> String {
        if let overridden = environment["BREE_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            // Untagged Debug builds register bree-dev:// so they can coexist
            // with the installed stable app. Tagged Debug builds use
            // bree-dev-<tag>://.
            if let tag = environment["BREE_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedCallbackSchemeTag(tag) {
                return "bree-dev-\(schemeTag)"
            }
            return "bree-dev"
        }
        if bundleIdentifier == "com.bree.app.nightly" { return "bree-nightly" }
        if bundleIdentifier == "com.bree.app.rc" { return "bree-rc" }
        return "bree"
    }

    static func sanitizedCallbackSchemeTag(_ rawTag: String) -> String? {
        let lowercased = rawTag.lowercased()
        var result = ""
        var previousWasHyphen = false
        for scalar in lowercased.unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? nil : result
    }

    public static var callbackURL: URL {
        URL(string: "\(callbackScheme)://auth-callback")!
    }

    static func resolvedCallbackURL(
        environment: [String: String],
        bundleIdentifier: String?
    ) -> URL {
        URL(string: "\(callbackScheme(environment: environment, bundleIdentifier: bundleIdentifier))://auth-callback")!
    }

    public static var websiteOrigin: URL {
        appWebOrigin(environment: runtimeEnvironment)
    }

    /// Pricing page used by every "Upgrade to bree Pro" entrypoint
    /// (Settings, command palette, Help menu). The DEBUG-only
    /// `~/.bree-dev.env` file wins over inherited process values, so a
    /// deeplink-launched dev build can point at the current tagged backend.
    public static var pricingURL: URL {
        resolvedPricingURL(environment: runtimeEnvironment)
    }

    public static func resolvedPricingURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("pricing")
    }

    public static var appPricingURL: URL {
        resolvedAppPricingURL(environment: runtimeEnvironment)
    }

    public static var appWebOrigin: URL {
        resolvedAppWebOrigin(environment: runtimeEnvironment)
    }

    /// Credential-bearing native-to-web handoffs are pinned to github.com/ecyx00/bree in
    /// release builds. Debug builds may additionally use an exact loopback or
    /// owner-provided Tailscale Serve origin, without accepting an arbitrary
    /// launch environment variable as a token destination.
    public static var appSessionHandoffOrigin: URL {
        #if DEBUG
        let isDebugBuild = true
        #else
        let isDebugBuild = false
        #endif
        return resolvedAppSessionHandoffOrigin(
            environment: runtimeEnvironment,
            isDebugBuild: isDebugBuild
        )
    }

    public static func resolvedAppSessionHandoffOrigin(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> URL {
        let productionOrigin = URL(string: "https://github.com/ecyx00/bree")!
        guard isDebugBuild else { return productionOrigin }

        let candidate = canonicalizedLoopbackURL(appWebOrigin(environment: environment))
        if candidate == productionOrigin { return productionOrigin }
        guard let components = URLComponents(
            url: candidate,
            resolvingAgainstBaseURL: false
        ),
              components.user == nil,
              components.password == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil,
              components.fragment == nil else {
            return productionOrigin
        }
        if components.host?.lowercased() == "localhost",
           components.scheme == "http" || components.scheme == "https" {
            return candidate
        }
        guard components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host.hasSuffix(".ts.net"),
              let trustedHost = environment["BREE_DEV_BACKEND_TAILSCALE_HOST"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              trustedHost == host,
              environment["BREE_DEV_BACKEND_TRANSPORT"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "direct",
              let port = components.port,
              (3800...4799).contains(port) else {
            return productionOrigin
        }
        return candidate
    }

    static func resolvedAppWebOrigin(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment)
    }

    public static func resolvedAppPricingURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("app-pricing")
    }

    public static var appProWelcomeURL: URL {
        resolvedAppProWelcomeURL(environment: runtimeEnvironment)
    }

    public static func resolvedAppProWelcomeURL(environment: [String: String]) -> URL {
        appWebOrigin(environment: environment).appendingPathComponent("app-pro-welcome")
    }

    /// Payment entrypoint used by native app UI. `BREE_BILLING_WWW_ORIGIN`
    /// can explicitly pin checkout elsewhere, otherwise checkout follows the
    /// same app web origin as `/app-pricing`. Direct Stripe Checkout binds the
    /// purchaser to the server-created session, so dev builds must start the
    /// request on the same origin that rendered pricing instead of crossing to
    /// production.
    public static var billingCheckoutURL: URL {
        resolvedBillingCheckoutURL(environment: runtimeEnvironment)
    }

    public static func resolvedBillingCheckoutURL(environment: [String: String]) -> URL {
        billingCheckoutURL(
            origin: billingWebsiteOrigin(environment: environment),
            callbackScheme: callbackScheme(environment: environment, bundleIdentifier: nil)
        )
    }

    public static var billingPortalURL: URL {
        resolvedBillingPortalURL(environment: runtimeEnvironment)
    }

    public static func resolvedBillingPortalURL(environment: [String: String]) -> URL {
        billingWebsiteOrigin(environment: environment).appendingPathComponent("api/billing/portal")
    }

    static var signInWebsiteOrigin: URL {
        resolvedAuthWebOrigin(environment: runtimeEnvironment)
    }

    public static var apiBaseURL: URL {
        resolvedAPIBaseURL(
            environment: runtimeEnvironment,
            isDebugBuild: isDebugBuild
        )
    }

    /// Resolve the authenticated web API origin. Release and production-auth
    /// processes are pinned to github.com/ecyx00/bree before reading ambient launch values,
    /// so a stale staging variable cannot redirect credential-bearing traffic.
    public static func resolvedAPIBaseURL(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> URL {
        if !isDebugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: isDebugBuild
            ) == .production {
            return URL(string: "https://github.com/ecyx00/bree")!
        }
        return canonicalizedLoopbackURL(
            resolvedURL(
                environmentKey: "BREE_API_BASE_URL",
                fallback: isDebugBuild
                    ? "http://localhost:\(resolvedBreePort(environment: environment))"
                    : "https://github.com/ecyx00/bree",
                environment: environment
            )
        )
    }

    /// Base URL for the bree-owned cloud VM backend (`/api/vm`).
    ///
    /// Resolution order for Debug (first hit wins):
    ///   1. `~/.bree-dev.env` file `BREE_VM_API_BASE_URL=...` line — explicit
    ///      operator state that works for click-through, Dock, and `open`.
    ///   2. process env `BREE_VM_API_BASE_URL` — useful for one-off launches.
    ///   3. VM backend dev origin (`http://localhost:$BREE_PORT` in Debug, github.com/ecyx00/bree in Release).
    public static var vmAPIBaseURL: URL {
        let environment = runtimeEnvironment
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if !debugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: debugBuild
            ) == .production {
            return URL(string: "https://github.com/ecyx00/bree")!
        }
        if let overridden = environment["BREE_VM_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return canonicalizedLoopbackURL(url)
        }
        if let override = devOverride(key: "BREE_VM_API_BASE_URL"),
           let url = URL(string: override) {
            return canonicalizedLoopbackURL(url)
        }
        return canonicalizedLoopbackURL(URL(string: defaultVMAPIOrigin)!)
    }

    /// Look up a Debug runtime override. A tag profile wins over the global
    /// file, so several tagged apps can run against different backends without
    /// rebuilding or inheriting a stale parent-process port. Returns nil in
    /// Release and never reads arbitrary keys as configuration.
    private static func devOverride(key: String) -> String? {
        #if DEBUG
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return nil }
        for path in devOverridePaths(home: home) {
            guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if let value = parseDebugOverride(key: key, contents: data) { return value }
        }
        return nil
        #else
        return nil
        #endif
    }

    private static func devOverridePaths(home: String) -> [String] {
        var paths: [String] = []
        if let tag = ProcessInfo.processInfo.environment["BREE_TAG"],
           tag.range(of: #"^[A-Za-z0-9._-]+\z"#, options: .regularExpression) != nil {
            let configDirectory = BreeIdentity.current.configDirectory(homeDirectory: URL(fileURLWithPath: home, isDirectory: true))
            paths.append(configDirectory.appendingPathComponent("dev-profiles/\(tag).env").path)
        }
        paths.append((home as NSString).appendingPathComponent(".bree-dev.env"))
        return paths
    }

    public static func parseDebugOverride(key: String, contents: String) -> String? {
        for raw in contents.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let parsedKey = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            guard parsedKey == key else { continue }
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\"") && value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if value.hasPrefix("'") && value.hasSuffix("'") { value = String(value.dropFirst().dropLast()) }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static var breePort: String {
        resolvedBreePort(environment: runtimeEnvironment)
    }

    private static func billingWebsiteOrigin(environment: [String: String]) -> URL {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if !debugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: debugBuild
            ) == .production {
            return URL(string: "https://github.com/ecyx00/bree")!
        }
        if let overridden = environmentURL("BREE_BILLING_WWW_ORIGIN", environment: environment) {
            return overridden
        }
        return appWebOrigin(environment: environment)
    }

    private static func resolvedAuthWebOrigin(environment: [String: String]) -> URL {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if !debugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: debugBuild
            ) == .production {
            return URL(string: "https://github.com/ecyx00/bree")!
        }
        if let authWebsite = environmentURL("BREE_AUTH_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(authWebsite)
        }
        return appWebOrigin(environment: environment)
    }

    private static func appWebOrigin(environment: [String: String]) -> URL {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if !debugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: debugBuild
            ) == .production {
            return URL(string: "https://github.com/ecyx00/bree")!
        }
        if let explicitWebsite = environmentURL("BREE_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(explicitWebsite)
        }
        if let authWebsite = environmentURL("BREE_AUTH_WWW_ORIGIN", environment: environment) {
            return canonicalizedLoopbackURL(authWebsite)
        }
        #if DEBUG
        if environmentPort("BREE_PORT", environment: environment) != nil ||
            environmentPort("PORT", environment: environment) != nil {
            return URL(string: resolvedDefaultWebOrigin(environment: environment))!
        }
        if let override = devOverride(key: "BREE_WWW_ORIGIN"),
           let url = URL(string: override) {
            return canonicalizedLoopbackURL(url)
        }
        #endif
        return resolvedURL(
            environmentKey: "BREE_WWW_ORIGIN",
            fallback: resolvedDefaultWebOrigin(environment: environment),
            environment: environment
        )
    }

    private static func billingCheckoutURL(origin: URL, callbackScheme: String) -> URL {
        var components = URLComponents(
            url: origin.appendingPathComponent("api/billing/checkout"),
            resolvingAgainstBaseURL: false
        )!
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name == "bree_external_browser" }
        queryItems.removeAll { $0.name == "bree_scheme" }
        queryItems.append(URLQueryItem(name: "bree_external_browser", value: "1"))
        queryItems.append(URLQueryItem(name: "bree_scheme", value: callbackScheme))
        components.queryItems = queryItems
        return components.url!
    }

    private static func resolvedBreePort(environment: [String: String]) -> String {
        environmentPort("BREE_PORT", environment: environment)
            ?? environmentPort("PORT", environment: environment)
            ?? "3777"
    }

    private static func environmentPort(_ key: String) -> String? {
        environmentPort(key, environment: runtimeEnvironment)
    }

    private static func environmentPort(_ key: String, environment: [String: String]) -> String? {
        guard let port = environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let value = UInt16(port),
            value > 0
        else {
            return nil
        }
        return port
    }

    private static var defaultWebOrigin: String {
        resolvedDefaultWebOrigin(environment: runtimeEnvironment)
    }

    private static func resolvedDefaultWebOrigin(environment: [String: String]) -> String {
        #if DEBUG
        let debugBuild = true
        #else
        let debugBuild = false
        #endif
        if !debugBuild
            || resolvedStackAuthEnvironment(
                environment: environment,
                isDebugBuild: debugBuild
            ) == .production {
            return "https://github.com/ecyx00/bree"
        }
        if let origin = environment["BREE_WWW_ORIGIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !origin.isEmpty {
            return origin
        }
        #if DEBUG
        return "http://localhost:\(resolvedBreePort(environment: environment))"
        #else
        return "https://github.com/ecyx00/bree"
        #endif
    }

    private static var defaultVMAPIOrigin: String {
        #if DEBUG
        return "http://localhost:\(breePort)"
        #else
        return "https://github.com/ecyx00/bree"
        #endif
    }

    private static var defaultAPIBaseURL: String {
        if let url = runtimeEnvironment["BREE_API_BASE_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !url.isEmpty {
            return url
        }
        #if DEBUG
        return "http://localhost:\(breePort)"
        #else
        return "https://api.bree.sh"
        #endif
    }

    public static var stackBaseURL: URL {
        resolvedURL(
            environmentKey: "BREE_STACK_BASE_URL",
            fallback: "https://api.stack-auth.com"
        )
    }

    public static var stackProjectID: String {
        #if DEBUG
        return resolvedStackProjectID(
            environment: runtimeEnvironment,
            isDebugBuild: true
        )
        #else
        return resolvedStackProjectID(
            environment: runtimeEnvironment,
            isDebugBuild: false
        )
        #endif
    }

    /// Resolve the Stack channel for a macOS build. Debug defaults to the
    /// development project, while `scripts/reload.sh --prod-auth` bakes an
    /// explicit production override into the tagged app's launch environment.
    /// Invalid values fail toward the build's normal channel.
    public static func resolvedStackAuthEnvironment(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> BREEAuthEnvironment {
        guard isDebugBuild else { return .production }
        switch environment["BREE_AUTH_ENVIRONMENT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "production":
            return .production
        case "development":
            return .development
        default:
            return isDebugBuild ? .development : .production
        }
    }

    public static func resolvedStackProjectID(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> String {
        if resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) == .production {
            return productionStackProjectID
        }
        if let projectID = environment["BREE_STACK_PROJECT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !projectID.isEmpty {
            return projectID
        }
        switch resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) {
        case .development:
            return developmentStackProjectID
        case .production:
            return productionStackProjectID
        }
    }

    public static var stackPublishableClientKey: String {
        #if DEBUG
        return resolvedStackPublishableClientKey(
            environment: runtimeEnvironment,
            isDebugBuild: true
        )
        #else
        return resolvedStackPublishableClientKey(
            environment: runtimeEnvironment,
            isDebugBuild: false
        )
        #endif
    }

    public static func resolvedStackPublishableClientKey(
        environment: [String: String],
        isDebugBuild: Bool
    ) -> String {
        if resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) == .production {
            return productionStackPublishableClientKey
        }
        if let clientKey = environment["BREE_STACK_PUBLISHABLE_CLIENT_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !clientKey.isEmpty {
            return clientKey
        }
        switch resolvedStackAuthEnvironment(
            environment: environment,
            isDebugBuild: isDebugBuild
        ) {
        case .development:
            return developmentStackPublishableClientKey
        case .production:
            return productionStackPublishableClientKey
        }
    }

    /// The website origin used for the after-sign-in handler.
    static var afterSignInOrigin: URL {
        resolvedAfterSignInOrigin(environment: runtimeEnvironment)
    }

    static func resolvedAfterSignInOrigin(environment: [String: String]) -> URL {
        resolvedAuthWebOrigin(environment: environment)
    }

    public static func signInURL(callbackState: String? = nil) -> URL {
        signInURL(callbackState: callbackState, afterSignInOrigin: afterSignInOrigin, callbackURL: callbackURL)
    }

    public static func signInURL(
        callbackState: String? = nil,
        environment: [String: String],
        bundleIdentifier: String? = nil
    ) -> URL {
        signInURL(
            callbackState: callbackState,
            afterSignInOrigin: resolvedAfterSignInOrigin(environment: environment),
            callbackURL: resolvedCallbackURL(environment: environment, bundleIdentifier: bundleIdentifier)
        )
    }

    private static func signInURL(
        callbackState: String?,
        afterSignInOrigin: URL,
        callbackURL: URL
    ) -> URL {
        // Build the after-sign-in callback URL that includes the native app return scheme.
        // The after-sign-in handler extracts tokens from the Stack Auth session
        // and redirects to the native app via the bree:// callback scheme.
        var afterSignInComponents = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/after-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        var nativeCallbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)!
        if let callbackState {
            nativeCallbackComponents.queryItems = [
                URLQueryItem(name: "bree_auth_state", value: callbackState),
            ]
        }

        afterSignInComponents.queryItems = [
            URLQueryItem(
                name: "native_app_return_to",
                value: nativeCallbackComponents.url!.absoluteString
            ),
        ]

        // Enter through bree's native sign-in wrapper, which sets a short-lived
        // server-side handoff nonce before redirecting to Stack's /sign-in.
        var components = URLComponents(
            url: afterSignInOrigin.appendingPathComponent("handler/native-sign-in", isDirectory: false),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(
                name: "after_auth_return_to",
                value: afterSignInComponents.url!.absoluteString
            ),
        ]
        return components.url!
    }

    private static func resolvedURL(environmentKey: String, fallback: String) -> URL {
        resolvedURL(
            environmentKey: environmentKey,
            fallback: fallback,
            environment: runtimeEnvironment
        )
    }

    private static func resolvedURL(
        environmentKey: String,
        fallback: String,
        environment: [String: String]
    ) -> URL {
        if let overridden = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty,
           let url = URL(string: overridden) {
            return url
        }
        return URL(string: fallback)!
    }

    private static func environmentURL(_ key: String, environment: [String: String]) -> URL? {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        return URL(string: raw)
    }

    private static func canonicalizedLoopbackURL(_ url: URL) -> URL {
        guard let host = url.host?.lowercased() else {
            return url
        }

        let loopbackHosts = ["127.0.0.1", "::1", "[::1]", "0.0.0.0"]
        guard loopbackHosts.contains(host) else {
            return url
        }

        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = "localhost"
        return components?.url ?? url
    }
}
