import Foundation
import Testing
@testable import BREEMobileCore

@Suite struct MobileIOSAppNamespaceTests {
    @Test(
        arguments: [
            "com.bree.app",
            "dev.bree.app.beta",
            "dev.bree.app.internal",
            "dev.bree.app.demo",
            "dev.bree.ios.feature-a",
            "dev.bree.ios.feature-b",
        ]
    )
    func fullBundleIdentifierOwnsEveryNamespace(bundleIdentifier: String) throws {
        let namespace = try #require(
            MobileIOSAppNamespace(bundleIdentifier: bundleIdentifier)
        )

        #expect(namespace.bundleIdentifier == bundleIdentifier)
        #expect(
            namespace.keychainService(base: "com.bree.iroh.identity")
                == "com.bree.iroh.identity.\(bundleIdentifier)"
        )
        #expect(
            namespace.keychainAccessGroup(teamIdentifier: "7WLXT3NR37")
                == "7WLXT3NR37.\(bundleIdentifier)"
        )
        #expect(
            namespace.pairingURLScheme
                == "bree-ios-\(bundleIdentifier)"
        )
    }

    @Test func appTypesAndDevTagsNeverSharePersistentOrPairingScopes() throws {
        let bundleIdentifiers = [
            "com.bree.app",
            "dev.bree.app.beta",
            "dev.bree.app.internal",
            "dev.bree.app.demo",
            "dev.bree.ios.feature-a",
            "dev.bree.ios.feature-b",
        ]
        let namespaces = try bundleIdentifiers.map {
            try #require(MobileIOSAppNamespace(bundleIdentifier: $0))
        }

        #expect(Set(namespaces.map(\.serverScope)).count == namespaces.count)
        #expect(Set(namespaces.map(\.pairingURLScheme)).count == namespaces.count)
        #expect(
            Set(
                namespaces.map {
                    $0.keychainService(base: "com.bree.iroh.identity")
                }
            ).count == namespaces.count
        )
    }

    @Test func rejectsMissingOrUnsafeBundleIdentifiers() {
        #expect(MobileIOSAppNamespace(bundleIdentifier: nil) == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "") == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "Dev.bree.ios.feature-a") == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "dev.bree.ios.*") == nil)
        #expect(MobileIOSAppNamespace(bundleIdentifier: "dev bree ios") == nil)
    }

    @Test func macInstanceTagResolvesOneExactIOSBundle() {
        #expect(
            MobileIOSAppNamespace(pairedMacInstanceTag: "feature-a")?.bundleIdentifier
                == "dev.bree.ios.feature-a"
        )
        #expect(
            MobileIOSAppNamespace(pairedMacInstanceTag: "default")?.bundleIdentifier
                == "com.bree.app"
        )
        #expect(MobileIOSAppNamespace(pairedMacInstanceTag: "invalid tag") == nil)
        #expect(MobileIOSAppNamespace(pairedMacInstanceTag: " feature-a ") == nil)
    }

    @Test func legacyBackupAdoptionIsLimitedToUnambiguousOwners() throws {
        let appStore = try #require(
            MobileIOSAppNamespace(bundleIdentifier: "com.bree.app")
        )
        let tagged = try #require(
            MobileIOSAppNamespace(bundleIdentifier: "dev.bree.ios.feature-a")
        )
        #expect(appStore.legacyBackupScope == .unscoped)
        #expect(
            tagged.legacyBackupScope
                == .scoped("ios:v2:ZmVhdHVyZS1h")
        )
        for bundleIdentifier in [
            "dev.bree.app.beta",
            "dev.bree.app.internal",
            "dev.bree.app.demo",
        ] {
            #expect(
                MobileIOSAppNamespace(
                    bundleIdentifier: bundleIdentifier
                )?.legacyBackupScope == nil
            )
        }
    }
}
