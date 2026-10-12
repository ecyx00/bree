import CmuxSettings
import Foundation

extension TerminalNotificationStore {
    /// Both notification effect lanes use the same organization path. The caller
    /// already applied mute, cooldown, effect policy, and the reorder setting.
    func applySidebarOrdering(for notification: TerminalNotification, effects: TerminalNotificationPolicyEffects) {
        guard effects.reorderWorkspace else { return }
        switch UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().app.reorderOnNotification) {
        case .off:
            return
        case .notifications:
            AppDelegate.shared?.tabManagerFor(tabId: notification.tabId)?
                .moveTabToTopForNotification(notification.tabId)
        case .agentActivity:
            WorkspaceActivityReorderController.shared.notificationRequestsReorder(workspaceId: notification.tabId)
        }
    }
}
