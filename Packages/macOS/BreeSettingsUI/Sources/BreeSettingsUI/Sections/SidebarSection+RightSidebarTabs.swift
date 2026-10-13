import BreeFoundation
import SwiftUI

extension SidebarSection {
    /// **Right Sidebar Tabs** card: one row per customizable tab with its
    /// resolved switch shortcut, reorder arrows, and a visibility toggle.
    /// State lives in the host (`rightSidebarTabs()` and the mutation
    /// methods); the card re-reads after every mutation and stays live via
    /// `rightSidebarTabsUpdates()` when the mode bar's context menu or a
    /// shortcut rebind changes the tabs from outside Settings.
    @ViewBuilder
    var rightSidebarTabsCard: some View {
        if !rightSidebarTabs.isEmpty {
            SettingsCard {
                SettingsCardRow(
                    configurationReview: .settingsOnly,
                    searchAnchorID: "setting:sidebarAppearance:right-sidebar-tabs",
                    String(localized: "settings.sidebar.rightTabs", defaultValue: "Right Sidebar Tabs"),
                    subtitle: String(localized: "settings.sidebar.rightTabs.subtitle", defaultValue: "Choose which tabs the right sidebar shows and their order. The ⌃1–⌃9 shortcuts follow the visible order.")
                ) {
                    EmptyView()
                }
                ForEach(rightSidebarTabs) { tab in
                    SettingsCardDivider()
                    rightSidebarTabRow(tab)
                }
            }
        }
    }

    @ViewBuilder
    private func rightSidebarTabRow(_ tab: RightSidebarTabSettingsItem) -> some View {
        let index = rightSidebarTabs.firstIndex(of: tab)
        let visibleCount = rightSidebarTabs.filter(\.isVisible).count
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tab.symbolName)
                .breeFont(.secondary)
                .foregroundStyle(.settingsSecondaryText)
                .frame(width: 18)
            Text(tab.title)
                .breeFont(.body, weight: .medium)
                .foregroundStyle(tab.isVisible ? AnyShapeStyle(SettingsPaletteStyle(role: .textPrimary)) : AnyShapeStyle(SettingsPaletteStyle(role: .textSecondary)))
            if !tab.shortcutLabel.isEmpty {
                Text(tab.shortcutLabel)
                    .breeFont(.count, countRow: .secondary)
                    .foregroundStyle(.settingsSecondaryText)
            }
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                Button {
                    hostActions.moveRightSidebarTab(id: tab.id, offset: -1)
                    rightSidebarTabs = hostActions.rightSidebarTabs()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(index == rightSidebarTabs.startIndex)
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        String(localized: "settings.sidebar.rightTabs.moveUp", defaultValue: "Move %@ Up"),
                        tab.title
                    )
                )
                .accessibilityIdentifier("SettingsRightSidebarTabMoveUp.\(tab.id)")
                Button {
                    hostActions.moveRightSidebarTab(id: tab.id, offset: 1)
                    rightSidebarTabs = hostActions.rightSidebarTabs()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(index == rightSidebarTabs.index(before: rightSidebarTabs.endIndex))
                .accessibilityLabel(
                    String.localizedStringWithFormat(
                        String(localized: "settings.sidebar.rightTabs.moveDown", defaultValue: "Move %@ Down"),
                        tab.title
                    )
                )
                .accessibilityIdentifier("SettingsRightSidebarTabMoveDown.\(tab.id)")
            }
            Toggle("", isOn: Binding(
                get: { tab.isVisible },
                set: { visible in
                    hostActions.setRightSidebarTabVisible(id: tab.id, visible: visible)
                    rightSidebarTabs = hostActions.rightSidebarTabs()
                }
            ))
            .labelsHidden()
            .controlSize(.small)
            .disabled(tab.isVisible && visibleCount == 1)
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    String(localized: "settings.sidebar.rightTabs.toggleVisible", defaultValue: "Show %@"),
                    tab.title
                )
            )
            .accessibilityIdentifier("SettingsRightSidebarTabVisibleToggle.\(tab.id)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("SettingsRightSidebarTabRow.\(tab.id)")
    }
}
