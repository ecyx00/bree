import Foundation

/// The buffer a shell integration reports when the app asks for it with the
/// private key sequence (see `TerminalCompletionShellBridge.requestSequence`).
struct TerminalCompletionBufferReport: Equatable, Sendable {
    /// Last digit of the request generation the shell answered.
    var token: Int
    var text: String
    /// Caret in characters.
    var caret: Int
    var cwd: String?
}

/// Wire parsing for the two v1 socket commands the shell integrations send:
///
///     report_completion_ready  --tab=<uuid> --panel=<uuid>
///     report_completion_buffer <token> <cursor> <pwd-b64|-> <buffer-b64|-> --tab=<uuid> --panel=<uuid>
///
/// The buffer and the directory are base64 so no shell metacharacter, space
/// or newline can reach the socket line unescaped. `-` stands for empty.
enum TerminalCompletionShellReport {
    static func panelID(_ arguments: String) -> UUID? {
        for part in arguments.split(separator: " ") where part.hasPrefix("--panel=") {
            return UUID(uuidString: String(part.dropFirst("--panel=".count)))
        }
        return nil
    }

    static func parseBuffer(_ arguments: String) -> (panel: UUID, report: TerminalCompletionBufferReport)? {
        guard let panel = panelID(arguments) else { return nil }
        let positional = arguments.split(separator: " ").filter { !$0.hasPrefix("--") }
        guard positional.count == 4,
              let token = Int(positional[0]), (0...9).contains(token),
              let caret = Int(positional[1]), caret >= 0,
              let text = decode(positional[3]) else { return nil }
        let cwd = decode(positional[2])
        let clamped = min(caret, text.count)
        return (panel, TerminalCompletionBufferReport(
            token: token,
            text: text,
            caret: clamped,
            cwd: cwd?.isEmpty == false ? cwd : nil
        ))
    }

    private static func decode(_ field: Substring) -> String? {
        if field == "-" { return "" }
        guard let data = Data(base64Encoded: String(field)) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Per-panel completion capability and the one in-flight buffer request.
///
/// A shell that loaded the widget announces `report_completion_ready`; only
/// those panels are ever sent the private sequence, which would otherwise
/// print as garbage. The sequence carries the last digit of a generation, so
/// a report that answers an older, timed-out request is dropped.
@MainActor
final class TerminalCompletionShellBridge {
    static let shared = TerminalCompletionShellBridge()

    /// `ESC [ 999<digit> ~`: a CSI function-key form no terminal emits (xterm
    /// function keys top out at 34), so nothing else produces or consumes it.
    static func requestSequence(token: UInt64) -> String {
        "\u{1B}[999\(token % 10)~"
    }

    static func matches(expected: UInt64, reportedToken: Int) -> Bool {
        Int(expected % 10) == reportedToken
    }

    private struct Waiter {
        var serial: UInt64
        var expected: UInt64
        var continuation: CheckedContinuation<TerminalCompletionBufferReport?, Never>
    }

    private(set) var readyPanels: Set<UUID> = []
    private var waiters: [UUID: Waiter] = [:]
    private var serial: UInt64 = 0
    private var nextToken: UInt64 = 0

    func isReady(panel: UUID) -> Bool { readyPanels.contains(panel) }

    func markReady(panel: UUID) { readyPanels.insert(panel) }

    /// A command started: another shell may take the prompt, so the panel must
    /// re-announce at its next prompt.
    func clearReady(panel: UUID) { readyPanels.remove(panel) }

    /// Called by the socket handler. Returns true when a waiting request took it.
    @discardableResult
    func deliver(panel: UUID, report: TerminalCompletionBufferReport) -> Bool {
        guard let waiter = waiters[panel],
              Self.matches(expected: waiter.expected, reportedToken: report.token) else { return false }
        waiters[panel] = nil
        waiter.continuation.resume(returning: report)
        return true
    }

    /// Writes the request sequence through `send` and waits up to `timeout`
    /// for the matching report. Nil on timeout.
    func request(
        panel: UUID,
        timeout: Duration = .milliseconds(250),
        send: (String) -> Void
    ) async -> TerminalCompletionBufferReport? {
        nextToken &+= 1
        let token = nextToken
        serial &+= 1
        let mine = serial
        return await withCheckedContinuation { continuation in
            waiters[panel]?.continuation.resume(returning: nil)
            waiters[panel] = Waiter(serial: mine, expected: token, continuation: continuation)
            send(Self.requestSequence(token: token))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.expire(panel: panel, serial: mine)
            }
        }
    }

    private func expire(panel: UUID, serial: UInt64) {
        guard let waiter = waiters[panel], waiter.serial == serial else { return }
        waiters[panel] = nil
        waiter.continuation.resume(returning: nil)
    }
}
