import Foundation

/// One terminal color Settings > Themes can override in cmux's Ghostty config.
public enum GhosttyTerminalColorSlot: Hashable, Sendable {
    case background
    case foreground
    case cursor
    case selectionBackground
    case selectionForeground
    /// An ANSI palette entry, 0...15.
    case palette(Int)

    /// The ANSI palette entries the editor exposes.
    public static let paletteRange = 0...15

    /// Every editable slot, in display order.
    public static let all: [GhosttyTerminalColorSlot] =
        [.background, .foreground, .cursor, .selectionBackground, .selectionForeground]
        + paletteRange.map { .palette($0) }

    /// The distinct Ghostty keys the slots write; `palette` is a repeated key.
    public static let configKeys = [
        "background", "foreground", "cursor-color",
        "selection-background", "selection-foreground", "palette",
    ]

    /// The Ghostty key this slot is written under.
    public var configKey: String {
        switch self {
        case .background: return "background"
        case .foreground: return "foreground"
        case .cursor: return "cursor-color"
        case .selectionBackground: return "selection-background"
        case .selectionForeground: return "selection-foreground"
        case .palette: return "palette"
        }
    }
}

/// A set of `#rrggbb` colors keyed by slot: the colors in effect, or the
/// overrides cmux's config holds.
public struct GhosttyTerminalColors: Equatable, Sendable {
    /// Lowercase `#rrggbb` per slot. Absent slots are not set.
    public var hexBySlot: [GhosttyTerminalColorSlot: String]

    public init(hexBySlot: [GhosttyTerminalColorSlot: String] = [:]) {
        self.hexBySlot = hexBySlot
    }

    public var isEmpty: Bool { hexBySlot.isEmpty }

    /// Folds config assignments (unquoted values per key, in load order) into
    /// colors. The last valid value wins and an empty value clears the slot,
    /// as in Ghostty. Keys outside ``GhosttyTerminalColorSlot/configKeys`` are
    /// ignored.
    public init(directives: [String: [String]]) {
        var result: [GhosttyTerminalColorSlot: String] = [:]
        let single: [(String, GhosttyTerminalColorSlot)] = [
            ("background", .background), ("foreground", .foreground),
            ("cursor-color", .cursor), ("selection-background", .selectionBackground),
            ("selection-foreground", .selectionForeground),
        ]
        for (key, slot) in single {
            for raw in directives[key] ?? [] {
                let value = raw.trimmingCharacters(in: .whitespaces)
                if value.isEmpty {
                    result[slot] = nil
                } else if let hex = Self.normalizedHex(value) {
                    result[slot] = hex
                }
            }
        }
        for raw in directives["palette"] ?? [] {
            let value = raw.trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                for index in GhosttyTerminalColorSlot.paletteRange { result[.palette(index)] = nil }
                continue
            }
            guard let separator = value.firstIndex(of: "="),
                  let index = Int(value[..<separator].trimmingCharacters(in: .whitespaces)),
                  GhosttyTerminalColorSlot.paletteRange.contains(index),
                  let hex = Self.normalizedHex(String(value[value.index(after: separator)...]))
            else { continue }
            result[.palette(index)] = hex
        }
        hexBySlot = result
    }

    /// The config values to write for `key`, one line each, in slot order.
    /// Empty when no slot uses `key`, which removes the key from the file.
    public func configValues(forKey key: String) -> [String] {
        GhosttyTerminalColorSlot.all.compactMap { slot in
            guard slot.configKey == key, let hex = hexBySlot[slot] else { return nil }
            if case .palette(let index) = slot { return "\(index)=\(hex)" }
            return hex
        }
    }

    /// `#rrggbb` (lowercased) from `#rgb`, `#rrggbb`, or either without `#`;
    /// `nil` for anything else (named colors, `cell-foreground`, bad digits).
    public static func normalizedHex(_ value: String) -> String? {
        var digits = value.trimmingCharacters(in: .whitespaces)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.allSatisfy(\.isHexDigit) else { return nil }
        switch digits.count {
        case 6: return "#" + digits.lowercased()
        case 3: return "#" + digits.lowercased().map { "\($0)\($0)" }.joined()
        default: return nil
        }
    }

    /// WCAG contrast ratio between two `#rrggbb` colors, or `nil` if either is invalid.
    public static func contrastRatio(_ first: String, _ second: String) -> Double? {
        guard let a = luminance(first), let b = luminance(second) else { return nil }
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func luminance(_ hex: String) -> Double? {
        guard let normalized = normalizedHex(hex), let value = Int(normalized.dropFirst(), radix: 16) else { return nil }
        func channel(_ shift: Int) -> Double {
            let c = Double((value >> shift) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
    }
}

/// What the Themes color editor shows: the colors in effect and the part of
/// them cmux's own config overrides.
public struct GhosttyTerminalColorSnapshot: Equatable, Sendable {
    public var effective: GhosttyTerminalColors
    public var overrides: GhosttyTerminalColors

    public init(effective: GhosttyTerminalColors = .init(), overrides: GhosttyTerminalColors = .init()) {
        self.effective = effective
        self.overrides = overrides
    }

    public static let defaults = GhosttyTerminalColorSnapshot()
}
