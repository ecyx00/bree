public import SwiftUI

/// Shared look of Bree's icon-only buttons. `BreeIconButtonStyle` and
/// `BreeCompactIconButtonStyle` differ only in metrics.
private struct BreeIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let hitSize: CGFloat
    let symbolSize: CGFloat
    let isSelected: Bool

    @Environment(\.breePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    // Hover lives here, not on the ButtonStyle struct: style structs are value
    // copies that SwiftUI recreates, so @State there never updates the view.
    @State private var isHovering = false

    private var fill: Color {
        if configuration.isPressed { return palette.pressedFill }
        if isSelected { return palette.selectedQuiet }
        if isHovering { return palette.hoverFill }
        return .clear
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
        configuration.label
            .font(.system(size: symbolSize, weight: .regular))
            .foregroundStyle(isSelected ? palette.activeIndicator : (isHovering || configuration.isPressed ? palette.textPrimary : palette.textSecondary))
            .frame(width: hitSize, height: hitSize)
            .background(shape.fill(fill))
            .overlay {
                if isFocused { shape.stroke(palette.focusRing, lineWidth: 2) }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = isEnabled && $0 }
    }
}

/// 28x28 icon button: 13 pt regular outline symbol, radius 6.
///
/// Hover uses `hoverFill`, pressed `pressedFill`. `isSelected` tints the symbol with the accent
/// on `selectedQuiet`; the caller passes the filled symbol variant for that state. Disabled is 40%.
public struct BreeIconButtonStyle: ButtonStyle {
    public var isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        BreeIconButtonBody(
            configuration: configuration,
            hitSize: BreeMetrics.iconButtonSize,
            symbolSize: 13,
            isSelected: isSelected
        )
    }
}

/// 20x20 icon button (HIG desktop minimum): 11 pt symbol, radius 6. For close, plus and
/// chevron controls inside rows. Same states as ``BreeIconButtonStyle``.
public struct BreeCompactIconButtonStyle: ButtonStyle {
    public var isSelected: Bool

    public init(isSelected: Bool = false) {
        self.isSelected = isSelected
    }

    public func makeBody(configuration: Configuration) -> some View {
        BreeIconButtonBody(
            configuration: configuration,
            hitSize: BreeMetrics.compactIconButtonSize,
            symbolSize: 11,
            isSelected: isSelected
        )
    }
}

public extension ButtonStyle where Self == BreeIconButtonStyle {
    /// `.buttonStyle(.breeIcon)` or `.buttonStyle(.breeIcon(isSelected: true))`.
    static var breeIcon: BreeIconButtonStyle { BreeIconButtonStyle() }
    static func breeIcon(isSelected: Bool) -> BreeIconButtonStyle { BreeIconButtonStyle(isSelected: isSelected) }
}

public extension ButtonStyle where Self == BreeCompactIconButtonStyle {
    /// `.buttonStyle(.breeCompactIcon)` or `.buttonStyle(.breeCompactIcon(isSelected: true))`.
    static var breeCompactIcon: BreeCompactIconButtonStyle { BreeCompactIconButtonStyle() }
    static func breeCompactIcon(isSelected: Bool) -> BreeCompactIconButtonStyle {
        BreeCompactIconButtonStyle(isSelected: isSelected)
    }
}

/// Primary text button: ivory accent fill with base-surface text, radius 6.
/// Replaces `.borderedProminent`, whose fill follows the system blue.
public struct BreeProminentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        BreeProminentButtonBody(configuration: configuration)
    }
}

private struct BreeProminentButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.breePalette) private var palette
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .foregroundStyle(palette.surfaceBase)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: BreeMetrics.radiusControl, style: .continuous)
                    .fill(palette.accentFill)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
    }
}

public extension ButtonStyle where Self == BreeProminentButtonStyle {
    /// Primary action button in the monochrome accent.
    static var breeProminent: BreeProminentButtonStyle { BreeProminentButtonStyle() }
}
