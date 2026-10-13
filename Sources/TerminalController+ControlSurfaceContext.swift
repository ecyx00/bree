import AppKit
import Bonsplit
import BreeControlSocket
import Foundation
import GhosttyKit

extension TerminalController {
    /// Socket error text extracted because `TerminalController.swift` sits at
    /// its file-length budget.
    nonisolated static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }
}

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let owner = routing.remoteRelayOwnerWorkspaceID {
            guard let workspace = tabManager.tabs.first(where: { $0.id == owner }),
                  remoteRelayTargetIsCurrent(routing: routing, workspace: workspace) else {
                return nil
            }
            return workspace
        }
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            if let workspace = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                return workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(surfaceID: surfaceId) != nil
            }) {
                return workspace
            }
            return tabManager.tabs.first(where: { $0.containsDockPanel(surfaceId) })
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(paneID: paneId) != nil
            }) {
                return workspace
            }
            if let located = locateDockPane(paneId), located.tabManager === tabManager {
                return located.workspace
            }
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective: SurfaceResumeBindingSnapshot
        switch SurfaceResumeApprovalStore.applyingStoredApprovalLookup(to: binding) {
        case .pendingSigningSecret:
            effective = SurfaceResumeApprovalStore.bindingWithoutStoredApproval(to: binding)
        case let .resolved(binding):
            effective = binding
        }
        let remoteContext = effective.launchFlavor.remoteContext
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            launchCommand: effective.launchCommand.map {
                controlAgentLaunchCommand(
                    $0,
                    replaySafeEnvironmentFor: effective.kind
                )
            },
            permissionMode: effective.permissionMode,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            executionLocationRawValue: effective.launchFlavor.executionLocationRawValue,
            remoteWorkspaceID: remoteContext?.workspaceID,
            remoteSurfaceID: remoteContext?.surfaceID,
            remotePTYSessionID: remoteContext?.persistentPTYSessionID,
            updatedAt: effective.updatedAt,
            resumeEvidenceProvenance: effective.resumeEvidenceProvenance
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }

        let summaries = controlSurfaceSummaries(workspace: ws).filter { summary in
            guard let owner = routing.remoteRelayOwnerWorkspaceID else { return true }
            return remoteRelaySurfaceIsOwnedByWorkspace(
                summary.surfaceID,
                workspace: ws,
                ownerWorkspaceID: owner
            )
        }
        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: summaries + (routing.remoteRelayOwnerWorkspaceID == nil
                ? controlTopologyDocks(workspace: ws, tabManager: tabManager)
                    .flatMap { controlDockSurfaceSummaries(dock: $0) }
                : [])
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let containerPanelID: UUID?
        if let owner = routing.remoteRelayOwnerWorkspaceID {
            containerPanelID = ws.activeRemoteTerminalSurfaceIds
                .sorted { $0.uuidString < $1.uuidString }
                .first {
                    remoteRelaySurfaceIsOwnedByWorkspace(
                        $0,
                        workspace: ws,
                        ownerWorkspaceID: owner
                    )
                }
                ?? ws.remoteTmuxSessionMirror?.controlPaneLocations().first(where: {
                    remoteRelaySurfaceIsOwnedByWorkspace(
                        $0.pane.panel.id,
                        workspace: ws,
                        ownerWorkspaceID: owner
                    )
                })?.pane.panel.id
        } else {
            containerPanelID = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        }
        let projection = containerPanelID.flatMap {
            ws.controlSurfaceProjection(forContainerPanelID: $0)
        }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: projection?.paneID,
            surfaceID: projection?.surfaceID,
            surfaceTypeRawValue: projection?.panel.panelType.rawValue
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = controlSurfacePanels(workspace: ws).map { panel in
            controlSurfaceHealthEntry(
                for: panel,
                terminalTarget: ws.controlSocketTerminalTarget(for: panel.id)
            )
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: items
        )
    }

    // MARK: - focus

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        switch ws.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            guard focusRemoteTmuxControlPane(
                location,
                workspace: ws,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound(surfaceID)
            }
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: location.pane.panel.id
            )
        case .unresolvedMirror:
            return .surfaceNotFound(surfaceID)
        case .notRemote:
            break
        }
        let isWorkspaceSurface = ws.panels[surfaceID] != nil
        if ws.containsDockPanel(surfaceID) {
            // Workspace-scoped Docks are retained only for compatibility and
            // have no renderable owner. Revealing the window Dock would expose
            // a different store, so explicit focus must fail closed.
            return .dockUnavailable(message: dockUnavailableMessage())
        }
        guard isWorkspaceSurface else {
            return .surfaceNotFound(surfaceID)
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        // Record explicit intent before selection schedules focus restoration.
        tabManager.focusTab(ws.id, surfaceId: surfaceID, suppressFlash: true)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
