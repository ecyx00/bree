import Foundation
import Testing
@testable import CmuxFoundation

@Suite struct CmuxConfigPathTests {
    private let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
    private let bree = CmuxIdentity(bundleIdentifier: "com.bree.app")
    private let dev = CmuxIdentity(bundleIdentifier: "com.cmuxterm.app.debug.bree")
    private let cmux = CmuxIdentity(bundleIdentifier: nil)

    @Test func globalPathsPerIdentity() {
        #expect(bree.configFile(homeDirectory: home).path == "/Users/test/.config/bree/bree.json")
        #expect(dev.configFile(homeDirectory: home).path == "/Users/test/.config/bree-dev/bree.json")
        #expect(cmux.configFile(homeDirectory: home).path == "/Users/test/.config/cmux/cmux.json")
        #expect(bree.sidebarsDirectory(homeDirectory: home).path == "/Users/test/.config/bree/sidebars")
        #expect(bree.configFileDisplayPath == "~/.config/bree/bree.json")
        #expect(bree.projectConfigDisplayPath == ".bree/bree.json")
    }

    @Test func projectCandidatesAreOwnFilesOnly() {
        #expect(bree.projectConfigCandidates(in: "/p") == ["/p/.bree/bree.json", "/p/bree.json"])
        #expect(cmux.projectConfigCandidates(in: "/p") == ["/p/.cmux/cmux.json", "/p/cmux.json"])
    }

    @Test func resolvingBreeConfigNeverTouchesCmuxConfig() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-config-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let cmuxFile = cmux.configFile(homeDirectory: tmp)
        try FileManager.default.createDirectory(at: cmuxFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ \"app\": { \"language\": \"tr\" } }\n".utf8)
        try original.write(to: cmuxFile)

        for identity in [bree, dev] {
            let target = identity.configFile(homeDirectory: tmp)
            #expect(!target.path.contains("/.config/cmux/"))
            // Resolving the path must not seed the file from cmux.json.
            #expect(!FileManager.default.fileExists(atPath: target.path))
        }
        #expect(try Data(contentsOf: cmuxFile) == original)
    }

    @Test func everyBreeRootIsDisjointFromCmux() {
        let home = URL(fileURLWithPath: "/Users/test", isDirectory: true)
        for identity in [bree, dev] {
            #expect(!identity.dotDirectory(homeDirectory: home).path.contains("cmux"))
            #expect(!identity.stateDirectory(homeDirectory: home).path.contains("cmux"))
            #expect(!identity.applicationSupportDirectoryName.lowercased().contains("cmux"))
            #expect(!identity.tempNamePrefix.contains("cmux"))
            #expect(!identity.configDirectoryName.contains("cmux"))
        }
        #expect(dev.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/bree-dev")
        #expect(bree.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/bree")
        #expect(cmux.stateDirectory(homeDirectory: home).path == "/Users/test/.local/state/cmux")
        #expect(CmuxIdentity.remoteDotDirectoryName == ".bree")
    }
}
