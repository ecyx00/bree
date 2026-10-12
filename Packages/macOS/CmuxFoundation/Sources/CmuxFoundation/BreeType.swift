public import AppKit
public import SwiftUI

/// Semantic text roles of the Bree type scale. Base `S` = interface text size x magnification.
public enum BreeTextRole: Sendable, CaseIterable {
    /// `S`, medium: section headers, panel titles.
    case title
    /// `S`, regular: rows, lists, trees, menus drawn by Bree.
    case body
    /// `S-1`, regular (pass `.medium` when selected): tab titles.
    case tab
    /// `S-1`, regular: row details, subtitles.
    case secondary
    /// `S-2`, regular or medium: meta, badges, hints. The smallest role.
    case caption
    /// `S-1`, regular, SF Mono: paths, shortcuts, branch names, hashes.
    case mono
    /// Numbers inside rows and badges: SF Pro with monospaced digits at its row's size.
    case count

    var pointOffset: CGFloat {
        switch self {
        case .title, .body, .count: return 0
        case .tab, .secondary, .mono: return -1
        case .caption: return -2
        }
    }

    var defaultWeight: Font.Weight { self == .title ? .medium : .regular }
}

/// A fully resolved font recipe. Floors are already applied.
public struct BreeTypeSpec: Equatable, Sendable {
    /// Point size, never below ``BreeType/minimumPointSize``.
    public let size: CGFloat
    /// Weight, never heavier than medium.
    public let weight: Font.Weight
    /// Whether the face is SF Mono.
    public let isMonospaced: Bool
    /// Whether digits are tabular.
    public let monospacedDigit: Bool
}

/// Resolves and applies the Bree type scale. Floors live here so callers cannot violate them.
public enum BreeType {
    /// Nothing is drawn below this size (HIG minimum).
    public static let minimumPointSize: CGFloat = 10
    /// Semibold and heavier weights are downgraded to medium below this size.
    public static let minimumSemiboldPointSize: CGFloat = 11

    /// Pure resolver, used by the SwiftUI modifier, the AppKit accessors and tests.
    ///
    /// - Parameters:
    ///   - role: The text role.
    ///   - weight: Optional weight override (for example `.medium` for a selected tab).
    ///   - countRow: For `.count`, the role of the row the number sits in; ignored otherwise.
    ///   - interfaceSize: Interface text size in points; clamped to 11...16.
    ///   - magnificationPercent: Global font magnification percent; clamped to its range.
    public static func spec(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body,
        interfaceSize: Int,
        magnificationPercent: Int
    ) -> BreeTypeSpec {
        let sizingRole = (role == .count && countRow != .count) ? countRow : role
        let base = GlobalFontMagnification.scaledSize(
            CGFloat(InterfaceTextSize.clamp(interfaceSize)),
            percent: magnificationPercent
        )
        let size = max(minimumPointSize, base + sizingRole.pointOffset)
        var resolved = weight ?? (role == .count ? sizingRole.defaultWeight : role.defaultWeight)
        // Claude-style hierarchy is size and tone, not weight: medium is the ceiling.
        if resolved.isSemiboldOrHeavier { resolved = .medium }
        return BreeTypeSpec(
            size: size,
            weight: resolved,
            isMonospaced: role == .mono,
            monospacedDigit: role == .count
        )
    }

    /// AppKit font for `role` using the stored interface size and magnification.
    /// Reapply when ``InterfaceTextSize/didChangeNotification`` or
    /// ``GlobalFontMagnification/didChangeNotification`` posts.
    public static func nsFont(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body
    ) -> NSFont {
        let spec = spec(
            role,
            weight: weight,
            countRow: countRow,
            interfaceSize: InterfaceTextSize.stored,
            magnificationPercent: GlobalFontMagnification.storedPercent
        )
        let nsWeight = spec.weight.nsWeight
        if spec.isMonospaced { return NSFont.monospacedSystemFont(ofSize: spec.size, weight: nsWeight) }
        if spec.monospacedDigit { return NSFont.monospacedDigitSystemFont(ofSize: spec.size, weight: nsWeight) }
        return NSFont.systemFont(ofSize: spec.size, weight: nsWeight)
    }
}

private extension Font.Weight {
    var isSemiboldOrHeavier: Bool {
        self == .semibold || self == .bold || self == .heavy || self == .black
    }

    var nsWeight: NSFont.Weight {
        switch self {
        case .ultraLight: return .ultraLight
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}

struct BreeFontModifier: ViewModifier {
    @Environment(\.cmuxGlobalFontMagnificationPercent) private var percent
    @Environment(\.breeInterfaceTextSize) private var interfaceSize
    let role: BreeTextRole
    let weight: Font.Weight?
    let countRow: BreeTextRole

    func body(content: Content) -> some View {
        content.font(resolvedFont)
    }

    private var resolvedFont: Font {
        let spec = BreeType.spec(
            role,
            weight: weight,
            countRow: countRow,
            interfaceSize: interfaceSize,
            magnificationPercent: percent
        )
        var font = Font.system(size: spec.size, weight: spec.weight, design: spec.isMonospaced ? .monospaced : .default)
        if spec.monospacedDigit { font = font.monospacedDigit() }
        return font
    }
}

public extension View {
    /// Applies a Bree type role, honoring interface text size, global magnification and the floors.
    ///
    /// - Parameters:
    ///   - role: The text role.
    ///   - weight: Optional weight override, for example `.medium` for a selected tab or caption.
    ///   - countRow: For `.count`, the role of the surrounding row, so numbers match their label.
    func breeFont(
        _ role: BreeTextRole,
        weight: Font.Weight? = nil,
        countRow: BreeTextRole = .body
    ) -> some View {
        modifier(BreeFontModifier(role: role, weight: weight, countRow: countRow))
    }
}
