import AppKit
import BreeAppKitSupportUI
import BreeFoundation
import BreeSidebar
import SwiftUI
import BreeSettings

/// Collapsible group header that doubles as the anchor workspace row.
struct SidebarWorkspaceGroupHeaderView: View, Equatable {
    // Closures and delegate factories are excluded because they are recreated
    // by the parent on each evaluation. The scalar snapshots below are the
    // header's render and behavior inputs under the LazyVStack.
    nonisolated static func == (lhs: SidebarWorkspaceGroupHeaderView, rhs: SidebarWorkspaceGroupHeaderView) -> Bool {
        lhs.groupId == rhs.groupId &&
            lhs.anchorWorkspaceId == rhs.anchorWorkspaceId &&
            lhs.name == rhs.name &&
            lhs.iconSymbol == rhs.iconSymbol &&
            lhs.tintHex == rhs.tintHex &&
            lhs.isCollapsed == rhs.isCollapsed &&
            lhs.isPinned == rhs.isPinned &&
            lhs.isAnchorActive == rhs.isAnchorActive &&
            lhs.isMultiSelected == rhs.isMultiSelected &&
            lhs.multiSelectionBackgroundStyle == rhs.multiSelectionBackgroundStyle &&
            lhs.anchorActiveEdgeColor == rhs.anchorActiveEdgeColor &&
            lhs.memberCount == rhs.memberCount &&
            lhs.anchorUnreadCount == rhs.anchorUnreadCount &&
            lhs.canMarkRead == rhs.canMarkRead &&
            lhs.canMarkUnread == rhs.canMarkUnread &&
            lhs.hasLatestNotifications == rhs.hasLatestNotifications &&
            lhs.canMarkAllRead == rhs.canMarkAllRead &&
            lhs.canMarkAllUnread == rhs.canMarkAllUnread &&
            lhs.statusGlyph == rhs.statusGlyph &&
            lhs.compactsAgentStatus == rhs.compactsAgentStatus &&
            lhs.shortcutDigit == rhs.shortcutDigit &&
            lhs.shortcutModifierSymbol == rhs.shortcutModifierSymbol &&
            lhs.showsShortcutHint == rhs.showsShortcutHint &&
            lhs.isPointerHovering == rhs.isPointerHovering &&
            lhs.shortcutHintXOffset == rhs.shortcutHintXOffset &&
            lhs.shortcutHintYOffset == rhs.shortcutHintYOffset &&
            lhs.fontScale == rhs.fontScale &&
            lhs.cwdContextMenuItems == rhs.cwdContextMenuItems &&
            lhs.newWorkspacePlacement == rhs.newWorkspacePlacement &&
            lhs.rowSpacing == rhs.rowSpacing &&
            lhs.isFirstRow == rhs.isFirstRow &&
            lhs.isBeingDragged == rhs.isBeingDragged &&
            lhs.topDropIndicatorVisible == rhs.topDropIndicatorVisible &&
            lhs.bottomDropIndicatorVisible == rhs.bottomDropIndicatorVisible &&
            lhs.notificationBadgeColorHex == rhs.notificationBadgeColorHex
    }

    let groupId: UUID
    let anchorWorkspaceId: UUID
    let name: String
    let iconSymbol: String
    let tintHex: String?
    let isCollapsed: Bool
    let isPinned: Bool
    let isAnchorActive: Bool
    let isMultiSelected: Bool
    let multiSelectionBackgroundStyle: SidebarWorkspaceRowBackgroundStyle
    /// Hairline painted while this header is anchor-active; nil when subtle
    /// selection is off.
    var anchorActiveEdgeColor: NSColor? = nil
    let memberCount: Int
    let anchorUnreadCount: Int
    let canMarkRead: Bool
    let canMarkUnread: Bool
    let hasLatestNotifications: Bool
    let canMarkAllRead: Bool
    let canMarkAllUnread: Bool
    let statusGlyph: SidebarCompactStatusGlyph?
    /// Whether `sidebar.compactAgentStatus` is on; see the AppKit row model.
    var compactsAgentStatus = false
    let shortcutDigit: Int?
    let shortcutModifierSymbol: String?
    let showsShortcutHint: Bool
    let isPointerHovering: Bool
    let shortcutHintXOffset: Double
    let shortcutHintYOffset: Double
    let fontScale: CGFloat
    let cwdContextMenuItems: [BreeResolvedConfigContextMenuItem]
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
    let rowSpacing: CGFloat
    let isFirstRow: Bool
    let isBeingDragged: Bool
    let topDropIndicatorVisible: Bool
    let bottomDropIndicatorVisible: Bool
    /// Notification Badge color setting; nil falls back to the bree accent.
    let notificationBadgeColorHex: String?
    /// Shared group-header actions used by both the lazy SwiftUI row and the
    /// retained AppKit table cell.
    let actions: SidebarGroupHeaderRowActions
    let onContextMenuAppear: () -> Void
    let onContextMenuDisappear: () -> Void

    @State private var contextMenuVisible = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.breeAccentColor) private var accentColor
    @Environment(\.breePalette) private var palette

    @Environment(\.breeGlobalFontMagnificationPercent) private var globalFontMagnificationPercent

#if DEBUG
    // Plain-value environment probe set only by SidebarLazyLayoutScaleTests;
    // default no-op. See SidebarLazyContractProbe.
    @Environment(\.sidebarLazyContractProbe) private var sidebarLazyContractProbe
#endif

    private var metrics: SidebarWorkspaceGroupHeaderMetrics {
        SidebarWorkspaceGroupHeaderMetrics(fontScale: fontScale)
    }

    /// Un-magnified glyph size of a type role on the sidebar base size; the
    /// symbol views apply the global magnification themselves.
    private func glyphSize(_ role: BreeTextRole) -> CGFloat {
        SidebarRowType.spec(
            role,
            base: SidebarTabItemFontScale.baseSize(forScale: fontScale),
            magnificationPercent: GlobalFontMagnification.defaultPercent
        ).size
    }

    private var iconColor: Color {
        if let tintHex, let nsColor = NSColor(hex: tintHex) {
            return Color(nsColor: nsColor)
        }
        return palette.textSecondary
    }

    private var displayedIconSymbol: String {
        RenderableSystemSymbol.resolvedWorkspaceGroupIcon(explicit: iconSymbol, configured: nil)
    }

    private var shortcutHintPillText: String? {
        guard showsShortcutHint,
              let shortcutDigit,
              let shortcutModifierSymbol else { return nil }
        return "\(shortcutModifierSymbol)\(shortcutDigit)"
    }

    private var pinnedGroupTooltip: String {
        String(localized: "workspaceGroup.pinned.tooltip", defaultValue: "Pinned group")
    }

    private var multiSelectionBackgroundColor: Color {
        guard let color = multiSelectionBackgroundStyle.color else {
            return .clear
        }
        if multiSelectionBackgroundStyle.edgeColor == nil { return palette.selectedQuiet }
        return Color(nsColor: color).opacity(multiSelectionBackgroundStyle.opacity)
    }

    /// Subtle-selection hairline, matching selected workspace rows.
    private var selectionEdgeColor: NSColor? {
        if isAnchorActive { return anchorActiveEdgeColor }
        if isMultiSelected { return multiSelectionBackgroundStyle.edgeColor }
        return nil
    }

    private var selectionCornerRadius: CGFloat {
        isMultiSelected && !isAnchorActive ? 6 : 4
    }

    var body: some View {
#if DEBUG
        let _ = { sidebarLazyContractProbe.groupHeaderRowBody?() }()
#endif
        HStack(spacing: 4) {
            if isPinned {
                BreeSystemSymbolImage(
                    magnified: "pin.fill",
                    pointSize: glyphSize(.caption),
                    weight: .regular,
                    tint: palette.textSecondary
                )
                .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                .safeHelp(pinnedGroupTooltip)
                .accessibilityLabel(Text(pinnedGroupTooltip))
            }
            BreeSystemSymbolImage(
                systemName: isCollapsed ? "chevron.right" : "chevron.down",
                pointSize: glyphSize(.caption),
                weight: .regular,
                tint: palette.textSecondary,
                appliesGlobalFontMagnification: true)
                .frame(width: metrics.chevronFrame, height: metrics.chevronFrame)
                .contentShape(Rectangle())
                .onTapGesture { actions.onToggleCollapsed() }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(
                    Text(
                        isCollapsed
                            ? String(localized: "workspaceGroup.expand.a11y", defaultValue: "Expand group")
                            : String(localized: "workspaceGroup.collapse.a11y", defaultValue: "Collapse group")
                    )
                )

            HStack(spacing: 6) {
                BreeSystemSymbolImage(
                    systemName: displayedIconSymbol,
                    pointSize: glyphSize(.body),
                    weight: .regular,
                    tint: iconColor,
                    appliesGlobalFontMagnification: true)
                    .frame(width: metrics.iconFrame, height: metrics.iconFrame)
                    .accessibilityHidden(true)
                Text(name)
                    .sidebarFont(.title, fontScale: fontScale)
                    .foregroundStyle(palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // Compact status mode: unread folds into the glyph (blue).
                if let statusGlyph {
                    SidebarCompactStatusGlyphView(
                        glyph: statusGlyph,
                        pointSize: GlobalFontMagnification.scaledSize(glyphSize(.body), percent: globalFontMagnificationPercent),
                        color: statusGlyph.color(isActive: false, selected: NSColor(palette.textPrimary), secondary: NSColor(palette.textSecondary))
                    )
                } else if anchorUnreadCount > 0, !compactsAgentStatus {
                    Text("\(anchorUnreadCount)")
                        .sidebarFont(.count, weight: .medium, countRow: .caption, fontScale: fontScale)
                        // Surface colour on the attention fill: 4.5:1 for every theme.
                        .foregroundStyle(notificationBadgeColorHex == nil ? palette.surfaceBase : Color.white)
                        .padding(.horizontal, metrics.unreadHorizontalPadding)
                        .padding(.vertical, metrics.unreadVerticalPadding)
                        .background(Capsule().fill(Color(nsColor: breeNotificationBadgeNSColor(
                            hex: notificationBadgeColorHex,
                            fallback: NSColor(palette.accentFill)
                        ))))
                        .accessibilityLabel(Text(String.localizedStringWithFormat(
                            String(localized: "workspaceGroup.unread.a11y", defaultValue: "%lld unread"),
                            anchorUnreadCount
                        )))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                actions.onFocusAnchor(NSApp.currentEvent?.modifierFlags ?? [])
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(name))
            .accessibilityHint(Text(String(
                localized: "workspaceGroup.focusAnchor.a11y",
                defaultValue: "Focus the group's anchor workspace"
            )))

            let plusVisible = isPointerHovering && !contextMenuVisible && !showsShortcutHint
            Button(action: actions.onTapPlus) {
                BreeSystemSymbolImage(
                    systemName: "plus",
                    pointSize: glyphSize(.body),
                    weight: .regular,
                    tint: palette.textSecondary,
                    appliesGlobalFontMagnification: true)
                    .frame(width: metrics.plusFrame, height: metrics.plusFrame)
                    .contentShape(Rectangle())
                    .opacity(plusVisible ? 1 : 0)
            }
            .buttonStyle(.plain)
            .frame(width: metrics.plusFrame, height: metrics.plusFrame)
            .allowsHitTesting(plusVisible)
            .accessibilityHidden(!plusVisible)
            .accessibilityLabel(Text(String(
                localized: "workspaceGroup.newWorkspaceInGroup.a11y",
                defaultValue: "New workspace in group"
            )))
            .contextMenu {
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                        defaultValue: "New Workspace in Group"
                    ),
                    action: actions.onTapPlus
                )
                .onAppear {
                    contextMenuVisible = true
                    onContextMenuAppear()
                }
                .onDisappear {
                    contextMenuVisible = false
                    onContextMenuDisappear()
                }
                if !cwdContextMenuItems.isEmpty {
                    Divider()
                    ForEach(cwdContextMenuItems) { item in
                        switch item {
                        case .separator:
                            Divider()
                        case .action(let action):
                            Button(action.title) {
                                actions.onRunResolvedItem(action)
                            }
                        }
                    }
                }
                Divider()
                Button(
                    String(
                        localized: "workspaceGroup.plus.contextMenu.editConfig",
                        defaultValue: "Edit Group Config..."
                    ),
                    action: actions.onEditConfig
                )
            }
        }
        .padding(.vertical, 5)
        .padding(.trailing, SidebarWorkspaceListMetrics.rowContentHorizontalPadding)
        .contentShape(Rectangle())
        .background(
            isAnchorActive
                ? palette.selectedQuiet
                : isMultiSelected
                    ? multiSelectionBackgroundColor
                    : Color.clear
        )
        .clipShape(RoundedRectangle(
            cornerRadius: selectionCornerRadius,
            style: .continuous
        ))
        .overlay {
            if let selectionEdgeColor {
                RoundedRectangle(cornerRadius: selectionCornerRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: selectionEdgeColor), lineWidth: 1)
            }
        }
        .sidebarShortcutHintOverlay(
            text: shortcutHintPillText,
            emphasis: isAnchorActive ? 1.0 : 0.9,
            offsetX: shortcutHintXOffset,
            offsetY: shortcutHintYOffset
        )
        .padding(.horizontal, SidebarWorkspaceListMetrics.rowOuterHorizontalPadding)
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
        .opacity(isBeingDragged ? 0.6 : 1)
        .overlay(alignment: .top) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: topDropIndicatorVisible,
                isFirstRow: isFirstRow,
                rowSpacing: rowSpacing
            )
        }
        .overlay(alignment: .bottom) {
            SidebarWorkspaceTopDropIndicator(
                isVisible: bottomDropIndicatorVisible,
                isFirstRow: false,
                rowSpacing: rowSpacing,
                isBottomEdge: true,
                leadingInset: metrics.groupScopedBottomDropIndicatorLeadingInset
            )
        }
        .contextMenu {
            Button(
                String(
                    localized: "workspaceGroup.plus.contextMenu.newWorkspace",
                    defaultValue: "New Workspace in Group"
                ),
                action: actions.onTapPlus
            )
            .onAppear {
                contextMenuVisible = true
                onContextMenuAppear()
            }
            .onDisappear {
                contextMenuVisible = false
                onContextMenuDisappear()
            }
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.rename",
                    defaultValue: "Rename Group..."
                ),
                action: actions.onRename
            )
            Button(
                isPinned
                    ? String(
                        localized: "workspaceGroup.contextMenu.unpin",
                        defaultValue: "Unpin Group"
                    )
                    : String(
                        localized: "workspaceGroup.contextMenu.pin",
                        defaultValue: "Pin Group"
                    ),
                action: actions.onTogglePinned
            )
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markRead",
                    defaultValue: "Mark Group as Read"
                ),
                action: actions.onMarkRead
            )
            .disabled(!canMarkRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markUnread",
                    defaultValue: "Mark Group as Unread"
                ),
                action: actions.onMarkUnread
            )
            .disabled(!canMarkUnread)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.clearLatestNotifications",
                    defaultValue: "Clear Latest Notifications"
                ),
                action: actions.onClearLatestNotifications
            )
            .disabled(!hasLatestNotifications)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllRead",
                    defaultValue: "Mark All Workspaces in Group as Read"
                ),
                action: actions.onMarkAllRead
            )
            .disabled(!canMarkAllRead)
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.markAllUnread",
                    defaultValue: "Mark All Workspaces in Group as Unread"
                ),
                action: actions.onMarkAllUnread
            )
            .disabled(!canMarkAllUnread)
            Divider()
            Button(
                String(
                    localized: "workspaceGroup.contextMenu.editConfig",
                    defaultValue: "Edit Group Config..."
                ),
                action: actions.onEditConfig
            )
            Divider()
            if !isPinned || memberCount > 0 {
                Button(
                    String(
                        localized: "workspaceGroup.contextMenu.ungroup",
                        defaultValue: "Ungroup Workspaces"
                    ),
                    action: actions.onUngroup
                )
            }
            Button(
                role: .destructive,
                action: actions.onDelete
            ) {
                Text(
                    String(
                        localized: "workspaceGroup.contextMenu.delete",
                        defaultValue: "Delete Group"
                    )
                )
            }
        }
    }
}
