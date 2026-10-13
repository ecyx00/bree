import BreeFoundation
import SwiftUI

/// Resolves a Bree palette role from the environment at render time, so Settings
/// text follows the terminal theme live without each view declaring `breePalette`.
struct SettingsPaletteStyle: ShapeStyle {
    let role: BreeChromePalette.Role

    func resolve(in environment: EnvironmentValues) -> Color {
        environment.breePalette.color(role)
    }
}

extension ShapeStyle where Self == SettingsPaletteStyle {
    /// Secondary Settings text (notes, row subtitles): `textSecondary`, 4.5:1 floor.
    static var settingsSecondaryText: SettingsPaletteStyle { .init(role: .textSecondary) }
    /// Primary Settings text (section headers): `textPrimary`, 7:1 floor.
    static var settingsPrimaryText: SettingsPaletteStyle { .init(role: .textPrimary) }
    /// Error text, always paired with a message or glyph.
    static var settingsError: SettingsPaletteStyle { .init(role: .signalError) }
    /// Warning text, always paired with a message or glyph.
    static var settingsAttention: SettingsPaletteStyle { .init(role: .signalAttention) }
    static var settingsSuccess: SettingsPaletteStyle { .init(role: .signalSuccess) }
    /// Hairline stroke for cards and fields.
    static var settingsSeparator: SettingsPaletteStyle { .init(role: .separator) }
}
