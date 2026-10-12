import Foundation
import Testing
@testable import cmux_DEV

@Suite("AgentImageDiscovery")
struct AgentImageStripTests {
    @Test func sortsNumericallyAndFiltersExtensions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("proj/sess-1/images")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["10.png", "2.png", "1.JPG", "3.txt", "4.webp", "notes.png", "5.gif", "6.jpeg"] {
            try Data([0]).write(to: dir.appendingPathComponent(name))
        }
        let found = AgentImageDiscovery.discover(root: root, sessionID: "sess-1")
        #expect(found.map { $0.url.lastPathComponent } == ["1.JPG", "2.png", "4.webp", "5.gif", "6.jpeg", "10.png", "notes.png"])
        #expect(found.first?.title == "Image #1")
        #expect(AgentImageDiscovery.discover(root: root, sessionID: "other").isEmpty)
    }
}

@Suite("AgentImageTokenRemoval")
struct AgentImageTokenRemovalTests {
    private let viewport = "history [Image #1] old\n│ > hi [Image #2]\n│ footer"

    @Test func cursorAtTokenEndNeedsNoMoves() throws {
        let plan = try #require(AgentImageTokenRemoval.plan(viewport: viewport, cursorRow: 1, cursorColumn: 17, number: 2))
        #expect(plan.horizontalMoves == 0)
        #expect(plan.head == "│ > hi ")
    }

    @Test func cursorInsideAndAfterTokenMovesToItsEnd() throws {
        #expect(AgentImageTokenRemoval.plan(viewport: viewport, cursorRow: 1, cursorColumn: 10, number: 2)?.horizontalMoves == 7)
        #expect(AgentImageTokenRemoval.plan(viewport: "> [Image #2] tail", cursorRow: 0, cursorColumn: 16, number: 2)?.horizontalMoves == -4)
    }

    @Test func refusesWhenTokenIsNotOnCursorRowOrAmbiguous() {
        #expect(AgentImageTokenRemoval.plan(viewport: viewport, cursorRow: 1, cursorColumn: 17, number: 1) == nil)
        #expect(AgentImageTokenRemoval.plan(viewport: "[Image #1] [Image #1]", cursorRow: 0, cursorColumn: 10, number: 1) == nil)
        #expect(AgentImageTokenRemoval.plan(viewport: viewport, cursorRow: 9, cursorColumn: 0, number: 2) == nil)
        #expect(AgentImageTokenRemoval.plan(viewport: "日本 [Image #2]", cursorRow: 0, cursorColumn: 12, number: 2) == nil)
    }

    @Test func backspaceOnlyWhileLeftOfCursorIsHeadPlusTokenPrefix() throws {
        let plan = try #require(AgentImageTokenRemoval.plan(viewport: "> hi [Image #2]", cursorRow: 0, cursorColumn: 15, number: 2))
        #expect(AgentImageTokenRemoval.shouldBackspace(rowText: "> hi [Image #2]", cursorColumn: 15, plan: plan))
        #expect(AgentImageTokenRemoval.shouldBackspace(rowText: "> hi [Imag", cursorColumn: 10, plan: plan))
        #expect(AgentImageTokenRemoval.shouldBackspace(rowText: "> hi [", cursorColumn: 6, plan: plan))
        // Head only (token gone) or user text before it: never.
        #expect(!AgentImageTokenRemoval.shouldBackspace(rowText: "> hi ", cursorColumn: 5, plan: plan))
        #expect(!AgentImageTokenRemoval.shouldBackspace(rowText: "> hi x", cursorColumn: 6, plan: plan))
        #expect(!AgentImageTokenRemoval.shouldBackspace(rowText: "> hi [Image #3]", cursorColumn: 15, plan: plan))
    }
}

@Suite("AgentImageStripPlacement")
struct AgentImageStripPlacementTests {
    private let rule = String(repeating: "─", count: 40)

    @Test func findsLastInputRuleFollowedByPrompt() {
        let text = "❯ old\nreply\n\(rule)\n❯ hello [Image #1]\n\(rule)\nfooter"
        #expect(AgentImageStripPlacement.inputRuleRow(viewport: text, columns: 40) == 2)
    }

    @Test func refusesWithoutRuleThenPromptOrWhenShort() {
        #expect(AgentImageStripPlacement.inputRuleRow(viewport: "$ ls\n❯ x", columns: 40) == nil)
        #expect(AgentImageStripPlacement.inputRuleRow(viewport: "───\n❯ x", columns: 40) == nil)
        #expect(AgentImageStripPlacement.inputRuleRow(viewport: "\(rule)\n> x", columns: 40) == nil)
    }
}
