import AppKit
import CmuxFoundation
import SwiftUI

/// The Attention / Notifications button, in the right-hand control cluster of
/// the tab bar. It anchors the popover so it opens over the terminal area and
/// never over the left sidebar. The unread (or waiting-agent) badge is kept.
struct TitlebarNotificationsBell: View {
    @Environment(\.breePalette) private var palette
    @ObservedObject private var notifications = TerminalNotificationStore.shared
    @ObservedObject private var attention = AttentionStore.shared

    var body: some View {
        let counts = TitlebarControlsVisibility.bellCounts(unread: notifications.unreadCount)
        let title = String(localized: "titlebar.notifications.tooltip", defaultValue: "Show notifications")
        let shortcut = KeyboardShortcutSettings.Action.showNotifications
        Button {
            AppDelegate.shared?.toggleNotificationsPopover(animated: true)
        } label: {
            // 28x28 hit area; the glyph keeps its size and the badge stays inside the frame.
            ZStack(alignment: .topTrailing) {
                Label(String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"),
                      systemImage: counts.needsAttention ? "bell.badge" : "bell")
                    .labelStyle(.iconOnly)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(counts.needsAttention ? palette.signalAttention : palette.textSecondary)
                    .frame(width: 28, height: 28)
                if counts.count > 0 {
                    Text("\(min(counts.count, 99))")
                        .breeFont(.count, weight: .medium, countRow: .caption)
                        .foregroundColor(palette.surfaceBase)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(counts.needsAttention ? palette.signalAttention : palette.accentFill))
                        .offset(x: -1, y: 2)
                }
            }
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(NotificationsAnchorView { _ in })
        .safeHelp(shortcut.tooltip(title))
        .accessibilityLabel(String(localized: "titlebar.notifications.accessibilityLabel", defaultValue: "Notifications"))
        .accessibilityIdentifier("Titlebar.showNotifications")
        .titlebarInteractiveControl()
        // `attention.revision` re-evaluates the waiting-agent count.
        .id(attention.revision)
    }
}
