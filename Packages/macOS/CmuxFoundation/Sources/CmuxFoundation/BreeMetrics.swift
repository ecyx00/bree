public import CoreGraphics

/// Shared radii, spacing and sizes of the Bree design system.
public enum BreeMetrics {
    /// Corner radii: badges and chips, controls and rows, cards and popups.
    public static let radiusSmall: CGFloat = 4
    public static let radiusControl: CGFloat = 6
    public static let radiusCard: CGFloat = 10

    /// 4-pt spacing grid.
    public static let spacing4: CGFloat = 4
    public static let spacing8: CGFloat = 8
    public static let spacing12: CGFloat = 12
    public static let spacing16: CGFloat = 16
    public static let spacing24: CGFloat = 24

    /// Row heights: single-line and two-line.
    public static let rowHeight: CGFloat = 28
    public static let rowHeightTwoLine: CGFloat = 44

    /// Icon-button hit sizes (square): standard and compact (HIG desktop minimum).
    public static let iconButtonSize: CGFloat = 28
    public static let compactIconButtonSize: CGFloat = 20
}
