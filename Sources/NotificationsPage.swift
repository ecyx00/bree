import BreeFoundation
import Bonsplit
import SwiftUI

struct NotificationsPage: View {
    let isFocused: Bool
    let isVisibleInUI: Bool

    @EnvironmentObject var notificationStore: TerminalNotificationStore
    @EnvironmentObject var tabManager: TabManager
    @FocusState private var focusedNotificationId: UUID?
    @State private var keyboardShortcutSettingsObserver = KeyboardShortcutSettingsObserver.shared
    @State private var ghosttyBackgroundColor = Color(nsColor: GhosttyBackgroundTheme.currentColor())

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if !notificationStore.notificationMenuSnapshot.hasNotifications {
                emptyState
            } else if notificationStore.notifications.isEmpty {
                workspaceUnreadIndicatorState
            } else {
                notificationsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ghosttyBackgroundColor)
        .onAppear {
            refreshGhosttyBackground()
            setInitialFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidReload)) { _ in
            refreshGhosttyBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { _ in
            refreshGhosttyBackground()
        }
        .onChange(of: notificationStore.notifications.first?.id) {
            setInitialFocus()
        }
        .onChange(of: isFocused) {
            setInitialFocus()
        }
        .onChange(of: isVisibleInUI) {
            setInitialFocus()
        }
    }

    private func refreshGhosttyBackground() {
        ghosttyBackgroundColor = Color(nsColor: GhosttyBackgroundTheme.currentColor())
    }

    private var notificationsList: some View {
        // Build one tabId -> title index per render instead of an O(tabs) lookup
        // for every notification row. Constructing the ForEach then costs
        // O(rows + tabs) rather than O(rows × tabs), which matters when many
        // notifications accumulate (issue #5794).
        let tabTitles = AppDelegate.shared?.tabTitlesByTabId() ?? [:]
        return ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(notificationStore.notifications) { notification in
                    NotificationRow(
                        notification: notification,
                        tabTitle: tabTitle(for: notification.tabId, in: tabTitles),
                        isFocused: focusedNotificationId == notification.id,
                        onOpen: {
                            // SwiftUI action closures aren't guaranteed to be main-actor
                            // isolated; hop to the main actor for window focus + tab selection.
                            Task { @MainActor in
                                _ = AppDelegate.shared?.openTerminalNotification(notification)
                            }
                        },
                        onClear: {
                            notificationStore.remove(id: notification.id)
                        },
                        focusedNotificationId: $focusedNotificationId
                    )
                    // Each NotificationRow renders heavily-modified nested stacks.
                    // Equatable + .equatable() lets a NotificationStore publish that
                    // touches one notification skip body re-evaluation for the other
                    // rows, instead of re-laying out the whole LazyVStack on every
                    // publish (issue #5794, same class as #2586 / #5752).
                    .equatable()
                }
            }
            .padding(16)
        }
    }

    private func setInitialFocus() {
        // Background-mounted pane tabs must not claim focus when their feed changes.
        guard isFocused,
              isVisibleInUI,
              let firstId = notificationStore.notifications.first?.id else {
            focusedNotificationId = nil
            return
        }
        focusedNotificationId = firstId
    }

    private var header: some View {
        HStack {
            Text(String(localized: "notifications.title", defaultValue: "Notifications"))
                .scaledFont(.title2)
                .fontWeight(.semibold)

            Spacer()

            if notificationStore.notificationMenuSnapshot.hasNotifications {
                jumpToUnreadButton

                Button(String(localized: "notifications.clearAll", defaultValue: "Clear All")) {
                    notificationStore.clearAll()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            BreeSystemSymbolImage(magnified: "bell.slash", pointSize: 32, tint: .secondary)
            Text(String(localized: "notifications.empty.title", defaultValue: "No notifications yet"))
                .scaledFont(.headline)
            Text(String(localized: "notifications.empty.description", defaultValue: "Desktop notifications will appear here for quick review."))
                .scaledFont(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceUnreadIndicatorState: some View {
        VStack(spacing: 8) {
            BreeSystemSymbolImage(magnified: "bell.badge", pointSize: 32, tint: .secondary)
            Text(notificationStore.notificationMenuSnapshot.stateHintTitle)
                .scaledFont(.headline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var jumpToUnreadButton: some View {
        if let key = jumpToUnreadShortcut.keyEquivalent {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .keyboardShortcut(key, modifiers: jumpToUnreadShortcut.eventModifiers)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        } else {
            Button(action: {
                AppDelegate.shared?.jumpToLatestUnread()
            }) {
                HStack(spacing: 6) {
                    Text(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread"))
                    ShortcutAnnotation(text: jumpToUnreadShortcut.displayString)
                }
            }
            .buttonStyle(.bordered)
            .safeHelp(KeyboardShortcutSettings.Action.jumpToUnread.tooltip(String(localized: "notifications.jumpToLatestUnread", defaultValue: "Jump to Latest Unread")))
            .disabled(!hasUnreadNotifications)
        }
    }

    private var jumpToUnreadShortcut: StoredShortcut {
        let _ = keyboardShortcutSettingsObserver.revision
        return KeyboardShortcutSettings.shortcut(for: .jumpToUnread)
    }

    private func tabTitle(for tabId: UUID, in tabTitles: [UUID: String]) -> String? {
        tabTitles[tabId] ?? tabManager.tabs.first(where: { $0.id == tabId })?.title
    }

    private var hasUnreadNotifications: Bool {
        notificationStore.notificationMenuSnapshot.hasUnreadNotifications
    }
}

struct ShortcutAnnotation: View {
    let text: String
    var accessibilityIdentifier: String? = nil

    @ViewBuilder
    var body: some View {
        if let accessibilityIdentifier {
            badge.accessibilityIdentifier(accessibilityIdentifier)
        } else {
            badge
        }
    }

    private var badge: some View {
        Text(text)
            .scaledFont(size: 10, weight: .semibold, design: .rounded)
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
    }
}

struct NotificationRow: View, Equatable {
    @Environment(\.breeAccentColor) private var breeAccent
    // Closures and the focus binding are recreated by the parent on every render
    // and excluded from ==. Equality compares only the value snapshot the row
    // actually renders, so `.equatable()` can suppress body re-evaluation for
    // rows whose snapshot is unchanged (snapshot-boundary rule, CLAUDE.md /
    // issue #2586). `isFocused` is passed in (rather than read from the binding
    // inside the row) precisely so it participates in equality — otherwise a
    // focus change would leave the default-action shortcut on a stale row.
    nonisolated static func == (lhs: NotificationRow, rhs: NotificationRow) -> Bool {
        lhs.notification == rhs.notification &&
            lhs.tabTitle == rhs.tabTitle &&
            lhs.isFocused == rhs.isFocused
    }

    /// "47s ago", "5m ago", "3h ago", "2d ago".
    static func agoLabel(since: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        if seconds < 60 {
            return String(localized: "notifications.time.seconds", defaultValue: "\(seconds)s ago")
        }
        if seconds < 3600 {
            return String(localized: "notifications.time.minutes", defaultValue: "\(seconds / 60)m ago")
        }
        if seconds < 86400 {
            return String(localized: "notifications.time.hours", defaultValue: "\(seconds / 3600)h ago")
        }
        return String(localized: "notifications.time.days", defaultValue: "\(seconds / 86400)d ago")
    }

    let notification: TerminalNotification
    let tabTitle: String?
    let isFocused: Bool
    let onOpen: () -> Void
    let onClear: () -> Void
    let focusedNotificationId: FocusState<UUID?>.Binding

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onOpen) {
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(notification.isRead ? Color.clear : breeAccent.color)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(breeAccent.color.opacity(notification.isRead ? 0.2 : 1), lineWidth: 1)
                        )
                        .padding(.top, 6)

                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(notification.title)
                                .scaledFont(.headline)
                                .foregroundColor(.primary)
                            Spacer()
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(Self.agoLabel(since: notification.createdAt, now: context.date))
                                    .scaledFont(.caption)
                                    .foregroundColor(.secondary)
                                    .monospacedDigit()
                            }
                        }

                        if !notification.body.isEmpty {
                            Text(notification.body)
                                .scaledFont(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(3)
                        }

                        if let tabTitle {
                            Text(tabTitle)
                                .scaledFont(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    Spacer(minLength: 0)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("NotificationRow.\(notification.id.uuidString)")
            .focusable()
            .focused(focusedNotificationId, equals: notification.id)
            .modifier(DefaultActionModifier(isActive: isFocused))

            Button(action: onClear) {
                BreeSystemSymbolImage(systemName: "xmark.circle.fill", pointSize: 14, tint: .secondary)
            }
            .buttonStyle(.plain)
            // BreeSystemSymbolImage renders an AppKit NSImage with no accessibility
            // description, so the icon-only button needs an explicit label (the prior
            // SwiftUI system-symbol path used to supply one implicitly).
            .accessibilityLabel(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
            .safeHelp(String(localized: "notifications.row.clear", defaultValue: "Clear notification"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .contextMenu {
            Button(String(localized: "notifications.open", defaultValue: "Open")) {
                onOpen()
            }
            Button(String(localized: "notifications.copy", defaultValue: "Copy")) {
                TerminalNotificationClipboard.copy(notification, workspaceTitle: tabTitle)
            }
            Divider()
            Button(String(localized: "notifications.dismiss", defaultValue: "Dismiss"), role: .destructive) {
                onClear()
            }
        }
    }
}

private struct DefaultActionModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}
