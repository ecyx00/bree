import Foundation
import Testing
@testable import BreeFoundation

@Suite struct BreeIdentityTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    @Test func breeRoots() {
        let id = BreeIdentity(bundleIdentifier: "com.bree.app")
        #expect(id.kind == .bree)
        #expect(id.dotDirectory(homeDirectory: home).path == "/Users/test/.bree")
        #expect(id.applicationSupportDirectoryName == "Bree")
        #expect(id.cachesDirectoryName == "Bree")
        #expect(id.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/bree")
        #expect(id.socketFileName == "bree.sock")
        #expect(id.cliInstallName == "bree")
        #expect(id.defaultsDomain == "com.bree.app")
    }

    @Test func breeDevRoots() {
        let id = BreeIdentity(bundleIdentifier: "com.bree.app.debug.bree")
        #expect(id.kind == .breeDev)
        #expect(id.dotDirectoryName == ".bree-dev")
        #expect(id.applicationSupportDirectoryName == "Bree Dev")
        #expect(id.cachesDirectoryName == "Bree Dev")
        #expect(id.stateDirectoryName == "bree-dev")
        #expect(id.cliInstallName == "bree")
    }

    @Test func devTagsAreDevAndEverythingElseIsBree() {
        for bundle in ["com.bree.app.debug", "com.bree.app.debug.other"] {
            let id = BreeIdentity(bundleIdentifier: bundle)
            #expect(id.kind == .breeDev, "\(bundle)")
            #expect(id.dotDirectory(homeDirectory: home).path == "/Users/test/.bree-dev")
            #expect(id.reverseDNSPrefix == "com.bree.dev")
        }
        for bundle in [nil, "", "com.example.x", "com.bree.app.extra", "com.bree.app.debugger"] {
            let id = BreeIdentity(bundleIdentifier: bundle)
            #expect(id.kind == .bree, "\(bundle ?? "nil")")
            #expect(id.dotDirectory(homeDirectory: home).path == "/Users/test/.bree")
            #expect(id.defaultsDomain == "com.bree.app")
            #expect(id.reverseDNSPrefix == "com.bree")
        }
    }

    @Test func cliPrefersEnvThenEnclosingBundleThenBree() {
        let envWins = BreeIdentity.forCLI(
            environment: ["BREE_BUNDLE_ID": "com.bree.app.debug.bree"],
            enclosingAppBundleIdentifier: "com.bree.app"
        )
        #expect(envWins.kind == .breeDev)
        let bundleFallback = BreeIdentity.forCLI(
            environment: ["BREE_BUNDLE_ID": "  "],
            enclosingAppBundleIdentifier: "com.bree.app.debug.bree"
        )
        #expect(bundleFallback.kind == .breeDev)
        let none = BreeIdentity.forCLI(environment: [:], enclosingAppBundleIdentifier: nil)
        #expect(none.kind == .bree)
    }
}
