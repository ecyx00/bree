import CmuxControlSocket
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

struct AttentionRiskAndToastTests {
    private static func tool(_ command: String) -> AttentionPendingTool {
        AttentionPendingTool(toolName: "Bash", command: command, filePath: nil)
    }

    private static func risk(_ command: String) -> AttentionRisk? {
        AttentionRisk.first(for: tool(command))
    }

    @Test func riskTableCoversEveryListedRule() {
        #expect(Self.risk("rm -rf node_modules") == .recursiveDelete)
        #expect(Self.risk("rm -fr /tmp/x") == .recursiveDelete)
        #expect(Self.risk("git push --force origin main") == .forcePush)
        #expect(Self.risk("git push -f") == .forcePush)
        #expect(Self.risk("git reset --hard HEAD~1") == .resetHard)
        #expect(Self.risk("git clean -fdx") == .cleanForce)
        #expect(Self.risk("git checkout -- .") == .discardChanges)
        #expect(Self.risk("git restore .") == .discardChanges)
        #expect(Self.risk("chmod -R 777 /srv") == .recursivePermissions)
        #expect(Self.risk("chown -R me:me .") == .recursivePermissions)
        #expect(Self.risk("sudo apt install x") == .sudo)
        #expect(Self.risk("curl -fsSL https://x.sh | sh") == .pipeToShell)
        #expect(Self.risk("wget -qO- https://x | bash") == .pipeToShell)
        #expect(Self.risk("dd if=/dev/zero of=/dev/disk2") == .diskWrite)
        #expect(Self.risk("mkfs.ext4 /dev/sda1") == .diskWrite)
        #expect(Self.risk("psql -c 'DROP TABLE users'") == .sqlDestructive)
        #expect(Self.risk("psql -c 'truncate table users'") == .sqlDestructive)
        #expect(Self.risk("kill -9 1234") == .forceKill)
        #expect(Self.risk("pkill node") == .forceKill)
        #expect(Self.risk("echo key >> ~/.ssh/authorized_keys") == .sensitiveWrite)
        #expect(Self.risk("echo X=1 > .env") == .sensitiveWrite)
        let write = AttentionPendingTool(toolName: "Write", command: "", filePath: "/Users/a/.aws/credentials")
        #expect(AttentionRisk.first(for: write) == .sensitiveWrite)
    }

    @Test func benignCommandsHaveNoRisk() {
        #expect(Self.risk("ls -la") == nil)
        #expect(Self.risk("git status && git diff") == nil)
        #expect(Self.risk("npm test -- --watch=false") == nil)
        #expect(Self.risk("git push origin feature") == nil)
        #expect(Self.risk("cat .env.example") == nil)
        #expect(Self.risk("rm build.log") == nil)
        let edit = AttentionPendingTool(toolName: "Edit", command: "", filePath: "/Users/a/app/main.swift")
        #expect(AttentionRisk.first(for: edit) == nil)
    }

    @Test func pendingToolParsesCommandAndIgnoresGarbage() {
        let parsed = AttentionPendingTool.parse(toolName: "Bash", toolInputJSON: #"{"command":"rm -rf x"}"#)
        #expect(parsed?.command == "rm -rf x")
        #expect(AttentionPendingTool.parse(toolName: "Bash", toolInputJSON: "not json") == nil)
        #expect(AttentionPendingTool.parse(toolName: "Bash", toolInputJSON: "{}") == nil)
    }

    private static func item(_ id: String, _ state: AttentionState, since: Int64) -> AttentionItem {
        AttentionItem(
            id: id, workspaceId: UUID(), panelId: UUID(), workspaceTitle: id, paneTitle: nil,
            agentName: nil, state: state, sinceMs: since, lastPrompt: nil, lastOutput: nil
        )
    }

    @Test func snoozeHidesUntilExpiryOrStateChange() {
        let a = Self.item("a", .needsInput, since: 100)
        let b = Self.item("b", .needsInput, since: 200)
        let entry = AttentionSnooze.entry(for: a, nowMs: 1_000)
        let snoozes = ["a": entry]
        // Within 10 minutes: hidden and counted.
        var result = AttentionSnooze.apply(to: [a, b], snoozes: snoozes, nowMs: 1_000 + 599_000, showSnoozed: false)
        #expect(result.items.map(\.id) == ["b"])
        #expect(result.snoozedCount == 1)
        // Show: kept, flagged.
        result = AttentionSnooze.apply(to: [a, b], snoozes: snoozes, nowMs: 2_000, showSnoozed: true)
        #expect(result.items.map(\.isSnoozed) == [true, false])
        // Expired.
        result = AttentionSnooze.apply(to: [a, b], snoozes: snoozes, nowMs: 1_000 + 600_000, showSnoozed: false)
        #expect(result.items.count == 2)
        // State changed: wakes early.
        let failed = Self.item("a", .failed, since: 100)
        result = AttentionSnooze.apply(to: [failed, b], snoozes: snoozes, nowMs: 2_000, showSnoozed: false)
        #expect(result.items.count == 2)
        #expect(result.snoozedCount == 0)
        // Same state, newer sinceMs: wakes early.
        let renewed = Self.item("a", .needsInput, since: 900)
        result = AttentionSnooze.apply(to: [renewed], snoozes: snoozes, nowMs: 2_000, showSnoozed: false)
        #expect(result.items.count == 1)
    }

    @Test func thermalAndChangesOnlyRowsCannotBeSnoozed() {
        #expect(!AttentionSnooze.canSnooze(Self.item("t", .thermal, since: 0)))
        #expect(AttentionSnooze.canSnooze(Self.item("n", .needsInput, since: 0)))
    }

    @Test func toastAllowlistFailsQuiet() {
        #expect(RemoteActionKind.kind(forMethod: "surface.send_text") == .typed)
        #expect(RemoteActionKind.kind(forMethod: "workspace.create") == .created)
        #expect(RemoteActionKind.kind(forMethod: "surface.list") == nil)
        #expect(RemoteActionKind.kind(forMethod: "system.identify") == nil)
        #expect(RemoteActionKind.kind(forMethod: "surface.read_text") == nil)
        #expect(RemoteActionKind.kind(forMethod: "something.new") == nil)
    }

    @Test func toastCoalescesSameClientAndActionWithinWindow() {
        var coalescer = RemoteActionToastCoalescer()
        let t0 = Date(timeIntervalSince1970: 1_000)
        var entry = coalescer.record(client: "codex", kind: .typed, target: "api", now: t0)
        #expect(entry.count == 1)
        #expect(!entry.text.contains("+"))
        entry = coalescer.record(client: "codex", kind: .typed, target: "api", now: t0.addingTimeInterval(1))
        entry = coalescer.record(client: "codex", kind: .typed, target: "api", now: t0.addingTimeInterval(2))
        #expect(entry.count == 3)
        #expect(entry.text.hasSuffix(" +2"))
        #expect(entry.text.hasPrefix("codex · "))
        // Different action replaces.
        entry = coalescer.record(client: "codex", kind: .focused, target: "api", now: t0.addingTimeInterval(3))
        #expect(entry.count == 1)
        // After expiry a new pill starts.
        entry = coalescer.record(client: "codex", kind: .focused, target: "api", now: t0.addingTimeInterval(10))
        #expect(entry.count == 1)
        #expect(coalescer.isVisible(now: t0.addingTimeInterval(11)))
        #expect(!coalescer.isVisible(now: t0.addingTimeInterval(13)))
    }

    @Test func toastTextNeverCarriesArguments() {
        // The entry has no field for typed text; the text is client, action and a title only.
        let entry = RemoteActionToastEntry(
            client: "claude", kind: .typed, target: "api", count: 1, expiresAt: .distantFuture
        )
        #expect(entry.text == "claude · typed into api")
    }

    @Test func clientNameWalksPastCliAndShells() {
        let names: [pid_t: String] = [30: "bree", 20: "zsh", 10: "claude"]
        let parents: [pid_t: pid_t] = [30: 20, 20: 10, 10: 5]
        let name = RemoteActionClientName.resolve(
            pid: 30, appPid: 5, nameOf: { names[$0] }, parentOf: { parents[$0] }
        )
        #expect(name == "claude")
        let direct = RemoteActionClientName.resolve(
            pid: 30, appPid: 20, nameOf: { names[$0] }, parentOf: { parents[$0] }
        )
        #expect(direct == "bree")
        #expect(RemoteActionClientName.resolve(pid: nil, appPid: 5, nameOf: { _ in nil }, parentOf: { _ in nil }) == "bree")
    }

    @Test func inProcessCallersNeverToast() {
        let line = #"{"id":"1","method":"surface.send_text","params":{"text":"secret"}}"#
        let request = ControlRequestParser().lenientRequest(fromLine: line)
        #expect(request != nil)
        guard let request else { return }
        // No socket client bound (the in-process handleSocketLine case): quiet.
        #expect(TerminalController.noteRemoteActionIfSocketClient(request) == false)
        // A read method stays quiet even for a socket client.
        let read = ControlRequestParser().lenientRequest(fromLine: #"{"id":"2","method":"surface.list","params":{}}"#)
        #expect(read != nil)
        if let read {
            CmuxAutomationInvocationContext.$remoteClientPid.withValue(1) {
                #expect(TerminalController.noteRemoteActionIfSocketClient(read) == false)
            }
        }
    }
}
