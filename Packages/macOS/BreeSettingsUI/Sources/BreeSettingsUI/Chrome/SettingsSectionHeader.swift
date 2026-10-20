import BreeFoundation
import SwiftUI

/// Section header rendered above a ``SettingsCard``.
///
/// Mirrors the legacy in-app chrome: title in the primary text role
/// nudged 2pt right of the card, intentionally tucked close to the
/// card below it.
///
/// Pass the owning ``SettingsSectionID`` so the header pulses the
/// search-result highlight when the user clicks that section's hit in
/// the sidebar search (matching the per-row highlight). The scroll
/// `.id` stays on the enclosing section, so the header only takes the
/// highlight overlay, never a duplicate `.id`.
@MainActor
public struct SettingsSectionHeader: View {
    let title: String
    let section: SettingsSectionID?

    public init(_ title: String, section: SettingsSectionID? = nil) {
        self.title = title
        self.section = section
    }

    public var body: some View {
        // The window toolbar already shows the section title
        // (`navigationTitle`), so the page carries a zero-size anchor only:
        // it keeps the section id, search highlight and UI-test identifier.
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityElement()
            .settingsSearchHighlight(section.map { ["section:\($0.rawValue)"] } ?? [])
    }
}
