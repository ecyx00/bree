import Foundation

/// Local title ownership.
extension Workspace {
    /// Sets, replaces, or clears (empty/nil `title`) a panel custom title.
    ///
    /// `.auto` writes are rejected when a user or remote title exists, and
    /// `.auto` never clears. `.remote` is the remote daemon's canonical value and
    /// may replace a local title. Returns whether the write landed.
    @discardableResult
    func setPanelCustomTitle(
        panelId: UUID,
        title: String?,
        source: CustomTitleSource = .user,
        propagateToRemoteTmux: Bool = true
    ) -> Bool {
        guard panels[panelId] != nil else { return false }
        let previousWorkspaceTitle = self.title
        defer {
            if self.title != previousWorkspaceTitle {
                owningTabManager?.panelCustomTitleDidReconcileWorkspaceTitle(self)
            }
        }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let previous = panelCustomTitles[panelId]
        if source == .auto {
            guard !trimmed.isEmpty else { return false }
            if previous != nil, (panelCustomTitleSources[panelId] ?? .user) != .auto { return false }
        }
        var sameText = false
        if trimmed.isEmpty {
            guard previous != nil else { return false }
            if previous != nil {
                panelCustomTitles.removeValue(forKey: panelId)
                panelCustomTitleSources.removeValue(forKey: panelId)
            }
        } else {
            if previous == trimmed {
                // Same text still updates provenance. A remote observation must
                // be able to turn a just-confirmed local intent into settled
                // daemon-owned state without changing the visible tab twice.
                panelCustomTitleSources[panelId] = source
                sameText = true
            } else {
                panelCustomTitles[panelId] = trimmed
                panelCustomTitleSources[panelId] = source
            }
        }

        applyFocusedPanelTitle(panelId: panelId)

        // A repeated remote or automatic observation only changes provenance.
        // A repeated USER edit remains an idempotent intent and must still reach
        // the daemon, because the earlier request may have failed or been lost.
        if sameText, source != .user { return true }

        guard let panel = panels[panelId], let tabId = surfaceIdFromPanelId(panelId) else { return true }
        let baseTitle = panelTitles[panelId] ?? panel.displayTitle
        bonsplitController.updateTab(
            tabId,
            title: resolvedPanelTitle(panelId: panelId, fallback: baseTitle),
            hasCustomTitle: panelCustomTitles[panelId] != nil
        )
        // A remote tmux mirror tab rename propagates to `rename-window`.
        if propagateToRemoteTmux, isRemoteTmuxMirror {
            AppDelegate.shared?.remoteTmuxController.handleMirrorWindowRenamed(
                workspaceId: id, panelId: panelId, title: trimmed
            )
        }
        return true
    }

}
