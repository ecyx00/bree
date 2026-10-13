import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

@MainActor
@Suite(.serialized) struct WorkspaceCreateWorkingDirectoryTests {
    @Test func expandsHomeDirectory() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("~") == NSHomeDirectory())
    }

    @Test func expandsHomeSubdirectory() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("~/sub/dir") == "\(NSHomeDirectory())/sub/dir")
    }

    @Test func absolutePathPassesThrough() {
        #expect(TerminalController.v2ExpandedWorkingDirectory("/tmp/project") == "/tmp/project")
    }

    @Test func nilAndEmptyReturnNil() {
        #expect(TerminalController.v2ExpandedWorkingDirectory(nil) == nil)
        #expect(TerminalController.v2ExpandedWorkingDirectory(" \n ") == nil)
    }

    @Test func sameOperationIDCreatesOneWorkspaceWithOneInitialAgentCommand() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let operationID = UUID()
        let initialCommand = "codex \"${BREE_TASK_PROMPT}\""
        let params: [String: Any] = [
            "operation_id": operationID.uuidString,
            "title": "Idempotent Task",
            "initial_command": initialCommand,
            "initial_env": ["BREE_TASK_PROMPT": "Fix the composer"],
        ]
        let cache = Self.makeCache()

        let first = TerminalController.shared.v2WorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let retry = TerminalController.shared.v2WorkspaceCreate(
            params: params,
            tabManager: manager,
            idempotencyCache: cache
        )
        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let createdPanels = created.panels.values.compactMap { $0 as? TerminalPanel }

        #expect(manager.tabs.count == initialWorkspaceIDs.count + 1)
        #expect(createdPanels.count == 1)
        let launchedCommand = try #require(createdPanels.first?.surface.debugInitialCommand())
        #expect(launchedCommand == WorkspaceInitialCommandLoginShell.wrap(initialCommand))
        #expect(launchedCommand.contains(initialCommand))
        #expect(Self.workspaceID(from: first) == created.id)
        #expect(Self.workspaceID(from: retry) == created.id)
    }

    @Test func initialAgentCommandLaunchesThroughLoginShellWithShimPath() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let initialCommand = "claude -- \"$BREE_TASK_PROMPT\""

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_command": initialCommand,
            "initial_env": ["BREE_TASK_PROMPT": "Fix the composer"],
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        let launchedCommand = try #require(panel.surface.debugInitialCommand())

        #expect(launchedCommand != initialCommand)
        #expect(launchedCommand.contains("-lc"))
        #expect(launchedCommand.contains(initialCommand))
        #expect(launchedCommand.contains("BREE_CLAUDE_WRAPPER_SHIM_ROOT"))
    }

    @Test func initialAgentCommandPreservesSurroundingWhitespaceThroughTerminalStartup() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))
        let initialCommand = " \nprintf '  preserved  '\n "

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_command": initialCommand,
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        let launchedCommand = try #require(panel.surface.debugInitialCommand())
        #expect(launchedCommand == WorkspaceInitialCommandLoginShell.wrap(initialCommand))
        #expect(
            launchedCommand
                .replacingOccurrences(of: "'\"'\"'", with: "'")
                .contains(initialCommand)
        )
    }

    @Test func whitespaceOnlyInitialAgentCommandStartsPlainShell() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_command": " \n\t ",
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.debugInitialCommand() == nil)
    }

    @Test(arguments: ["/bin/zsh", "/bin/bash", "/usr/local/bin/fish"])
    func workspaceInitialCommandPreservesShellArguments(shell: String) throws {
        let command = "printf 'hello'\necho done"
        let arguments = try Self.decodeShellArguments(WorkspaceInitialCommandLoginShell.wrap(command, userShell: shell))
        try #require(arguments.count == 3)
        #expect(arguments[0] == shell)
        #expect(arguments[1] == "-lc")
        #expect(arguments[2].hasSuffix("\n" + command))
    }

    @Test(arguments: [nil, "/opt/weird/nu"] as [String?])
    func workspaceInitialCommandFallsBackToZsh(shell: String?) throws {
        let command = "printf 'hello'\necho done"
        let arguments = try Self.decodeShellArguments(WorkspaceInitialCommandLoginShell.wrap(command, userShell: shell))
        try #require(arguments.count == 3)
        #expect(arguments[0] == "/bin/zsh")
        #expect(arguments[1] == "-lc")
        #expect(arguments[2].hasSuffix("\n" + command))
    }

    /// Let the system shell decode quoting without executing the wrapped command.
    /// The portable login-shell tests execute the payload and verify PATH safety.
    private static func decodeShellArguments(_ command: String) throws -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "set -- " + command + "; printf '%s\\0' \"$@\""]
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        return data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    @Test func initialEnvironmentRejectsCStringTruncationAndPreservesEmptyPrompt() throws {
        let manager = TabManager()
        let initialWorkspaceIDs = Set(manager.tabs.map(\.id))

        _ = TerminalController.shared.v2WorkspaceCreate(params: [
            "initial_env": [
                "BREE_SOCKET_PATH\u{0}x": "spoofed",
                "BAD=KEY": "value",
                "NUL_VALUE": "a\u{0}b",
                "BREE_TASK_PROMPT": "",
                "GOOD": "value",
            ],
        ], tabManager: manager)

        let created = try #require(manager.tabs.first { !initialWorkspaceIDs.contains($0.id) })
        let panel = try #require(created.panels.values.compactMap { $0 as? TerminalPanel }.first)
        #expect(panel.surface.respawnInitialEnvironmentOverrides == [
            "BREE_TASK_PROMPT": "",
            "GOOD": "value",
        ])
    }

    @Test func taskCreateOperationIDSurvivesSnapshotRestoreWithFreshRuntimeWorkspaceID() throws {
        let operationID = UUID()
        let original = Workspace()
        original.taskCreateOperationID = operationID

        let snapshot = original.sessionSnapshot(includeScrollback: false)
        let restored = Workspace()
        _ = restored.restoreSessionSnapshot(snapshot)

        #expect(snapshot.taskCreateOperationID == operationID)
        #expect(restored.taskCreateOperationID == operationID)
        #expect(restored.id != original.id)
    }

    @Test(arguments: [false, true])
    func retryFindsRestoredWorkspaceBeforeFreshCacheWithoutLaunchingCommand(reserveOriginalID: Bool) throws {
        let operationID = UUID()
        let sourceManager = TabManager()
        let sourceWorkspace = try #require(sourceManager.selectedWorkspace)
        sourceWorkspace.taskCreateOperationID = operationID
        let snapshot = sourceManager.sessionSnapshot(includeScrollback: false)
        let manager = TabManager()
        manager.restoreSessionSnapshot(
            snapshot,
            excludingWorkspaceIds: reserveOriginalID ? [sourceWorkspace.id] : []
        )
        let restored = try #require(manager.selectedWorkspace)
        let initialIDs = Set(manager.tabs.map(\.id))
        let cache = Self.makeCache()

        let result = TerminalController.shared.v2WorkspaceCreate(params: [
            "operation_id": operationID.uuidString,
            "initial_command": "must-not-launch",
        ], tabManager: manager, idempotencyCache: cache)

        #expect(Set(manager.tabs.map(\.id)) == initialIDs)
        if reserveOriginalID {
            #expect(restored.id != sourceWorkspace.id)
        } else {
            #expect(restored.id == sourceWorkspace.id)
        }
        #expect(restored.taskCreateOperationID == operationID)
        #expect(restored.panels.values.compactMap { $0 as? TerminalPanel }
            .allSatisfy { $0.surface.debugInitialCommand() != "must-not-launch" })
        #expect(Self.workspaceID(from: result) == restored.id)
    }

    @Test func retryFromAnotherManagerReturnsOwningWindowWithoutCreatingWorkspaceOrCommand() throws {
        let operationID = UUID()
        let currentManager = TabManager()
        let ownerManager = TabManager()
        let ownerWindowID = UUID()
        let ownerWorkspace = try #require(ownerManager.selectedWorkspace)
        ownerWorkspace.taskCreateOperationID = operationID
        let cache = Self.makeCache()
        cache.record(
            operationID: operationID,
            workspaceID: ownerWorkspace.id
        )
        let currentIDs = Set(currentManager.tabs.map(\.id))
        let ownerIDs = Set(ownerManager.tabs.map(\.id))

        let result = TerminalController.shared.v2WorkspaceCreate(
            params: [
                "operation_id": operationID.uuidString,
                "initial_command": "must-not-launch",
            ],
            tabManager: currentManager,
            taskCreateCandidates: [
                .init(tabManager: currentManager, windowID: UUID()),
                .init(tabManager: ownerManager, windowID: ownerWindowID),
            ],
            idempotencyCache: cache
        )

        #expect(Set(currentManager.tabs.map(\.id)) == currentIDs)
        #expect(Set(ownerManager.tabs.map(\.id)) == ownerIDs)
        #expect(ownerWorkspace.panels.values.compactMap { $0 as? TerminalPanel }
            .allSatisfy { $0.surface.debugInitialCommand() != "must-not-launch" })
        #expect(Self.workspaceID(from: result) == ownerWorkspace.id)
        #expect(Self.windowID(from: result) == ownerWindowID)
    }

    @Test func synchronousControlCreateKeepsWorkingDirectoryAsCwdWithoutFilesystemValidation() throws {
        let manager = TabManager()
        let baselineIDs = Set(manager.tabs.map(\.id))
        let requestedDirectory = "/missing/control-cwd-\(UUID().uuidString)"

        let result = TerminalController.shared.v2WorkspaceCreate(params: [
            "working_directory": requestedDirectory,
        ], tabManager: manager)
        let createdID = try #require(Self.workspaceID(from: result))
        let created = try #require(manager.tabs.first { $0.id == createdID })

        #expect(Set(manager.tabs.map(\.id)).subtracting(baselineIDs) == [createdID])
        #expect(created.currentDirectory == requestedDirectory)
    }

    @Test func legacyCwdRemainsCompatible() {
        let manager = TabManager()

        let legacyResult = TerminalController.shared.v2WorkspaceCreate(params: [
            "cwd": "relative/legacy-path",
        ], tabManager: manager)

        #expect(Self.workspaceID(from: legacyResult) != nil)
    }

    @Test func idempotencyCacheEvictsSuccessfulResultsInFIFOOrder() {
        let cache = Self.makeCache(capacity: 2)
        let firstID = UUID()
        let secondID = UUID()
        let thirdID = UUID()
        let firstWorkspaceID = UUID()
        let secondWorkspaceID = UUID()
        let thirdWorkspaceID = UUID()

        cache.record(operationID: firstID, workspaceID: firstWorkspaceID)
        cache.record(operationID: secondID, workspaceID: secondWorkspaceID)
        #expect(cache.workspaceID(for: firstID) == firstWorkspaceID)
        cache.record(operationID: thirdID, workspaceID: thirdWorkspaceID)

        #expect(cache.workspaceID(for: firstID) == nil)
        #expect(cache.workspaceID(for: secondID) == secondWorkspaceID)
        #expect(cache.workspaceID(for: thirdID) == thirdWorkspaceID)
    }

    private static func workspaceID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["workspace_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }

    private static func makeCache(capacity: Int = 256) -> TerminalController.WorkspaceCreateIdempotencyCache {
        TerminalController.WorkspaceCreateIdempotencyCache(
            capacity: capacity,
            persistence: InMemoryWorkspaceCreateIdempotencyStore()
        )
    }

    private static func errorCode(from result: TerminalController.V2CallResult) -> String? {
        guard case .err(let code, _, _) = result else { return nil }
        return code
    }

    private static func windowID(from result: TerminalController.V2CallResult) -> UUID? {
        guard case .ok(let rawPayload) = result,
              let payload = rawPayload as? [String: Any],
              let rawID = payload["window_id"] as? String else {
            return nil
        }
        return UUID(uuidString: rawID)
    }

}
