import Bonsplit
import CoreGraphics
import Foundation

/// Bottom-panel behavior of the Dock engine. The panel is a per-workspace
/// `DockSplitStore` hosted under the main split; it never reads `dock.json`.
extension DockSplitStore {
    static let bottomPanelMinHeight: CGFloat = 120
    static let bottomPanelDefaultHeightFraction: CGFloat = 0.3
    static let bottomPanelMaxHeightFraction: CGFloat = 0.8

    /// Skips the legacy config load so nothing seeds, prompts for trust or
    /// reloads (and kills terminals) behind the panel's back.
    func prepareForBottomPanel() {
        guard !isRetired else { return }
        isBottomPanelHost = true
        guard !hasLoadedConfiguration else { return }
        cancelConfigurationTasks()
        hasLoadedConfiguration = true
        hasAppliedConfigurationSeed = true
    }

    /// Creates the first terminal in the workspace cwd when the panel has no
    /// content. Returns whether the panel has content afterwards.
    @discardableResult
    func ensureBottomPanelContent() -> Bool {
        prepareForBottomPanel()
        guard !isRetired else { return false }
        if !panels.isEmpty { return true }
        guard let paneId = resolvePane(requestedPaneID: nil) else { return false }
        return newSurface(kind: .terminal, inPane: paneId, focus: false) != nil
    }

    /// Height in points for the given content height: persisted value or 30%,
    /// clamped to the minimum and to 80% of the content.
    func resolvedBottomPanelHeight(forContentHeight total: CGFloat) -> CGFloat {
        let maxHeight = max(Self.bottomPanelMinHeight, total * Self.bottomPanelMaxHeightFraction)
        let wanted = bottomPanelHeight.map { CGFloat($0) }
            ?? total * Self.bottomPanelDefaultHeightFraction
        return min(max(wanted, Self.bottomPanelMinHeight), maxHeight)
    }

    /// Hides an open panel once its last panel closed. Skipped while a restore,
    /// reset or teardown empties the panel on purpose.
    func notifyBottomPanelEmptyIfNeeded() {
        guard isBottomPanelOpen, !suppressBottomPanelEmptyHide, !isRetired, panels.isEmpty else { return }
        // Defer: this runs inside a Bonsplit close callback.
        Task { @MainActor [weak self] in
            guard let self, self.isBottomPanelOpen, !self.suppressBottomPanelEmptyHide,
                  !self.isRetired, self.panels.isEmpty else { return }
            self.terminalFontSizeOwningWorkspace?.setBottomPanelOpen(false)
        }
    }

    /// Applies persisted presentation state after a session restore.
    func applyBottomPanelSnapshot(isOpen: Bool?, height: Double?) {
        prepareForBottomPanel()
        bottomPanelHeight = height
        guard isOpen == true else { return }
        if !panels.isEmpty || ensureBottomPanelContent() {
            isBottomPanelOpen = true
        }
    }
}
