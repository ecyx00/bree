import Foundation
import Testing
@testable import BreeFoundation

@Suite struct BreeConfigPathTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let bree = BreeIdentity(bundleIdentifier: "com.bree.app")
    private let dev = BreeIdentity(bundleIdentifier: "com.bree.app.debug.bree")

    @Test func globalPathsPerIdentity() {
        #expect(bree.configFile(homeDirectory: home).path == "/Users/test/.config/bree/bree.json")
        #expect(dev.configFile(homeDirectory: home).path == "/Users/test/.config/bree-dev/bree.json")
        #expect(bree.sidebarsDirectory(homeDirectory: home).path == "/Users/test/.config/bree/sidebars")
        #expect(bree.configFileDisplayPath == "~/.config/bree/bree.json")
        #expect(bree.projectConfigDisplayPath == ".bree/bree.json")
    }

    @Test func projectCandidates() {
        #expect(bree.projectConfigCandidates(in: "/p") == ["/p/.bree/bree.json", "/p/bree.json"])
    }

    @Test func breeRootsAreDistinctPerIdentity() {
        #expect(dev.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/bree-dev")
        #expect(bree.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/bree")
        #expect(bree.dotDirectoryName != dev.dotDirectoryName)
        #expect(bree.applicationSupportDirectoryName != dev.applicationSupportDirectoryName)
        #expect(BreeIdentity.remoteDotDirectoryName == ".bree")
    }
}
