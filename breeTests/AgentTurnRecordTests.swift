import Foundation
import XCTest

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

final class AgentTurnRecordTests: XCTestCase {
    private func record(
        _ id: String, workspace: String = "w1", turnId: String? = nil, at: TimeInterval, reviewed: Bool = false
    ) -> AgentTurnRecord {
        AgentTurnRecord(
            id: id, workspaceId: workspace, surfaceId: "s1", sessionId: "sess", turnId: turnId, agent: "claude",
            repoRoot: "/tmp/repo", start: "aaaaaaa", end: "bbbbbbb", files: 5, added: 120, removed: 30,
            finishedAt: at, reviewed: reviewed)
    }

    func testAppendCapsPerWorkspaceAndReturnsEvictedOldest() {
        var file = AgentTurnRecordFile()
        for index in 0..<20 { XCTAssertTrue(file.append(record("a\(index)", at: Double(index))).isEmpty) }
        file.append(record("other", workspace: "w2", at: 0))
        let evicted = file.append(record("a20", at: 20))
        XCTAssertEqual(evicted.map(\.id), ["a0"])
        XCTAssertEqual(file.records(forWorkspace: "w1").count, 20)
        XCTAssertEqual(file.records(forWorkspace: "w1").first?.id, "a20")
        XCTAssertEqual(file.records(forWorkspace: "w2").count, 1)
    }

    func testRepeatedStopForSameTurnReplacesEarlierRecord() {
        var file = AgentTurnRecordFile()
        file.append(record("first", turnId: "t1", at: 1))
        let evicted = file.append(record("second", turnId: "t1", at: 2))
        XCTAssertEqual(evicted.map(\.id), ["first"])
        XCTAssertEqual(file.records.map(\.id), ["second"])
    }

    func testMarkReviewedFlipsOnceAndSurvivesRoundTrip() throws {
        var file = AgentTurnRecordFile()
        file.append(record("a", at: 1))
        XCTAssertTrue(file.markReviewed(id: "a"))
        XCTAssertFalse(file.markReviewed(id: "a"))
        XCTAssertFalse(file.markReviewed(id: "missing"))
        let decoded = try JSONDecoder().decode(AgentTurnRecordFile.self, from: JSONEncoder().encode(file))
        XCTAssertEqual(decoded, file)
        XCTAssertEqual(decoded.records.first?.reviewed, true)
    }

    func testStorageUpdateIsReadModifyWrite() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("turn-records-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = AgentTurnRecordStorage.path(env: ["BREE_AGENT_HOOK_STATE_DIR": directory.path])
        XCTAssertEqual(path, directory.path + "/agent-turn-records.json")
        try AgentTurnRecordStorage.update(path: path) { $0.append(record("a", at: 1)) }
        try AgentTurnRecordStorage.update(path: path) { $0.markReviewed(id: "a") }
        let stored = AgentTurnRecordStorage.read(path: path)
        XCTAssertEqual(stored.records.map(\.id), ["a"])
        XCTAssertTrue(stored.records[0].reviewed)
    }
}
