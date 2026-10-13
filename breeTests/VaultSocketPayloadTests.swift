import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@Suite
struct VaultSocketPayloadTests {
    private var entry: SessionEntry {
        SessionEntry(
            id: "claude:/tmp/s.jsonl",
            agent: .claude,
            sessionId: "session-1",
            title: "Fix the bug",
            cwd: "/Users/dev/bree",
            gitBranch: "main",
            pullRequest: nil,
            modified: Date(timeIntervalSince1970: 1_755_000_000),
            fileURL: URL(fileURLWithPath: "/tmp/s.jsonl"),
            specifics: .claude(model: nil, permissionMode: nil, configDirectoryForResume: nil),
            created: Date(timeIntervalSince1970: 1_754_000_000),
            messageCount: 7
        )
    }

    @Test
    func sessionPayloadCarriesIdentityStatusAndResumeCommand() {
        let now = Date(timeIntervalSince1970: 1_755_000_060)
        let payload = TerminalController.vaultSessionPayload(
            entry,
            liveKeys: [VaultLiveSessionKeys.key(for: entry)],
            now: now
        )
        #expect(payload["agent"] as? String == "claude")
        #expect(payload["session_id"] as? String == "session-1")
        #expect(payload["status"] as? String == "live")
        #expect(payload["title"] as? String == "Fix the bug")
        #expect(payload["cwd"] as? String == "/Users/dev/bree")
        #expect(payload["git_branch"] as? String == "main")
        #expect(payload["message_count"] as? Int == 7)
        #expect((payload["resume_command"] as? String)?.contains("session-1") == true)
        // The whole payload must be JSON-encodable for the wire.
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test
    func sessionPayloadWithoutProcessIsEnded() {
        let payload = TerminalController.vaultSessionPayload(
            entry,
            liveKeys: [],
            now: Date(timeIntervalSince1970: 1_755_000_060)
        )
        #expect(payload["status"] as? String == "exited")
    }
}
