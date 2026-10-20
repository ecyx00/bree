import AppKit
import Bonsplit
import BreeSurfaceCatalogModel
import BreeWorkspaces
import Foundation
import GhosttyKit

extension Workspace {
    var surfaceOwnershipPolicy: SurfaceOwnershipPolicy {
        SurfaceOwnershipPolicy(remoteMachine: nil)
    }

    /// A pane's projection or remote transport owns its machine, never its title
    /// or merely the workspace it happens to be displayed in.
    func machineOwningSurface(_ panelID: UUID, catalog: SurfaceCatalog? = nil) -> SurfaceMachineID? {
        let catalog = catalog ?? SurfaceCatalog.shared
        guard panels[panelID] != nil else { return nil }
        if let machine = catalog.machineOwningPanel(panelID), !machine.isLocal { return machine }
        return panels[panelID]?.transferredSurfaceMachine ?? .local
    }

    func surfaceDropRejection(
        _ transfer: PaneDragTransfer,
        source: PaneTransferSourceResolver.Source
    ) -> SurfaceTransferRejection? {
        guard surfaceOwnershipPolicy.remoteMachine != nil else { return nil }
        switch source {
        case .surfaceResources(let group):
            return SurfaceCatalog.shared.ownershipRejection(for: group.resources, policy: surfaceOwnershipPolicy)
        case .surface:
            guard transfer.isFromCurrentProcess else { return surfaceOwnershipPolicy.rejection(for: nil) }
            // A surface already in this workspace crosses no machine boundary when
            // it is reordered or split within it. Rejecting it here put the remote
            // drop gate over the workspace's own tab strips and blocked tab drags.
            if panelIdFromSurfaceId(TabID(uuid: transfer.tabId)) != nil { return nil }
            guard let app = AppDelegate.shared else { return surfaceOwnershipPolicy.rejection(for: nil) }
            return app.ownershipRejection(forBonsplitTab: transfer.tabId, policy: surfaceOwnershipPolicy)
        case .vaultSession, .filePreview, .rightSidebarTool:
            return surfaceOwnershipPolicy.rejection(for: .local)
        }
    }

    func surfaceDropRejection(_ transfer: TabDragTransfer) -> SurfaceTransferRejection? {
        let paneTransfer = PaneDragTransfer(tabDragTransfer: transfer)
        guard let source = PaneTransferSourceResolver().source(for: paneTransfer) else {
            return surfaceOwnershipPolicy.rejection(for: nil)
        }
        return surfaceDropRejection(paneTransfer, source: source)
    }

    func acceptsSurface(from source: Workspace, panelID: UUID) -> Bool {
        !isRetiredFromOwningTabManager
            && surfaceOwnershipPolicy.rejection(for: source.machineOwningSurface(panelID),
                                                kind: AppDelegate.shared?.surfaceResourceKind(for: source.panels[panelID])) == nil
    }

    func acceptsDetachedSurface(_ transfer: DetachedSurfaceTransfer) -> Bool {
        // A failed transfer must be able to restore the exact source, including
        // pre-existing mixed workspaces created before ownership was enforced.
        if transfer.origin == .workspace(id) { return true }
        let machine = transfer.surfaceMachine
            ?? SurfaceCatalog.shared.machineOwningPanel(transfer.panelId)
            ?? .local
        return surfaceOwnershipPolicy.rejection(for: machine, kind: AppDelegate.shared?.surfaceResourceKind(for: transfer.panel)) == nil
    }

    /// A one-tab edge drag leaves a placeholder behind; reuse it for a fresh terminal.
    func repairDraggedTabPlaceholder(in originalPane: PaneID, movedTabPane: PaneID, orientation: SplitOrientation) {
        let originalTabs = bonsplitController.tabs(inPane: originalPane)
        let controller = bonsplitController
        let placeholderTabs = originalTabs.filter { panelIdFromSurfaceId($0.id) == nil }
    #if DEBUG
        breeDebugLog(
            "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
            "action=reusePlaceholder placeholderCount=\(placeholderTabs.count)"
        )
    #endif
        if let replacementTab = placeholderTabs.first {
            // Keep the existing placeholder tab identity and replace only the panel mapping.
            // This avoids an extra create+close tab churn that can transiently render an
            // empty pane during drag-to-split of a single-tab pane.
            let inheritedConfig = inheritedTerminalConfig(inPane: originalPane)

            let replacementPanel = TerminalPanel(
                workspaceId: id,
                context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: inheritedConfig,
                portOrdinal: portOrdinal,
                additionalEnvironment: startupEnvironmentMergingWorkspaceEnvironment([:])
            )
            configureNewTerminalPanel(replacementPanel)
            panels[replacementPanel.id] = replacementPanel
            panelTitles[replacementPanel.id] = replacementPanel.displayTitle
            bindSurface(replacementTab.id, toPanelId: replacementPanel.id)

            bonsplitController.updateTab(
                replacementTab.id,
                title: replacementPanel.displayTitle,
                icon: .some(replacementPanel.displayIcon),
                iconImageData: .some(nil),
                kind: .some(SurfaceKind.terminal.rawValue),
                hasCustomTitle: false,
                isDirty: replacementPanel.isDirty,
                showsNotificationBadge: false,
                isLoading: false,
                isPinned: false
            )
            rememberTerminalConfigInheritanceSource(replacementPanel)
            publishBreeSurfaceCreated(replacementPanel.id, paneId: originalPane, kind: "terminal", origin: "placeholder_repair", focused: false)

            for extraPlaceholder in placeholderTabs.dropFirst() {
                bonsplitController.closeTab(extraPlaceholder.id)
            }
        } else {
    #if DEBUG
            breeDebugLog(
                "split.placeholderRepair pane=\(originalPane.id.uuidString.prefix(5)) " +
                "fallback=createTerminalAndDropPlaceholders"
            )
    #endif
            _ = newTerminalSurface(inPane: originalPane, focus: false)
            for tab in controller.tabs(inPane: originalPane) {
                if panelIdFromSurfaceId(tab.id) == nil {
                    bonsplitController.closeTab(tab.id)
                }
            }
        }
    }
}

extension BrowserPanel {
    func preferredURLStringForSessionSnapshot() -> String? {
        if let displayURL = restorableDisplayURLForCurrentErrorPage(liveURL: webView.url),
           let value = Self.serializableSessionHistoryURLString(displayURL) {
            return value
        }
        return Self.serializableSessionHistoryURLString(currentURL)
    }
}
