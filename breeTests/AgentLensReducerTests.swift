import BREEAgentLaunch
import Foundation
import Testing
@testable import Bree_Dev

@Suite("AgentLensReducer")
struct AgentLensReducerTests {
    private let workspace = UUID()
    private let surface = UUID()

    private func event(
        _ name: WorkstreamEvent.HookEventName,
        tool: String? = nil,
        input: String? = nil,
        isError: Bool? = nil,
        source: String = "claude",
        at seconds: TimeInterval = 100
    ) -> WorkstreamEvent {
        WorkstreamEvent(
            sessionId: "S",
            hookEventName: name,
            source: source,
            workspaceId: workspace.uuidString,
            surfaceId: surface.uuidString,
            cwd: "/Users/me/Projects/bree",
            toolName: tool,
            toolInputJSON: input,
            isError: isError,
            receivedAt: Date(timeIntervalSince1970: seconds)
        )
    }

    private func run(_ events: [WorkstreamEvent]) -> AgentLensCard? {
        events.reduce(nil as AgentLensCard?) { AgentLensReducer.reduce($0, event: $1) }
    }

    @Test func nonClaudeEventsCreateNoCard() {
        #expect(run([event(.preToolUse, tool: "Edit", source: "codex")]) == nil)
    }

    @Test func preToolUseSetsStepProjectAndSurface() throws {
        let card = try #require(run([
            event(.preToolUse, tool: "Edit", input: #"{"file_path":"/a/b/Foo.swift"}"#),
        ]))
        #expect(card.state == .running)
        #expect(card.step == .init(tool: "Edit", target: "Foo.swift"))
        #expect(card.project == "bree")
        #expect(card.surfaceID == surface)
        #expect(card.workspaceID == workspace)
        #expect(card.files == ["/a/b/Foo.swift"])
    }

    @Test func filesAreDedupedMostRecentFirstAndReadsDoNotCount() throws {
        let card = try #require(run([
            event(.preToolUse, tool: "Edit", input: #"{"file_path":"/a/One.swift"}"#),
            event(.preToolUse, tool: "Write", input: #"{"file_path":"/a/Two.swift"}"#),
            event(.preToolUse, tool: "Read", input: #"{"file_path":"/a/Three.swift"}"#),
            event(.preToolUse, tool: "Edit", input: #"{"file_path":"/a/One.swift"}"#),
        ]))
        #expect(card.files == ["/a/One.swift", "/a/Two.swift"])
    }

    @Test func todoWriteSetsProgressAndCurrentTodo() throws {
        let json = #"{"todos":[{"content":"A","status":"completed","activeForm":"Doing A"},{"content":"B","status":"in_progress","activeForm":"Doing B"},{"content":"C","status":"pending","activeForm":"Doing C"}]}"#
        let card = try #require(run([event(.preToolUse, tool: "TodoWrite", input: json)]))
        #expect(card.todos == .init(done: 1, total: 3, current: "Doing B"))
    }

    @Test func unknownTodoShapeKeepsPreviousTodos() throws {
        let good = #"{"todos":[{"content":"A","status":"in_progress"}]}"#
        let card = try #require(run([
            event(.preToolUse, tool: "TodoWrite", input: good),
            event(.preToolUse, tool: "TodoWrite", input: #"{"todos":[{"title":"x"}]}"#),
            event(.preToolUse, tool: "TodoWrite", input: "not json"),
        ]))
        #expect(card.todos == .init(done: 0, total: 1, current: "A"))
    }

    @Test func emptyTodoListClearsTodos() throws {
        let card = try #require(run([
            event(.preToolUse, tool: "TodoWrite", input: #"{"todos":[{"content":"A","status":"pending"}]}"#),
            event(.preToolUse, tool: "TodoWrite", input: #"{"todos":[]}"#),
        ]))
        #expect(card.todos == nil)
    }

    @Test func blockingToolsAndPermissionRequestNeedInputUntilNextTool() throws {
        let asking = try #require(run([event(.preToolUse, tool: "AskUserQuestion")]))
        #expect(asking.state == .needsInput)
        let permission = try #require(run([event(.preToolUse, tool: "Bash"), event(.permissionRequest)]))
        #expect(permission.state == .needsInput)
        let resumed = try #require(run([event(.permissionRequest), event(.preToolUse, tool: "Bash")]))
        #expect(resumed.state == .running)
    }

    @Test func idleNotificationDoesNotFlagNeedsInputButMidTurnOneDoes() throws {
        let idle = try #require(run([event(.stop), event(.notification)]))
        #expect(idle.state == .idle)
        let mid = try #require(run([event(.userPromptSubmit), event(.notification)]))
        #expect(mid.state == .needsInput)
    }

    @Test func failureThenNextToolRecovers() throws {
        let failed = try #require(run([event(.preToolUse, tool: "Bash"), event(.postToolUseFailure, tool: "Bash")]))
        #expect(failed.state == .error)
        let recovered = try #require(run([event(.postToolUseFailure), event(.preToolUse, tool: "Bash")]))
        #expect(recovered.state == .running)
    }

    @Test func stopClearsStepAndKeepsFilesAndTodos() throws {
        let card = try #require(run([
            event(.preToolUse, tool: "Edit", input: #"{"file_path":"/a/One.swift"}"#),
            event(.stop),
        ]))
        #expect(card.state == .idle)
        #expect(card.step == nil)
        #expect(card.files.count == 1)
    }

    @Test func sessionEndRemovesTheCard() {
        #expect(run([event(.preToolUse, tool: "Bash"), event(.sessionEnd)]) == nil)
    }

    @Test func bashTargetIsTheClippedFirstLine() throws {
        let long = String(repeating: "x", count: 100)
        let card = try #require(run([event(.preToolUse, tool: "Bash", input: #"{"command":"\#(long)\nsecond"}"#)]))
        #expect(card.step?.target?.count == 48)
    }

    @Test func startedAtIsTheFirstEventAndLastEventAtOnlyMovesForward() throws {
        let card = try #require(run([
            event(.sessionStart, at: 100),
            event(.preToolUse, tool: "Bash", at: 90),
            event(.postToolUse, at: 150),
        ]))
        #expect(card.startedAt == Date(timeIntervalSince1970: 100))
        #expect(card.lastEventAt == Date(timeIntervalSince1970: 150))
    }
}
