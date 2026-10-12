import Foundation

@testable import CmuxSettingsUI

@MainActor
final class CountingDesktopAuthorizationHostActions: SettingsHostActions {
    var desktopStatusReads = 0
    var desktopStreamCreations = 0
    var desktopRefreshes = 0
    var desktopStatus: DesktopNotificationAuthorizationState = .unknown

    private let desktopStream: AsyncStream<DesktopNotificationAuthorizationState>

    init(
        desktopStream: AsyncStream<DesktopNotificationAuthorizationState> = AsyncStream { $0.finish() }
    ) {
        self.desktopStream = desktopStream
    }

    func clearBrowserHistory() {}
    func openConfigInExternalEditor() {}
    func sendTestNotification() {}
    func openSystemNotificationSettings() {}
    func restartApp() {}
    func openBrowserImportFlow() {}
    func requestNotificationAuthorization() {}
    func openTerminalConfigWindow() {}
    func previewNotificationSound(value: String, customFilePath: String) {}

    func desktopNotificationAuthorizationStatus() -> DesktopNotificationAuthorizationState {
        desktopStatusReads += 1
        return desktopStatus
    }

    func desktopNotificationAuthorizationStatusUpdates() -> AsyncStream<DesktopNotificationAuthorizationState> {
        desktopStreamCreations += 1
        return desktopStream
    }

    func refreshDesktopNotificationAuthorizationStatus() {
        desktopRefreshes += 1
    }
}
