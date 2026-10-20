import BreeSurfaceCatalogModel
import Foundation

/// Browser view duplication retains resource provenance before navigation.
extension Workspace {
    @discardableResult
    func duplicateBrowserToRight(panelId: UUID, focus: Bool = true) -> BrowserPanel? {
        guard let anchorTabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId),
              let browser = browserPanel(for: panelId) else { return nil }
        guard surfaceOwnershipPolicy.rejection(for: machineOwningSurface(panelId), kind: AppDelegate.shared?.surfaceResourceKind(for: browser)) == nil else { return nil }
        let targetIndex = insertionIndexToRight(of: anchorTabId, inPane: paneId)
        guard let newPanel = newBrowserSurface(
            inPane: paneId,
            url: browser.currentURLForTabDuplication,
            focus: focus,
            preferredProfileID: browser.profileID,
            chromeVisibility: browser.chromeVisibility,
            bypassRemoteProxy: browser.bypassesRemoteWorkspaceProxyForTabDuplication,
            websiteDataStore: browser.explicitEphemeralWebsiteDataStoreForSibling
        ) else { return nil }
        newPanel.setMuted(browser.isMuted)
        syncBrowserAudioMuteStateForPanel(newPanel.id, browserPanel: newPanel)
        _ = reorderSurface(panelId: newPanel.id, toIndex: targetIndex, focus: focus)
        return newPanel
    }

}
