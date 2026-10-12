public import SwiftUI

/// The "Interface text size" setting: the base size `S` of the Bree type scale.
///
/// Stored as an integer point size. The effective base is this value times the
/// global font magnification (see ``BreeType``).
public enum InterfaceTextSize {
    /// UserDefaults key storing the interface text size in points.
    public static let key = "interfaceTextSize"
    /// Default size (macOS Body).
    public static let defaultSize: Int = 13
    /// Smallest selectable size.
    public static let minimumSize: Int = 11
    /// Largest selectable size.
    public static let maximumSize: Int = 16
    /// Step used by settings UI and schema validation.
    public static let step: Int = 1

    /// Notification posted after the setting changes, for AppKit views that cache fonts.
    public static let didChangeNotification = Notification.Name("cmux.interfaceTextSize.didChange")

    /// Clamps a requested size to the supported range.
    public static func clamp(_ size: Int) -> Int {
        Swift.max(minimumSize, Swift.min(maximumSize, size))
    }

    /// The clamped size stored in `UserDefaults.standard`; unset means ``defaultSize``.
    /// Accepts numeric storage and string-encoded integers.
    public static var stored: Int {
        let raw = UserDefaults.standard.object(forKey: key)
        if let number = raw as? NSNumber { return clamp(number.intValue) }
        if let string = raw as? String, let parsed = Int(string) { return clamp(parsed) }
        return defaultSize
    }
}

struct InterfaceTextSizeKey: EnvironmentKey {
    static var defaultValue: Int { InterfaceTextSize.stored }
}

public extension EnvironmentValues {
    /// The current clamped interface text size in points.
    ///
    /// Injected by ``View/cmuxFontMagnificationEnvironment()`` next to the
    /// global font magnification percent.
    var breeInterfaceTextSize: Int {
        get { self[InterfaceTextSizeKey.self] }
        set { self[InterfaceTextSizeKey.self] = InterfaceTextSize.clamp(newValue) }
    }
}
