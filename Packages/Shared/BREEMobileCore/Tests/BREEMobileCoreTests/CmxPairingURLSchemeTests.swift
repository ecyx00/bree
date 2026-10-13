import Foundation
import Testing
@testable import BREEMobileCore

/// Every installed iOS bundle owns one pairing URL scheme. Parsers accept only
/// schemes whose release or development lane can be classified for account
/// preflight, while installed builds still register their exact bundle scheme.
@Suite struct CmxPairingURLSchemeTests {
    @Test func everyInstalledBundleEmitsItsOwnScheme() {
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.bree.app.internal"
            )?.rawValue == "bree-ios-dev.bree.app.internal"
        )
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.bree.app.demo"
            )?.rawValue == "bree-ios-dev.bree.app.demo"
        )
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.bree.ios.feature-a"
            )?.rawValue == "bree-ios-dev.bree.ios.feature-a"
        )
    }

    @Test func invalidIdentityDoesNotFallBackToAnotherApp() {
        #expect(CmxPairingURLScheme(iOSBundleIdentifier: "") == nil)
        #expect(CmxPairingURLScheme(iOSBundleIdentifier: "invalid bundle") == nil)
        #expect(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.bree.app.unrecognized"
            ) == nil
        )
        #if !os(iOS)
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: "invalid tag",
                isDevelopmentBuild: true
            ).resolved == nil
        )
        #endif
    }

    #if !os(iOS)
    @Test func untaggedDebugMacTargetsDefaultDebugIOSBundle() {
        #if DEBUG
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: true
            ).resolved?.rawValue == "bree-ios-dev.bree.ios"
        )
        #endif
    }

    @Test func untaggedMacBuildChannelsResolveDistinctExactBundles() {
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: true
            ).resolved?.rawValue == "bree-ios-dev.bree.ios"
        )
        #expect(
            CmxPairingURLSchemeResolver(
                currentIOSBundleIdentifier: nil,
                targetIOSBundleIdentifier: nil,
                macInstanceTag: nil,
                isDevelopmentBuild: false
            ).resolved?.rawValue == "bree-ios-com.bree.app"
        )
    }

    @Test func macCanExplicitlyTargetEveryReleaseLane() {
        for bundleIdentifier in [
            "com.bree.app",
            "dev.bree.app.beta",
            "dev.bree.app.internal",
            "dev.bree.app.demo",
        ] {
            #expect(
                CmxPairingURLSchemeResolver(
                    currentIOSBundleIdentifier: nil,
                    targetIOSBundleIdentifier: bundleIdentifier,
                    macInstanceTag: nil,
                    isDevelopmentBuild: false
                ).resolved?.rawValue
                    == "bree-ios-\(bundleIdentifier)"
            )
        }
    }
    #endif

    @Test func parserAcceptsNamespacedSchemes() {
        #expect(CmxPairingURLScheme(rawValue: "bree-ios-dev.bree.app.internal") != nil)
        #expect(CmxPairingURLScheme(rawValue: "bree-ios-dev.bree.app.demo") != nil)
        #expect(CmxPairingURLScheme(rawValue: "BREE-IOS-DEV.BREE.IOS.FEATURE-A") != nil)
        // Old QR codes remain scannable inside an already-open app. New builds
        // do not register these shared schemes with iOS.
        #expect(CmxPairingURLScheme(rawValue: "bree-ios") != nil)
        #expect(CmxPairingURLScheme(rawValue: "bree-ios-dev") != nil)
    }

    @Test func parserRejectsForeignSchemes() {
        #expect(CmxPairingURLScheme(rawValue: nil) == nil)
        #expect(CmxPairingURLScheme(rawValue: "") == nil)
        #expect(CmxPairingURLScheme(rawValue: "https") == nil)
        #expect(CmxPairingURLScheme(rawValue: "bree-ios-*") == nil)
    }

    @Test func channelClassificationRecognizesOnlyAuthoritativeLanes() throws {
        for bundleIdentifier in [
            "com.bree.app",
            "dev.bree.app.beta",
            "dev.bree.app.internal",
            "dev.bree.app.demo",
        ] {
            let scheme = try #require(
                CmxPairingURLScheme(
                    iOSBundleIdentifier: bundleIdentifier
                )
            )
            #expect(scheme.isRelease)
            #expect(!scheme.isDevelopment)
        }
        let development = try #require(
            CmxPairingURLScheme(
                iOSBundleIdentifier: "dev.bree.ios.feature-a"
            )
        )
        #expect(development.isDevelopment)
        #expect(!development.isRelease)
        #expect(CmxPairingURLScheme(rawValue: "bree-ios-dev.bree.app.unrecognized") == nil)
    }

    @Test func prefixCheckAcceptsNamespacedSchemesAndRejectsOthers() {
        #expect(CmxPairingURLScheme(urlString:
            "bree-ios-dev.bree.app.internal://attach?v=2&r=100.64.0.5:58465"
        ) != nil)
        #expect(CmxPairingURLScheme(urlString:
            "BREE-IOS-DEV.BREE.IOS.FEATURE-A://attach?v=2"
        ) != nil)
        #expect(CmxPairingURLScheme(urlString: "bree-ios://attach?v=2") != nil)
        #expect(CmxPairingURLScheme(urlString: "bree-ios-dev://attach?v=2") != nil)
        #expect(CmxPairingURLScheme(urlString: "https://example.com") == nil)
        #expect(CmxPairingURLScheme(urlString: "bree-ios-dev.bree.app.internal") == nil)
    }
}
