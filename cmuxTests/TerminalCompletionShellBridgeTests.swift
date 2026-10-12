import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct TerminalCompletionShellBridgeTests {
    private let panel = "22222222-2222-2222-2222-222222222222"

    private func b64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    @Test("buffer report decodes base64 buffer, cwd, caret and panel")
    func parsesBufferReport() throws {
        let line = "3 7 \(b64("/Users/me/My Dir")) \(b64("cd Desk; echo \"$(x)\"")) --tab=11111111-1111-1111-1111-111111111111 --panel=\(panel)"
        let parsed = try #require(TerminalCompletionShellReport.parseBuffer(line))
        #expect(parsed.panel == UUID(uuidString: panel))
        #expect(parsed.report.token == 3)
        #expect(parsed.report.caret == 7)
        #expect(parsed.report.cwd == "/Users/me/My Dir")
        #expect(parsed.report.text == "cd Desk; echo \"$(x)\"")
    }

    @Test("empty buffer and cwd use the dash placeholder; caret is clamped")
    func parsesPlaceholders() throws {
        let parsed = try #require(TerminalCompletionShellReport.parseBuffer("0 5 - - --panel=\(panel)"))
        #expect(parsed.report.text.isEmpty)
        #expect(parsed.report.cwd == nil)
        #expect(parsed.report.caret == 0)
    }

    @Test("malformed reports are rejected")
    func rejectsMalformed() {
        #expect(TerminalCompletionShellReport.parseBuffer("3 1 - - ") == nil)  // no panel
        #expect(TerminalCompletionShellReport.parseBuffer("10 1 - - --panel=\(panel)") == nil)  // token out of range
        #expect(TerminalCompletionShellReport.parseBuffer("3 x - - --panel=\(panel)") == nil)  // caret
        #expect(TerminalCompletionShellReport.parseBuffer("3 1 - !!! --panel=\(panel)") == nil)  // bad base64
        #expect(TerminalCompletionShellReport.parseBuffer("3 1 - --panel=\(panel)") == nil)  // missing field
    }

    @Test("panel id parses from ready reports")
    func parsesReadyPanel() {
        #expect(TerminalCompletionShellReport.panelID("--tab=x --panel=\(panel)") == UUID(uuidString: panel))
        #expect(TerminalCompletionShellReport.panelID("--panel=nope") == nil)
    }

    @Test("generation token matches only the last digit of the live request")
    func tokenMatching() {
        #expect(TerminalCompletionShellBridge.matches(expected: 7, reportedToken: 7))
        #expect(TerminalCompletionShellBridge.matches(expected: 17, reportedToken: 7))
        #expect(!TerminalCompletionShellBridge.matches(expected: 7, reportedToken: 6))
    }

    @Test("request sequence is ESC [ 999 digit ~")
    func requestSequence() {
        #expect(TerminalCompletionShellBridge.requestSequence(token: 4) == "\u{1B}[9994~")
        #expect(TerminalCompletionShellBridge.requestSequence(token: 12) == "\u{1B}[9992~")
    }

    @MainActor
    @Test("a stale report is dropped and the matching one resolves the request")
    func deliversOnlyMatchingToken() async throws {
        let bridge = TerminalCompletionShellBridge()
        let id = try #require(UUID(uuidString: panel))
        let report = { (token: Int) in TerminalCompletionBufferReport(token: token, text: "ls", caret: 2, cwd: nil) }
        var sent = ""
        let task = Task { @MainActor in
            await bridge.request(panel: id, timeout: .seconds(2)) { sent = $0 }
        }
        await Task.yield()
        let digit = try #require(sent.dropFirst(5).first?.wholeNumberValue)
        #expect(!bridge.deliver(panel: id, report: report((digit + 1) % 10)))
        #expect(bridge.deliver(panel: id, report: report(digit)))
        #expect(await task.value?.text == "ls")
    }

    @MainActor
    @Test("ready flag is set by an announcement and cleared when a command starts")
    func readyLifecycle() throws {
        let bridge = TerminalCompletionShellBridge()
        let id = try #require(UUID(uuidString: panel))
        #expect(!bridge.isReady(panel: id))
        bridge.markReady(panel: id)
        #expect(bridge.isReady(panel: id))
        bridge.clearReady(panel: id)
        #expect(!bridge.isReady(panel: id))
    }
}
