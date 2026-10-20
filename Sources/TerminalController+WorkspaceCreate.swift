import Foundation

extension TerminalController {
    struct TaskCreateWorkspaceCandidate {
        let tabManager: TabManager
        let windowID: UUID?
    }

    struct TaskCreateWorkspaceResolution {
        let workspace: Workspace
        let candidate: TaskCreateWorkspaceCandidate
    }

    nonisolated static func v2ExpandedWorkingDirectory(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.hasPrefix("~") else { return trimmed }
        return (trimmed as NSString).expandingTildeInPath
    }

    // Shared workspace-create implementation: the workspace.create command moved
    // to ControlCommandCoordinator, which forwards to this body.
    func v2WorkspaceCreate(
        params: [String: Any],
        tabManager resolvedTabManager: TabManager? = nil,
        taskCreateCandidates: [TaskCreateWorkspaceCandidate]? = nil,
        idempotencyCache: WorkspaceCreateIdempotencyCache? = nil
    ) -> V2CallResult {
        let outcome = v2PrepareWorkspaceCreate(
            params: params,
            tabManager: resolvedTabManager,
            taskCreateCandidates: taskCreateCandidates,
            idempotencyCache: idempotencyCache
        )
        let preparation: WorkspaceCreatePreparation
        switch outcome {
        case let .failure(result):
            return result
        case let .existing(resolution):
            return workspaceCreateResult(
                workspace: resolution.workspace,
                windowID: resolution.candidate.windowID
            )
        case let .completed(_, operationID):
            return .err(
                code: "already_completed",
                message: "workspace.create operation already completed",
                data: ["operation_id": operationID.uuidString]
            )
        case let .ready(ready):
            preparation = ready
        }
        let workingDirectory = Self.v2ExpandedWorkingDirectory(
            v2RawString(params, "working_directory")
        )
        let execution: WorkspaceCreateExecutionPreparation
        switch v2PrepareWorkspaceCreateExecution(
            params: params,
            preparation: preparation,
            workingDirectory: workingDirectory
        ) {
        case let .failure(result):
            return result
        case let .ready(ready):
            execution = ready
        }
        return v2PerformWorkspaceCreate(
            preparation: preparation,
            execution: execution
        )
    }

    private func v2PerformWorkspaceCreate(
        preparation: WorkspaceCreatePreparation,
        execution: WorkspaceCreateExecutionPreparation,
        operationAlreadyAccepted: Bool = false
    ) -> V2CallResult {
        let tabManager = preparation.tabManager
        let operationID = preparation.operationID

        guard let result = tabManager.acquireWorkspaceIfActive({ () -> V2CallResult in
            var newWorkspace: Workspace?
            if let operationID, !operationAlreadyAccepted {
                // Acceptance must be durable before addWorkspace constructs a
                // terminal and can execute the task command. A crash in between
                // intentionally favors at-most-once startup over workspace recovery.
                do {
                    try preparation.idempotencyCache.accept(operationID: operationID)
                } catch {
                    workspaceCreateIdempotencyLogger.error(
                        "Task reservation failed: \(String(describing: error), privacy: .private)"
                    )
                    return .err(
                        code: "persistence_failed",
                        message: "Workspace task could not be reserved safely",
                        data: nil
                    )
                }
            }
            v2MainSync {
                let initialTerminalInput = execution.layoutNode == nil ? execution.initialInput : nil
                guard let ws = tabManager.addWorkspaceIfActive(
                    title: execution.title,
                    workingDirectory: execution.workingDirectory,
                    initialTerminalCommand: execution.layoutNode == nil ? execution.initialCommand : nil,
                    initialTerminalIsRemote: execution.layoutNode == nil && execution.initialTerminalIsRemote,
                    initialTerminalInput: initialTerminalInput,
                    initialTerminalEnvironment: execution.layoutNode == nil ? execution.initialEnvironment : [:],
                    workspaceEnvironment: execution.workspaceEnvironment,
                    select: execution.shouldFocus,
                    eagerLoadTerminal: execution.shouldEagerLoadTerminal,
                    autoWelcomeIfNeeded: initialTerminalInput == nil,
                    autoRefreshMetadata: execution.shouldAutoRefreshMetadata
                ) else { return }
                ws.taskCreateOperationID = operationID
                if execution.titleSource == .auto, execution.title != nil {
                    // The source is captured before this create returns to the
                    // caller, so a later bind can distinguish the placeholder
                    // from an explicit user rename with identical text.
                    ws.customTitleSource = .auto
                }
                ws.setCustomDescription(execution.description)
                if let layoutNode = execution.layoutNode {
                    ws.applyCustomLayout(
                        layoutNode,
                        baseCwd: execution.workingDirectory ?? ws.currentDirectory
                    )
                }
                if let groupID = execution.groupID {
                    tabManager.addWorkspaceToGroup(
                        workspaceId: ws.id,
                        groupId: groupID,
                        placement: execution.groupPlacement ?? .top,
                        referenceWorkspaceId: execution.groupReferenceWorkspaceID
                    )
                }
                newWorkspace = ws
            }

            guard let newWorkspace else {
                return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
            }
            if let operationID {
                preparation.idempotencyCache.associate(operationID: operationID, workspaceID: newWorkspace.id)
            }
            return workspaceCreateResult(
                workspace: newWorkspace,
                windowID: v2ResolveWindowId(tabManager: tabManager)
            )
        }) else {
            return .err(code: "internal_error", message: "Failed to create workspace", data: nil)
        }
        return result
    }

    private func workspaceCreateResult(
        workspace: Workspace,
        windowID: UUID?
    ) -> V2CallResult {
        let workspaceID = workspace.id
        let groupID = workspace.groupId
        let surfaceID = workspace.focusedPanelId
        return .ok([
            "window_id": v2OrNull(windowID?.uuidString),
            "window_ref": v2Ref(kind: .window, uuid: windowID),
            "workspace_id": workspaceID.uuidString,
            "workspace_ref": v2Ref(kind: .workspace, uuid: workspaceID),
            "group_id": v2OrNull(groupID?.uuidString),
            "group_ref": v2Ref(kind: .workspaceGroup, uuid: groupID),
            "surface_id": v2OrNull(surfaceID?.uuidString),
            "surface_ref": v2Ref(kind: .surface, uuid: surfaceID)
        ])
    }
}
