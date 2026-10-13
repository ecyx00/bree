public import SwiftUI

/// Adds bree font magnification values to SwiftUI environment lookups.
public extension EnvironmentValues {
    /// The current clamped global font magnification percent.
    ///
    /// bree scene roots should inject this value with
    /// ``View/breeFontMagnificationEnvironment()`` so repeated row labels can
    /// read a pure environment value instead of each subscribing to
    /// `UserDefaults`.
    var breeGlobalFontMagnificationPercent: Int {
        get { self[BreeGlobalFontMagnificationPercentKey.self] }
        set { self[BreeGlobalFontMagnificationPercentKey.self] = GlobalFontMagnification.clamp(newValue) }
    }
}
