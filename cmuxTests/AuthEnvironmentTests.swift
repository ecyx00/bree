import CmuxCloud
import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Auth environment")
struct AuthEnvironmentTests {
    @Test("debug file overrides win over stale inherited routing values and never import unknown keys")
    func debugFileOverridesWinOverStaleInheritedRoutingValues() {
        let merged = AuthEnvironment.mergedRuntimeEnvironment(
            environment: [
                "CMUX_API_BASE_URL": "https://stale.example",
                "CMUX_VM_API_BASE_URL": "https://stale.example",
                "CMUX_AUTH_ENVIRONMENT": "development",
                "UNSAFE_SECRET": "process-secret",
            ],
            fileOverrides: [
                "CMUX_API_BASE_URL": " https://fresh.example:4626/ ",
                "CMUX_VM_API_BASE_URL": "https://fresh.example:4626/",
                "UNSAFE_SECRET": "file-secret",
            ]
        )

        #expect(merged["CMUX_API_BASE_URL"] == "https://fresh.example:4626/")
        #expect(merged["CMUX_VM_API_BASE_URL"] == "https://fresh.example:4626/")
        #expect(merged["UNSAFE_SECRET"] == "process-secret")
    }

    @Test("debug override parser accepts quoted values and ignores comments")
    func debugOverrideParserAcceptsQuotedValues() {
        let contents = "# comment\nCMUX_VM_API_BASE_URL = \"https://fresh.example:4626/\"\nOTHER=ignored\n"
        #expect(AuthEnvironment.parseDebugOverride(key: "CMUX_VM_API_BASE_URL", contents: contents) == "https://fresh.example:4626/")
        #expect(AuthEnvironment.parseDebugOverride(key: "CMUX_API_BASE_URL", contents: contents) == nil)
    }

    @Test("macOS production auth override selects the production Stack project")
    func macOSProductionAuthOverrideSelectsProductionStackProject() {
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": " production "],
            isDebugBuild: true
        ) == .production)
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: ["CMUX_AUTH_ENVIRONMENT": "production"],
            isDebugBuild: true
        ) == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: ["CMUX_AUTH_ENVIRONMENT": "production"],
            isDebugBuild: true
        ) == "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr")
    }

    @Test("invalid macOS auth override fails toward the build channel")
    func invalidMacOSAuthOverrideFailsTowardBuildChannel() {
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "staging"],
            isDebugBuild: true
        ) == .development)
        #expect(AuthEnvironment.resolvedStackAuthEnvironment(
            environment: ["CMUX_AUTH_ENVIRONMENT": "staging"],
            isDebugBuild: false
        ) == .production)
    }

    @Test("explicit Stack values override the selected auth channel")
    func explicitStackValuesOverrideSelectedAuthChannel() {
        let environment = [
            "CMUX_AUTH_ENVIRONMENT": "development",
            "CMUX_STACK_PROJECT_ID": "test-project",
            "CMUX_STACK_PUBLISHABLE_CLIENT_KEY": "test-key",
        ]
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: true
        ) == "test-project")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: true
        ) == "test-key")
    }

    @Test("production auth pins the authenticated API origin")
    func productionAuthPinsAuthenticatedAPIOrigin() {
        let debugProduction = AuthEnvironment.resolvedAPIBaseURL(
            environment: [
                "CMUX_AUTH_ENVIRONMENT": "production",
                "CMUX_API_BASE_URL": "https://cmux-staging.vercel.app",
            ],
            isDebugBuild: true
        )
        #expect(debugProduction.absoluteString == "https://cmux.com")

        let release = AuthEnvironment.resolvedAPIBaseURL(
            environment: ["CMUX_API_BASE_URL": "https://cmux-staging.vercel.app"],
            isDebugBuild: false
        )
        #expect(release.absoluteString == "https://cmux.com")
    }

    @Test("production auth pins Stack project and client key")
    func productionAuthPinsStackCredentials() {
        let environment = [
            "CMUX_AUTH_ENVIRONMENT": "production",
            "CMUX_STACK_PROJECT_ID": "staging-project",
            "CMUX_STACK_PUBLISHABLE_CLIENT_KEY": "staging-key",
        ]
        #expect(AuthEnvironment.resolvedStackProjectID(
            environment: environment,
            isDebugBuild: true
        ) == "9790718f-14cd-4f7e-824d-eaf527a82b82")
        #expect(AuthEnvironment.resolvedStackPublishableClientKey(
            environment: environment,
            isDebugBuild: true
        ) == "pck_kzj80gx4mh2jrzn1cx6y5e8jk0kwa01vkevh2p9zd4twr")
    }

    @Test("debug callback scheme uses sanitized tag")
    func debugCallbackSchemeUsesSanitizedTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "Safari Auth!"],
                bundleIdentifier: "com.cmuxterm.app.debug.safari-auth",
                isDebugBuild: true
            ) == "cmux-dev-safari-auth"
        )
    }

    @Test("release callback scheme ignores ambient tag")
    func releaseCallbackSchemeIgnoresAmbientTag() {
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app",
                isDebugBuild: false
            ) == "cmux"
        )
        #expect(
            AuthEnvironment.callbackScheme(
                environment: ["CMUX_TAG": "safari-auth"],
                bundleIdentifier: "com.cmuxterm.app.nightly",
                isDebugBuild: false
            ) == "cmux-nightly"
        )
    }

    @Test("sign-in URL enters native wrapper")
    func signInURLEntersNativeWrapper() {
        // Regression coverage for #5720: the client must not derive auth URL
        // path segments from the user's system locale, such as /ru/.
        let url = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(ru)",
                "LANG": "ru_RU.UTF-8",
                "LC_ALL": "ru_RU.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )

        assertNativeSignInURL(url)
    }

    @Test("tagged debug sign-in URL uses local origin and tag callback scheme")
    func taggedDebugSignInURLUsesLocalOriginAndTagCallbackScheme() throws {
        let url = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "CMUX_TAG": "pair-auth",
                "CMUX_PORT": "4123",
            ],
            bundleIdentifier: "com.cmuxterm.app.debug.pair-auth"
        )

        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port == 4123)
        #expect(url.path == "/handler/native-sign-in")

        let afterAuthReturnTo = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "after_auth_return_to" })?
            .value)
        let afterSignInURL = try #require(URL(string: afterAuthReturnTo))
        #expect(afterSignInURL.scheme == "http")
        #expect(afterSignInURL.host == "localhost")
        #expect(afterSignInURL.port == 4123)

        let nativeReturnTo = try #require(URLComponents(url: afterSignInURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "native_app_return_to" })?
            .value)
        let nativeCallbackURL = try #require(URL(string: nativeReturnTo))
        #expect(nativeCallbackURL.scheme == "cmux-dev-pair-auth")
        #expect(nativeCallbackURL.host == "auth-callback")
    }

    @Test("sign-in URL ignores locale-like environment values")
    func signInURLIgnoresLocaleLikeEnvironmentValues() {
        let englishURL = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(en)",
                "LANG": "en_US.UTF-8",
                "LC_ALL": "en_US.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )
        let russianURL = AuthEnvironment.signInURL(
            callbackState: "state-1",
            environment: [
                "AppleLanguages": "(ru)",
                "LANG": "ru_RU.UTF-8",
                "LC_ALL": "ru_RU.UTF-8",
                "CMUX_AUTH_WWW_ORIGIN": "https://cmux.com",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux",
            ],
            bundleIdentifier: "com.cmuxterm.app"
        )

        #expect(russianURL == englishURL)
    }

    @Test("billing checkout follows app web origin unless billing origin is explicit")
    func billingCheckoutFollowsAppWebOriginUnlessBillingOriginIsExplicit() {
        let appOriginURL = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev",
                "CMUX_WWW_ORIGIN": "http://127.0.0.1:4278",
            ]
        )
        #expect(appOriginURL.scheme == "http")
        #expect(appOriginURL.host == "localhost")
        #expect(appOriginURL.port == 4278)
        #expect(appOriginURL.path == "/api/billing/checkout")
        #expect(URLComponents(url: appOriginURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_external_browser" && $0.value == "1" }) == true)
        #expect(URLComponents(url: appOriginURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == "cmux-dev" }) == true)

        let overrideURL = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://localhost:4278",
                "CMUX_BILLING_WWW_ORIGIN": "https://billing-preview.example",
                "CMUX_AUTH_CALLBACK_SCHEME": "cmux-dev-preview",
            ]
        )
        #expect(overrideURL.scheme == "https")
        #expect(overrideURL.host == "billing-preview.example")
        #expect(overrideURL.path == "/api/billing/checkout")
        #expect(URLComponents(url: overrideURL, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == "cmux-dev-preview" }) == true)
    }

    @Test("billing portal follows app web origin unless billing origin is explicit")
    func billingPortalFollowsAppWebOriginUnlessBillingOriginIsExplicit() {
        let appOriginURL = AuthEnvironment.resolvedBillingPortalURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://127.0.0.1:4278",
            ]
        )
        #expect(appOriginURL.scheme == "http")
        #expect(appOriginURL.host == "localhost")
        #expect(appOriginURL.port == 4278)
        #expect(appOriginURL.path == "/api/billing/portal")

        let overrideURL = AuthEnvironment.resolvedBillingPortalURL(
            environment: [
                "CMUX_WWW_ORIGIN": "http://localhost:4278",
                "CMUX_BILLING_WWW_ORIGIN": "https://billing-preview.example",
            ]
        )
        #expect(overrideURL.scheme == "https")
        #expect(overrideURL.host == "billing-preview.example")
        #expect(overrideURL.path == "/api/billing/portal")
    }

    @Test("billing checkout default origin follows build web origin")
    func billingCheckoutDefaultOriginFollowsBuildWebOrigin() {
        let url = AuthEnvironment.resolvedBillingCheckoutURL(
            environment: [
                "CMUX_PORT": "4278",
            ]
        )

        #if DEBUG
        #expect(url.scheme == "http")
        #expect(url.host == "localhost")
        #expect(url.port == 4278)
        #else
        #expect(url.scheme == "https")
        #expect(url.host == "cmux.com")
        #expect(url.port == nil)

        let releaseDefaultURL = AuthEnvironment.resolvedBillingCheckoutURL(environment: [:])
        #expect(releaseDefaultURL.scheme == "https")
        #expect(releaseDefaultURL.host == "cmux.com")
        #expect(releaseDefaultURL.port == nil)
        #endif

        #expect(url.path == "/api/billing/checkout")
        #if DEBUG
        let expectedScheme = "cmux-dev"
        #else
        let expectedScheme = "cmux"
        #endif
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .contains(where: { $0.name == "cmux_scheme" && $0.value == expectedScheme }) == true)
    }

    @Test("app session handoff pins credentials to production or debug loopback")
    func appSessionHandoffPinsCredentialOrigin() {
        let production = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: false
        )
        #expect(production.absoluteString == "https://cmux.com")

        let rejectedDebugRemote = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_AUTH_WWW_ORIGIN": "https://attacker.example"],
            isDebugBuild: true
        )
        #expect(rejectedDebugRemote.absoluteString == "https://cmux.com")

        let debugLoopback = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: ["CMUX_WWW_ORIGIN": "http://127.0.0.1:4347"],
            isDebugBuild: true
        )
        #expect(debugLoopback.absoluteString == "http://localhost:4347")
    }

    @Test("debug app session handoff accepts the tagged Tailscale Serve origin")
    func debugAppSessionHandoffAcceptsTaggedTailscaleOrigin() {
        let environment = [
            "CMUX_WWW_ORIGIN": "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
            "CMUX_DEV_BACKEND_TRANSPORT": "direct",
            "CMUX_DEV_BACKEND_TAILSCALE_HOST": "cmux-dev-backend-1.tail137216.ts.net",
        ]
        let origin = AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: environment,
            isDebugBuild: true
        )
        #expect(origin.absoluteString == environment["CMUX_WWW_ORIGIN"])
    }

    @Test("debug app session handoff rejects an untrusted Tailscale host or port")
    func debugAppSessionHandoffRejectsUntrustedTailscaleHostOrPort() {
        let baseEnvironment = [
            "CMUX_WWW_ORIGIN": "https://cmux-dev-backend-1.tail137216.ts.net:3916/",
            "CMUX_DEV_BACKEND_TRANSPORT": "direct",
            "CMUX_DEV_BACKEND_TAILSCALE_HOST": "cmux-dev-backend-1.tail137216.ts.net",
        ]
        var wrongHost = baseEnvironment
        wrongHost["CMUX_WWW_ORIGIN"] = "https://other.tail137216.ts.net:3916/"
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: wrongHost,
            isDebugBuild: true
        ).absoluteString == "https://cmux.com")

        var wrongPort = baseEnvironment
        wrongPort["CMUX_WWW_ORIGIN"] = "https://cmux-dev-backend-1.tail137216.ts.net:8443/"
        #expect(AuthEnvironment.resolvedAppSessionHandoffOrigin(
            environment: wrongPort,
            isDebugBuild: true
        ).absoluteString == "https://cmux.com")
    }

}

private func assertNativeSignInURL(_ url: URL) {
    #expect(url.scheme == "https")
    #expect(url.host == "cmux.com")
    #expect(url.path == "/handler/native-sign-in")
    #expect(!urlHasLeadingLocaleSegment(url))

    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let afterAuthReturnTo = components.queryItems?.first(where: { $0.name == "after_auth_return_to" })?.value,
          let afterSignInURL = URL(string: afterAuthReturnTo)
    else {
        Issue.record("sign-in URL must include an after_auth_return_to URL")
        return
    }

    #expect(afterSignInURL.scheme == "https")
    #expect(afterSignInURL.host == "cmux.com")
    #expect(afterSignInURL.path == "/handler/after-sign-in")
    #expect(!urlHasLeadingLocaleSegment(afterSignInURL))

    guard let afterSignInComponents = URLComponents(url: afterSignInURL, resolvingAgainstBaseURL: false),
          let nativeReturnTo = afterSignInComponents.queryItems?.first(where: { $0.name == "native_app_return_to" })?.value,
          let nativeCallbackURL = URL(string: nativeReturnTo)
    else {
        Issue.record("after-sign-in URL must include a native_app_return_to URL")
        return
    }

    #expect(nativeCallbackURL.scheme == "cmux")
    #expect(nativeCallbackURL.host == "auth-callback")

    let nativeCallbackComponents = URLComponents(url: nativeCallbackURL, resolvingAgainstBaseURL: false)
    #expect(nativeCallbackComponents?.queryItems?.first { $0.name == "cmux_auth_state" }?.value == "state-1")
}

private func urlHasLeadingLocaleSegment(_ url: URL) -> Bool {
    guard let firstSegment = url.pathComponents.dropFirst().first else {
        return false
    }
    return isLocalePathSegment(firstSegment)
}

private func isLocalePathSegment(_ segment: String) -> Bool {
    let parts = segment.split(separator: "-")
    guard let language = parts.first,
          (2...3).contains(language.count),
          language.allSatisfy(\.isLetter)
    else {
        return false
    }
    return parts.dropFirst().allSatisfy { subtag in
        (2...4).contains(subtag.count) && subtag.allSatisfy(\.isLetter)
    }
}

@Suite("Checkout attribution")
struct CheckoutAttributionTests {
    @Test
    func queryItemsCarrySourceClientChannelAndVersion() throws {
        let items = CheckoutAttribution.queryItems(
            source: .sidebarBadge,
            flavor: .nightly,
            infoDictionary: ["CFBundleShortVersionString": "0.65.1", "CFBundleVersion": "2026090101"]
        )
        let values = Dictionary(uniqueKeysWithValues: items.compactMap { item in item.value.map { (item.name, $0) } })

        #expect(values["cmux_source"] == "mac_sidebar_badge")
        #expect(values["cmux_client"] == "mac")
        #expect(values["cmux_channel"] == "nightly")
        #expect(values["cmux_app_version"] == "0.65.1")
        #expect(values["cmux_app_build"] == "2026090101")
    }

    @Test
    func applyingReplacesStaleAttributionAndKeepsOtherQuery() throws {
        let base = try #require(URL(string: "https://cmux.com/app-pricing?cmux_app=1&cmux_source=mac_help_menu&cmux_channel=stable"))
        let url = CheckoutAttribution.applying(
            to: base,
            source: .commandPalette,
            flavor: .dev,
            infoDictionary: [:]
        )
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)

        #expect(items.filter { $0.name == "cmux_source" }.map(\.value) == ["mac_command_palette"])
        #expect(items.filter { $0.name == "cmux_channel" }.map(\.value) == ["dev"])
        #expect(items.contains { $0.name == "cmux_app" && $0.value == "1" })
        #expect(!items.contains { $0.name == "cmux_app_version" })
    }

    @Test
    func everySourceIsAServerSafeToken() {
        for source in ProUpgradeSource.allCases {
            let token = source.rawValue
            #expect(token.hasPrefix("mac_"), "\(token)")
            #expect(token.count <= 64, "\(token)")
            #expect(token.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }, "\(token)")
        }
    }

    @Test
    func vmRequiresProErrorTextLinksWithATypedSource() {
        let text = defaultCloudVMAction(status: 402, errorCode: "vm_requires_pro")
        #expect(text.contains("cmux_source=\(ProUpgradeSource.vmRequiresProError.rawValue)"))
        #expect(text.contains("cmux_client=mac"))
    }

    @Test
    func intentPropertiesNameSurfaceAndChannel() {
        let properties = CheckoutAttribution.intentProperties(source: .helpMenu, flavor: .stable)
        #expect(properties["source"] as? String == "mac_help_menu")
        #expect(properties["client"] as? String == "mac")
        #expect(properties["channel"] as? String == "stable")
    }
}
