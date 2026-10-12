import CmuxCloud
import Bonsplit
import CmuxSurfaceCatalogModel
import Foundation

extension DockSplitStore {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        Workspace.liveWorkspace(id: workspaceId)?.surfaceOwnershipPolicy ?? .init(cloudMachine: nil)
    }

    func acceptsUnownedBrowserURL(_ url: URL?) -> Bool {
        guard url?.path == "/vnc.html" else { return true }
        return surfaceOwnershipPolicy.rejection(for: nil) == nil
    }

    func surfaceDropRejection(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source,
        policy: SurfaceOwnershipPolicy? = nil
    ) -> SurfaceTransferRejection? {
        let ownershipPolicy = policy ?? surfaceOwnershipPolicy
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: ownershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return ownershipPolicy.rejection(for: nil) }
            // A Dock surface split or reordered within this Dock stays on its machine.
            if surfaceIdToPanelId[TabID(uuid: transfer.tabId)] != nil { return nil }
            guard let app = AppDelegate.shared else { return ownershipPolicy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: ownershipPolicy)
        case .vaultSession, .filePreview, .rightSidebarTool:
            return ownershipPolicy.rejection(for: .local)
        }
    }

    func acceptsDetachedSurface(_ transfer: Workspace.DetachedSurfaceTransfer) -> Bool {
        if transfer.origin == .dock(workspaceId) { return true }
        return surfaceOwnershipPolicy.rejection(for: transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? transfer.panel.transferredSurfaceMachine, kind: AppDelegate.shared?.surfaceResourceKind(for: transfer.panel)) == nil
    }

    func acceptsRestoredDisplay(_ snapshot: SessionPanelSnapshot) -> Bool {
        if let resource = snapshot.browser?.cloudResource {
            return surfaceOwnershipPolicy.rejection(for: resource.machine, kind: resource.kind) == nil
        }
        if let raw = snapshot.browser?.urlString, URL(string: raw)?.path == "/vnc.html" {
            return surfaceOwnershipPolicy.rejection(for: nil) == nil
        }
        return true
    }

    func machineOwningSurface(_ panelID: UUID) -> SurfaceMachineID? {
        guard panels[panelID] != nil else { return nil }
        if let machine = SurfaceCatalog.shared.machineOwningPanel(panelID), !machine.isLocal { return machine }
        if let resource = (panels[panelID] as? DeferredBrowserPanel)?.sessionPanelSnapshot.browser?.cloudResource { return resource.machine }
        return panels[panelID]?.transferredSurfaceMachine
            ?? detachedSurfaceTransfersByPanelId[panelID]?.surfaceMachine
            ?? .local
    }
}

extension DockSplitStore {
    /// A Dock hosts a remote terminal only by transfer: a Cloud or SSH
    /// projection, or a remote PTY surface moved in from a remote workspace.
    func terminalRunsOnAnotherMachine(_ panelID: UUID) -> Bool {
        if detachedSurfaceTransfersByPanelId[panelID]?.isRemoteTerminal == true { return true }
        guard let machine = machineOwningSurface(panelID) else { return false }
        return !machine.isLocal
    }
}
