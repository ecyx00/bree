import AppKit
import CmuxFoundation
import SwiftUI

/// Rounded grouped container for a vertical stack of
/// ``SettingsCardRow``s separated by ``SettingsCardDivider``s.
///
/// A `surfaceRaised` rectangle with the card radius and a `separator`
/// hairline. Hosts use one ``SettingsCard`` per subsection
/// of the settings page.
///
/// ```swift
/// SettingsSectionHeader("Appearance")
/// SettingsCard {
///     SettingsCardRow(...)
///     SettingsCardDivider()
///     SettingsCardRow(...)
/// }
/// ```
@MainActor
public struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.breePalette) private var palette

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous)
                .fill(palette.surfaceRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: BreeMetrics.radiusCard, style: .continuous)
                        .strokeBorder(palette.separator, lineWidth: 1)
                )
        )
    }
}
