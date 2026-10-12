import CmuxFoundation
import Foundation
import Testing
@testable import CmuxWorkspaces

private struct MigrationFixture: SessionSnapshotRepresenting, Equatable {
    var version: Int
    var windows: [String]
    var hasWindows: Bool { !windows.isEmpty }
}

@Suite("Session snapshot legacy copy-once migration")
struct SessionSnapshotLegacyMigrationTests {
    private let bundleId = CmuxIdentity.breeBundleIdentifier

    @Test func copiesOldFileOnceAndLeavesItUntouched() throws {
        let appSupport = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-mig-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let identity = CmuxIdentity(bundleIdentifier: bundleId)
        let location = SessionSnapshotFileLocation(appSupportDirectory: appSupport, identity: identity)
        let old = location.legacyDirectoryURL.appendingPathComponent("session-\(bundleId).json")
        try FileManager.default.createDirectory(at: old.deletingLastPathComponent(), withIntermediateDirectories: true)
        let oldScroll = location.legacyDirectoryURL.appendingPathComponent("session-\(bundleId)-scrollback", isDirectory: true)
        try FileManager.default.createDirectory(at: oldScroll, withIntermediateDirectories: true)
        try Data("s".utf8).write(to: oldScroll.appendingPathComponent("p.json"))
        let oldHist = location.legacyDirectoryURL.appendingPathComponent("session-history", isDirectory: true)
        try FileManager.default.createDirectory(at: oldHist, withIntermediateDirectories: true)
        try Data("h".utf8).write(to: oldHist.appendingPathComponent("h.json"))
        let payload = Data(#"{"version":1,"windows":["w"]}"#.utf8)
        try payload.write(to: old)
        let oldDate = Date(timeIntervalSince1970: 1_000_000)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: old.path)

        let repo = SessionSnapshotRepository<MigrationFixture>(
            schemaVersion: 1, bundleIdentifier: bundleId, appSupportDirectory: appSupport, identity: identity
        )
        let restored = repo.loadStartupSnapshot()
        #expect(restored?.windows == ["w"])

        let new = try #require(repo.defaultSnapshotFileURL())
        #expect(new.path.contains("/Bree/"))
        #expect(!new.path.contains("/cmux/"))
        #expect(try Data(contentsOf: new) == payload)
        #expect(try Data(contentsOf: old) == payload)
        let attrs = try FileManager.default.attributesOfItem(atPath: old.path)
        #expect(attrs[.modificationDate] as? Date == oldDate)

        let newDir = location.cmuxDirectoryURL
        #expect(try Data(contentsOf: newDir.appendingPathComponent("session-\(bundleId)-scrollback/p.json")) == Data("s".utf8))
        #expect(try Data(contentsOf: newDir.appendingPathComponent("session-history/h.json")) == Data("h".utf8))
        #expect(FileManager.default.fileExists(atPath: oldScroll.appendingPathComponent("p.json").path))

        // Second launch: the new file wins; changing the old one must not copy again.
        try Data(#"{"version":1,"windows":["other"]}"#.utf8).write(to: old)
        let relaunched = SessionSnapshotRepository<MigrationFixture>(
            schemaVersion: 1, bundleIdentifier: bundleId, appSupportDirectory: appSupport, identity: identity
        )
        #expect(relaunched.loadStartupSnapshot()?.windows == ["w"])
    }
}
