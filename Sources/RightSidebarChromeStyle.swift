import AppKit
import BreeFoundation
import BreeAppKitSupportUI
import BreeSettings
import SwiftUI

func titlebarShortcutHintShouldShow(
    shortcut: StoredShortcut,
    alwaysShowShortcutHints: Bool,
    modifierPressed: Bool
) -> Bool {
    !shortcut.isUnbound && (alwaysShowShortcutHints || (shortcut.command && modifierPressed))
}

/// Resolves to the Bree palette's `textSecondary` (4.5:1 floor on every
/// surface, 7:1 under Increase Contrast) from the view's environment.
struct BreeSecondaryTextStyle: ShapeStyle {
    func resolve(in environment: EnvironmentValues) -> some ShapeStyle {
        environment.breePalette.textSecondary
    }
}

extension ShapeStyle where Self == BreeSecondaryTextStyle {
    /// Secondary text and empty states. Every caller keeps this name and gets
    /// the palette's `textSecondary` role.
    static var breeSecondaryText: BreeSecondaryTextStyle { BreeSecondaryTextStyle() }
}

enum HeaderChromeIconStyle {
    static let opacity = 0.86
    static let hoveredOpacity = 0.96
    static let pressedOpacity = 1.0
    static let disabledOpacity = 0.34
    static let weight: Font.Weight = .regular
    static let sidebarGlyphStrokeWidth: CGFloat = 1

    static func iconFrameSize(forIconSize iconSize: CGFloat) -> CGFloat {
        HeaderChromeControlMetrics.iconFrameSize(forIconSize: iconSize)
    }

    static func symbol(_ systemName: String) -> some View {
        HeaderChromeSymbol(systemName: systemName)
    }

    static func foregroundOpacity(isHovering: Bool, isPressed: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return disabledOpacity }
        if isPressed {
            return pressedOpacity
        }
        if isHovering {
            return hoveredOpacity
        }
        return opacity
    }

    static func backgroundOpacity(
        hoverBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return 0 }
        if isPressed {
            return 0.14
        }
        if isHovering {
            return hoverBackground ? 0.09 : 0.07
        }
        return 0
    }

    static func borderOpacity(
        buttonBackground: Bool,
        isHovering: Bool,
        isPressed: Bool,
        isEnabled: Bool = true
    ) -> Double {
        guard isEnabled else { return buttonBackground ? 0.04 : 0 }
        if isPressed {
            return 0.11
        }
        if isHovering {
            return 0.07
        }
        return buttonBackground ? 0.05 : 0
    }
}

private struct HeaderChromeSymbol: View {
    let systemName: String
    @Environment(\.breePalette) private var palette

    var body: some View {
        BreeSystemSymbolImage(
            systemName: systemName,
            pointSize: RightSidebarChromeMetrics.headerIconSize,
            weight: HeaderChromeIconStyle.weight,
            tint: palette.textSecondary
        )
    }
}

enum RightSidebarChromeControlStyle {
    static let modeIconSize: CGFloat = 11
    static let secondaryIconSize: CGFloat = 10
    static let iconWeight = HeaderChromeIconStyle.weight
    static let labelWeight = HeaderChromeIconStyle.weight

    /// Pill tint for a mode/grouping control, shared by the pill modifier's
    /// text foreground and the hosted symbol's baked-in tint. Selected and
    /// hovered use `textPrimary`; the rest `textSecondary`.
    static func pillForegroundColor(isSelected: Bool, isHovered: Bool, palette: BreeChromePalette) -> Color {
        isSelected || isHovered ? palette.textPrimary : palette.textSecondary
    }

    static func foregroundOpacity(isSelected: Bool, isHovered: Bool, isEnabled: Bool = true) -> Double {
        guard isEnabled else { return HeaderChromeIconStyle.disabledOpacity }
        if isSelected {
            return HeaderChromeIconStyle.pressedOpacity
        }
        return HeaderChromeIconStyle.foregroundOpacity(
            isHovering: isHovered,
            isPressed: false,
            isEnabled: isEnabled
        )
    }
}

struct RightSidebarChromeBarModifier: ViewModifier {
    var leadingPadding: CGFloat
    var trailingPadding: CGFloat
    var height: CGFloat
    @Environment(\.breeGlobalFontMagnificationPercent) private var globalFontPercent

    func body(content: Content) -> some View {
        content
            .padding(.leading, leadingPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, RightSidebarChromeMetrics.barVerticalPadding)
            .frame(height: resolvedHeight)
    }

    private var resolvedHeight: CGFloat {
        _ = globalFontPercent
        return max(height, RightSidebarChromeMetrics.secondaryBarHeight)
    }
}

struct RightSidebarChromePillModifier: ViewModifier {
    var isSelected: Bool
    var isHovered: Bool
    var horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding
    var geometryKeyPrefix: String?
    @Environment(\.breeGlobalFontMagnificationPercent) private var globalFontPercent
    @Environment(\.breePalette) private var palette

    func body(content: Content) -> some View {
        content
            .foregroundStyle(
                RightSidebarChromeControlStyle.pillForegroundColor(isSelected: isSelected, isHovered: isHovered, palette: palette)
            )
            .padding(.horizontal, horizontalPadding)
            .frame(height: controlHeight)
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: geometryKeyPrefix,
                isVisible: true
            )
            .background(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(alignment: .bottom) {
                // Selected indicator, distinct from the hover fill: a 2 pt
                // `activeIndicator` bar (3:1 floor on every surface).
                if isSelected {
                    Capsule()
                        .fill(palette.activeIndicator)
                        .frame(height: 2)
                        .padding(.horizontal, horizontalPadding)
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
            )
    }

    private var controlHeight: CGFloat {
        _ = globalFontPercent
        return RightSidebarChromeMetrics.controlHeight
    }

    private var foregroundOpacity: Double {
        RightSidebarChromeControlStyle.foregroundOpacity(
            isSelected: isSelected,
            isHovered: isHovered
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return palette.selectedFill
        }
        if isHovered {
            return palette.hoverFill
        }
        return Color.clear
    }
}

struct RightSidebarChromeBottomBorderModifier: ViewModifier {
    /// Kept for call sites; the border is the palette `separator` now.
    let backgroundColor: NSColor
    @Environment(\.breePalette) private var palette

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Rectangle().fill(palette.separator).frame(height: 1)
        }
    }
}

struct RightSidebarHeaderIconButtonStyle: ButtonStyle {
    var iconGeometryKeyPrefix: String? = nil

    func makeBody(configuration: Configuration) -> some View {
        RightSidebarHeaderIconButtonStyleBody(
            configuration: configuration,
            iconGeometryKeyPrefix: iconGeometryKeyPrefix
        )
    }
}

private struct RightSidebarHeaderIconButtonStyleBody: View {
    let configuration: ButtonStyle.Configuration
    let iconGeometryKeyPrefix: String?
    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.breePalette) private var palette

    var body: some View {
        configuration.label
            .symbolRenderingMode(.monochrome)
            .frame(
                width: RightSidebarChromeMetrics.headerIconFrameSize,
                height: RightSidebarChromeMetrics.headerIconFrameSize
            )
            .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                keyPrefix: iconGeometryKeyPrefix,
                isVisible: true
            )
            .frame(
                width: RightSidebarChromeMetrics.headerControlSize,
                height: RightSidebarChromeMetrics.headerControlSize
            )
            // The hosted symbol is a template image tinted by the palette role; hover/pressed dimming applies as view opacity.
            .foregroundStyle(palette.textSecondary)
            .opacity(isEnabled ? 1 : 0.4)
            .background {
                if let fill = backgroundFill {
                    RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                        .fill(fill)
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
            )
            .onHover { isHovering = $0 }
    }

    private var backgroundFill: Color? {
        guard isEnabled else { return nil }
        if configuration.isPressed { return palette.pressedFill }
        if isHovering { return palette.hoverFill }
        return nil
    }
}

extension View {
    func rightSidebarChromeBar(
        leadingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        trailingPadding: CGFloat = RightSidebarChromeMetrics.barHorizontalPadding,
        height: CGFloat = RightSidebarChromeMetrics.secondaryBarHeight
    ) -> some View {
        modifier(
            RightSidebarChromeBarModifier(
                leadingPadding: leadingPadding,
                trailingPadding: trailingPadding,
                height: height
            )
        )
    }

    func rightSidebarChromePill(
        isSelected: Bool,
        isHovered: Bool,
        horizontalPadding: CGFloat = RightSidebarChromeMetrics.controlHorizontalPadding,
        geometryKeyPrefix: String? = nil
    ) -> some View {
        modifier(
            RightSidebarChromePillModifier(
                isSelected: isSelected,
                isHovered: isHovered,
                horizontalPadding: horizontalPadding,
                geometryKeyPrefix: geometryKeyPrefix
            )
        )
    }

    func rightSidebarChromeBottomBorder(backgroundColor: NSColor) -> some View {
        modifier(RightSidebarChromeBottomBorderModifier(backgroundColor: backgroundColor))
    }

    /// Gives system bordered buttons below this view the shared
    /// right-sidebar button radius instead of the platform default shape.
    func rightSidebarButtonBorderShape() -> some View {
        buttonBorderShape(.roundedRectangle(radius: BreeMetrics.radiusControl))
    }

    func rightSidebarHeaderControlAlignment() -> some View {
        alignmentGuide(VerticalAlignment.center) { dimensions in
            dimensions[VerticalAlignment.center] + RightSidebarChromeMetrics.headerControlCenterAlignmentAdjustment
        }
    }
}

struct RightSidebarModeBarItem: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case mode(RightSidebarMode)
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .mode(let mode):
            return mode.rawValue
        }
    }

    var label: String {
        switch kind {
        case .mode(let mode):
            return mode.label
        }
    }

    var symbolName: String {
        switch kind {
        case .mode(let mode):
            return mode.symbolName
        }
    }

    var shortcutAction: KeyboardShortcutSettings.Action? {
        switch kind {
        case .mode(let mode):
            return mode.shortcutAction
        }
    }

    var mode: RightSidebarMode {
        switch kind {
        case .mode(let mode):
            return mode
        }
    }

    func isSelected(mode: RightSidebarMode) -> Bool {
        switch kind {
        case .mode(let itemMode):
            return mode == itemMode
        }
    }
}

struct ModeBarButton: View {
    let item: RightSidebarModeBarItem
    let isSelected: Bool
    var badgeCount: Int = 0
    let shortcutHint: StoredShortcut
    let showsShortcutHint: Bool
    let action: () -> Void

    @State private var isHovered: Bool = false
    @Environment(\.breePalette) private var palette

    var body: some View {
        Button(action: action) {
            // Widest variant first: at its floor width the tab measures and
            // draws the icon-only pill, never a truncated label.
            ViewThatFits(in: .horizontal) {
                tabContent(showsLabel: true)
                tabContent(showsLabel: false)
            }
            .rightSidebarChromePill(
                isSelected: isSelected,
                isHovered: isHovered,
                geometryKeyPrefix: "rightSidebarModeControl_\(item.id)"
            )
            .overlay(alignment: .trailing) {
                if showsShortcutHint {
                    ShortcutHintPill(shortcut: shortcutHint, fontSize: 10, emphasis: isSelected ? 1.15 : 0.95)
                        .offset(x: 5)
                        .shortcutHintTransition()
                        .accessibilityIdentifier("rightSidebarModeShortcutHint.\(item.id)")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .titlebarInteractiveControl()
        .onHover { isHovered = $0 }
        .help(helpText)
        .accessibilityLabel(item.label)
        .accessibilityIdentifier("RightSidebarModeButton.\(item.id)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .shortcutHintVisibilityAnimation(value: showsShortcutHint)
    }

    private func tabContent(showsLabel: Bool) -> some View {
        HStack(spacing: 4) {
            BreeSystemSymbolImage(
                systemName: item.symbolName,
                pointSize: RightSidebarChromeControlStyle.modeIconSize,
                weight: RightSidebarChromeControlStyle.iconWeight,
                tint: RightSidebarChromeControlStyle.pillForegroundColor(isSelected: isSelected, isHovered: isHovered, palette: palette),
                appliesGlobalFontMagnification: true
            )
                .reportRightSidebarChromeNamedGeometryForBonsplitUITest(
                    keyPrefix: "rightSidebarModeIcon_\(item.id)",
                    isVisible: true
                )
            if showsLabel {
                Text(item.label)
                    .breeFont(.tab, weight: isSelected ? .medium : nil)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            if badgeCount > 0 {
                pendingChip
            }
        }
    }

    private var helpText: String {
        if badgeCount > 0 {
            return String(
                localized: "rightSidebar.mode.pendingHelp",
                defaultValue: "\(item.label) · \(badgeCount) pending"
            )
        }
        return item.label
    }

    private var pendingChip: some View {
        let countText = badgeCount > 9 ? "9+" : String(badgeCount)
        return Text(countText)
            .breeFont(.count, countRow: .caption)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .foregroundStyle(palette.surfaceBase)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(palette.accentFill)
            )
            .fixedSize(horizontal: true, vertical: true)
            .layoutPriority(2)
    }
}
