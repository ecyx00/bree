import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CmuxIdentityTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)

    @Test func breeRoots() {
        let id = CmuxIdentity(bundleIdentifier: "com.bree.app")
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
        let id = CmuxIdentity(bundleIdentifier: "com.cmuxterm.app.debug.bree")
        #expect(id.kind == .breeDev)
        #expect(id.dotDirectoryName == ".bree-dev")
        #expect(id.applicationSupportDirectoryName == "Bree Dev")
        #expect(id.cachesDirectoryName == "Bree Dev")
        #expect(id.stateDirectoryName == "cmux")
        #expect(id.cliInstallName == "bree")
    }

    @Test func everythingElseIsCmuxUnchanged() {
        for bundle in [nil, "", "com.cmuxterm.app", "com.cmuxterm.app.debug", "com.cmuxterm.app.debug.other",
                       "com.cmuxterm.app.nightly", "com.example.x", "com.bree.app.extra"] {
            let id = CmuxIdentity(bundleIdentifier: bundle)
            #expect(id.kind == .cmux, "\(bundle ?? "nil")")
            #expect(id.dotDirectory(homeDirectory: home).path == "/Users/test/.cmuxterm")
            #expect(id.applicationSupportDirectoryName == "cmux")
            #expect(id.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/cmux")
            #expect(id.socketFileName == "cmux.sock")
            #expect(id.cliInstallName == "cmux")
            #expect(id.defaultsDomain == "com.cmuxterm.app")
            #expect(id.reverseDNSPrefix == "com.cmuxterm")
        }
    }

    @Test func cliPrefersEnvThenEnclosingBundleThenCmux() {
        let envWins = CmuxIdentity.forCLI(
            environment: ["CMUX_BUNDLE_ID": "com.bree.app"],
            enclosingAppBundleIdentifier: "com.cmuxterm.app"
        )
        #expect(envWins.kind == .bree)
        let bundleFallback = CmuxIdentity.forCLI(
            environment: ["CMUX_BUNDLE_ID": "  "],
            enclosingAppBundleIdentifier: "com.bree.app"
        )
        #expect(bundleFallback.kind == .bree)
        let cmux = CmuxIdentity.forCLI(environment: [:], enclosingAppBundleIdentifier: nil)
        #expect(cmux.kind == .cmux)
    }
}
