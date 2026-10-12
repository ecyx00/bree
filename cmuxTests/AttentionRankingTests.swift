import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AttentionRankingTests {
    private static let workspace = UUID()

    private static func item(
        _ name: String,
        _ state: AttentionState?,
        since: Int64? = 0,
        workspaceId: UUID = UUID()
    ) -> AttentionItem {
        AttentionItem(
            id: name,
            workspaceId: workspaceId,
            panelId: state == nil ? nil : UUID(),
            workspaceTitle: name,
            paneTitle: nil,
            agentName: nil,
            state: state,
            sinceMs: since,
            lastPrompt: nil,
            lastOutput: nil
        )
    }

    @Test func permissionRequestSaysApprovalAndQuestionSaysInput() {
        #expect(AttentionStyle.word(for: .needsInput, needsApproval: true) == "Needs approval")
        #expect(AttentionStyle.word(for: .needsInput) == "Needs input")
        #expect(AttentionStyle.word(for: .failed, needsApproval: true) == "Failed")
    }

    @Test func ranksNeedsInputThenFailedThenDoneThenRunning() {
        let ranked = AttentionRanking.rank([
            Self.item("run", .running),
            Self.item("done", .done),
            Self.item("fail", .failed),
            Self.item("ask", .needsInput),
            Self.item("changes", nil),
        ])
        #expect(ranked.map(\.id) == ["ask", "fail", "done", "run", "changes"])
    }

    @Test func blockedStatesListLongestWaitFirstOthersNewestFirst() {
        let ranked = AttentionRanking.rank([
            Self.item("askNew", .needsInput, since: 200),
            Self.item("askOld", .needsInput, since: 100),
            Self.item("doneOld", .done, since: 100),
            Self.item("doneNew", .done, since: 200),
        ])
        #expect(ranked.map(\.id) == ["askOld", "askNew", "doneNew", "doneOld"])
    }

    @Test func doneIsUnseenOnlyForUnselectedWorkspacesSinceTheLastLook() {
        #expect(AttentionRanking.isUnseenDone(sinceMs: 200, seenAtMs: 100, isSelected: false))
        #expect(!AttentionRanking.isUnseenDone(sinceMs: 100, seenAtMs: 200, isSelected: false))
        #expect(!AttentionRanking.isUnseenDone(sinceMs: 200, seenAtMs: 100, isSelected: true))
    }

    @Test func changeCountsAttachToTopRowAndAddChangesOnlyRows() {
        let busy = UUID()
        let quiet = UUID()
        let ranked = AttentionRanking.rank([
            Self.item("ask", .needsInput, workspaceId: busy),
            Self.item("run", .running, workspaceId: busy),
        ])
        let merged = AttentionRanking.attachChangeCounts(
            to: ranked,
            counts: [busy: 3, quiet: 2, UUID(): 0],
            titles: [quiet: "Quiet"]
        )
        #expect(merged.map(\.id).prefix(2) == ["ask", "run"])
        #expect(merged[0].changedCount == 3)
        #expect(merged[1].changedCount == 0)
        #expect(merged.count == 3)
        #expect(merged[2].state == nil)
        #expect(merged[2].workspaceTitle == "Quiet")
        #expect(merged[2].changedCount == 2)
    }

    @Test func jumpTargetSkipsTheFocusedPaneSoRepeatedPressesCycle() {
        let ranked = AttentionRanking.rank([
            Self.item("ask", .needsInput, since: 1),
            Self.item("fail", .failed, since: 2),
            Self.item("done", .done, since: 3),
        ])
        #expect(AttentionRanking.nextJumpTarget(in: ranked, currentWorkspaceId: nil, currentPanelId: nil)?.id == "ask")
        let first = ranked[0]
        #expect(AttentionRanking.nextJumpTarget(
            in: ranked, currentWorkspaceId: first.workspaceId, currentPanelId: first.panelId
        )?.id == "fail")
        #expect(AttentionRanking.nextJumpTarget(
            in: [first], currentWorkspaceId: first.workspaceId, currentPanelId: first.panelId
        ) == nil)
        #expect(AttentionRanking.nextJumpTarget(
            in: AttentionRanking.rank([Self.item("done", .done)]), currentWorkspaceId: nil, currentPanelId: nil
        ) == nil)
    }

    @Test func timeBucketsRoundDown() {
        #expect(AttentionRanking.timeBucket(sinceMs: 0, nowMs: 59_999) == .now)
        #expect(AttentionRanking.timeBucket(sinceMs: 0, nowMs: 60_000) == .minutes(1))
        #expect(AttentionRanking.timeBucket(sinceMs: 0, nowMs: 12 * 60_000 + 30_000) == .minutes(12))
        #expect(AttentionRanking.timeBucket(sinceMs: 0, nowMs: 3 * 3_600_000) == .hours(3))
        #expect(AttentionRanking.timeBucket(sinceMs: 0, nowMs: 2 * 86_400_000) == .days(2))
        #expect(AttentionRanking.timeBucket(sinceMs: 10_000, nowMs: 0) == .now)
    }

    @Test func oneLineCollapsesWhitespaceAndTruncates() {
        #expect(AttentionRanking.oneLine("  fix\n the   bug \t now ") == "fix the bug now")
        #expect(AttentionRanking.oneLine("   \n ") == nil)
        #expect(AttentionRanking.oneLine(nil) == nil)
        let long = String(repeating: "a", count: 300)
        #expect(AttentionRanking.oneLine(long, limit: 10) == String(repeating: "a", count: 9) + "…")
    }

    @Test func lastLineKeepsTheFinalNonEmptyLine() {
        #expect(AttentionRanking.lastLine("first\nsecond  line\n\n  ") == "second line")
        #expect(AttentionRanking.lastLine("\n\n") == nil)
    }
}
