public import SwiftUI

/// Adds bree-owned font scaling modifiers to SwiftUI views.
public extension View {
    /// Injects the global font magnification percent into this view subtree.
    ///
    /// Apply this once near each bree-owned SwiftUI root. Descendant
    /// ``scaledFont(size:weight:design:monospacedDigit:)`` calls then read the
    /// environment value without creating per-label `UserDefaults`
    /// subscriptions.
    ///
    /// - Returns: A view that supplies the current magnification percent to descendants.
    func breeFontMagnificationEnvironment() -> some View {
        modifier(BreeFontMagnificationEnvironmentModifier())
    }

    /// Apply a system font at `size` points, scaled by the global magnification.
    ///
    /// - Parameters:
    ///   - size: The unscaled base point size.
    ///   - weight: The system font weight to apply.
    ///   - design: The system font design to apply.
    ///   - monospacedDigit: Whether numeric glyphs should use tabular widths.
    /// - Returns: A view with a magnification-aware system font.
    func scaledFont(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        modifier(
            ScaledFontModifier(
                baseSize: size,
                weight: weight,
                design: design,
                monospacedDigit: monospacedDigit
            )
        )
    }

    /// Apply a text-style-sized system font, scaled by the global magnification.
    ///
    /// - Parameters:
    ///   - style: The SwiftUI text style whose bree base metrics should be used.
    ///   - weight: An optional weight override. When `nil`, bree uses the style's default weight.
    ///   - design: The system font design to apply.
    ///   - monospacedDigit: Whether numeric glyphs should use tabular widths.
    /// - Returns: A view with a magnification-aware font for the requested text style.
    func scaledFont(
        _ style: Font.TextStyle,
        weight: Font.Weight? = nil,
        design: Font.Design = .default,
        monospacedDigit: Bool = false
    ) -> some View {
        scaledFont(
            size: BreeTextStyleMetrics(style: style).baseSize,
            weight: weight ?? BreeTextStyleMetrics(style: style).baseWeight,
            design: design,
            monospacedDigit: monospacedDigit
        )
    }
}
