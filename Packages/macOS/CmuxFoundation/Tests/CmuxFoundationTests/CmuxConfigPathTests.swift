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
        #expect(CmuxIdentity.cmuxConfigFile(homeDirectory: home).path == "/Users/test/.config/cmux/cmux.json")
    }

    @Test func projectCandidatesPreferBreeThenReadOnlyCmuxFallback() {
        #expect(bree.projectConfigCandidates(in: "/p") == [
            "/p/.bree/bree.json", "/p/bree.json", "/p/.cmux/cmux.json", "/p/cmux.json",
        ])
        #expect(cmux.projectConfigCandidates(in: "/p") == ["/p/.cmux/cmux.json", "/p/cmux.json"])
    }

    private func tempHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-config-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func copiesOnceAndLeavesCmuxFileUntouched() throws {
        let tmp = try tempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let legacy = CmuxIdentity.cmuxConfigFile(homeDirectory: tmp)
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ \"app\": { \"language\": \"tr\" } }\n".utf8)
        try original.write(to: legacy)
        let before = try FileManager.default.attributesOfItem(atPath: legacy.path)[.modificationDate] as? Date

        #expect(CmuxConfigMigration.migrateIfNeeded(identity: bree, homeDirectory: tmp) == .copied)
        #expect(try Data(contentsOf: bree.configFile(homeDirectory: tmp)) == original)
        #expect(try Data(contentsOf: legacy) == original)
        #expect(try FileManager.default.attributesOfItem(atPath: legacy.path)[.modificationDate] as? Date == before)

        // The two files are independent from now on: a Bree edit is never overwritten by a second run.
        let edited = Data("{}\n".utf8)
        try edited.write(to: bree.configFile(homeDirectory: tmp))
        #expect(CmuxConfigMigration.migrateIfNeeded(identity: bree, homeDirectory: tmp) == .alreadyPresent)
        #expect(try Data(contentsOf: bree.configFile(homeDirectory: tmp)) == edited)
        #expect(try Data(contentsOf: legacy) == original)
    }

    @Test func noLegacyFileMeansNothingIsCreated() throws {
        let tmp = try tempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(CmuxConfigMigration.migrateIfNeeded(identity: dev, homeDirectory: tmp) == .noLegacyFile)
        #expect(!FileManager.default.fileExists(atPath: dev.configFile(homeDirectory: tmp).path))
        #expect(!FileManager.default.fileExists(atPath: tmp.appendingPathComponent(".config/cmux").path))
    }

    @Test func cmuxIdentityNeverMigrates() throws {
        let tmp = try tempHome()
        defer { try? FileManager.default.removeItem(at: tmp) }
        #expect(CmuxConfigMigration.migrateIfNeeded(identity: cmux, homeDirectory: tmp) == .notApplicable)
    }
}
