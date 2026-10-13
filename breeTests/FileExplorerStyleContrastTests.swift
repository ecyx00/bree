import AppKit
import BreeFoundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// The Files tree reads its colours from the Bree palette (a dynamic colour per
/// role), so these tests install a dark and a light theme palette and check the
/// resolved colours against the surfaces the palette guarantees.
@MainActor
@Suite struct FileExplorerStyleContrastTests {
    private let minimumTextContrast: CGFloat = 4.5
    private let minimumIconContrast: CGFloat = 3
    private let statuses: [GitFileStatus] = [.modified, .added, .deleted, .renamed, .untracked]
    private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

    private static func palette(background: String, foreground: String, ansi: [String]) -> BreeChromePalette {
        BreeChromePalette(
            BreeChromePalette.Inputs(
                background: BreeRGBA(hex: background) ?? BreeRGBA(red: 0, green: 0, blue: 0),
                foreground: BreeRGBA(hex: foreground) ?? BreeRGBA(red: 1, green: 1, blue: 1),
                ansi: ansi.compactMap { BreeRGBA(hex: $0) },
                increaseContrast: false
            )
        )
    }

    private static let darkPalette = palette(
        background: "#282A36", foreground: "#F8F8F2",
        ansi: ["#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
               "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF"]
    )
    private static let lightPalette = palette(
        background: "#FDF6E3", foreground: "#657B83",
        ansi: ["#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#BBB5A2",
               "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3"]
    )

    /// Installs `palette` for the duration of `body`, then restores the previous one.
    private func withPalette<T>(_ palette: BreeChromePalette, _ body: (BreeChromePalette) throws -> T) rethrows -> T {
        let previous = BreeChromePaletteStore.shared.palette
        BreeChromePaletteStore.shared.update(palette)
        defer { BreeChromePaletteStore.shared.update(previous) }
        return try body(palette)
    }

    private func surfaces(of palette: BreeChromePalette) -> [(String, NSColor)] {
        BreeChromePalette.contrastSurfaces.map { ($0.rawValue, palette.nsColor($0)) }
    }

    @Test func filenameColorsMeetContrastOnEverySurface() throws {
        for palette in [Self.darkPalette, Self.lightPalette] {
            try withPalette(palette) { palette in
                for style in FileExplorerStyle.allCases {
                    for status in statuses {
                        for name in appearances {
                            let appearance = try #require(NSAppearance(named: name))
                            let foreground = try resolved(style.gitColor(for: status), in: appearance)
                            for (surface, background) in surfaces(of: palette) {
                                let ratio = contrastRatio(foreground: foreground, background: background)
                                #expect(
                                    ratio >= minimumTextContrast,
                                    "\(style.label) \(statusName(status)) text contrast on \(surface) was \(ratio)"
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    @Test func plainTextAndSelectedRowsMeetContrast() throws {
        for palette in [Self.darkPalette, Self.lightPalette] {
            try withPalette(palette) { palette in
                let appearance = try #require(NSAppearance(named: .aqua))
                let plain = try resolved(FileExplorerPalette.textPrimary, in: appearance)
                let quiet = composited(palette.nsColor(.selectedQuiet), over: palette.nsColor(.surfaceBase))
                #expect(contrastRatio(foreground: plain, background: palette.nsColor(.surfaceBase)) >= minimumTextContrast)
                #expect(contrastRatio(foreground: plain, background: quiet) >= minimumTextContrast)

                // Focused selection: the cell draws white text on the opaque selectedFill.
                let focused = try resolved(FileExplorerPalette.selectedFill, in: appearance)
                #expect(contrastRatio(foreground: .white, background: focused) >= minimumTextContrast)
            }
        }
    }

    @Test func declaredIconTintsMeetContrastOnEverySurface() throws {
        for palette in [Self.darkPalette, Self.lightPalette] {
            try withPalette(palette) { palette in
                for style in FileExplorerStyle.allCases {
                    for (kind, tint) in [("file", style.fileIconTint), ("folder", style.folderIconTint)] {
                        let appearance = try #require(NSAppearance(named: .aqua))
                        let foreground = try resolved(tint, in: appearance)
                        for (surface, background) in surfaces(of: palette) {
                            let ratio = contrastRatio(foreground: foreground, background: background)
                            #expect(
                                ratio >= minimumIconContrast,
                                "\(style.label) \(kind) icon contrast on \(surface) was \(ratio)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test func paletteColorsFollowThePaletteAndReuseProviders() throws {
        let appearance = try #require(NSAppearance(named: .aqua))
        for style in FileExplorerStyle.allCases {
            for status in statuses {
                let color = style.gitColor(for: status)
                #expect(color === style.gitColor(for: status))
                let dark = withPalette(Self.darkPalette) { _ in try? resolved(color, in: appearance) }
                let light = withPalette(Self.lightPalette) { _ in try? resolved(color, in: appearance) }
                let darkColor = try #require(dark)
                let lightColor = try #require(light)
                #expect(
                    !hasSameRGBA(darkColor, lightColor),
                    "\(style.label) \(statusName(status)) did not follow the palette"
                )
            }
            #expect(style.fileIconTint === style.fileIconTint)
            #expect(style.folderIconTint === style.folderIconTint)
        }
    }

    @Test func plainFilesUsePrimaryTextRole() throws {
        let cell = FileExplorerCellView(identifier: NSUserInterfaceItemIdentifier("contrast-test"))
        let node = FileExplorerNode(name: "plain.swift", path: "/plain.swift", isDirectory: false)

        cell.configure(with: node)

        let nameLabel = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first)
        #expect(nameLabel.textColor === FileExplorerPalette.textPrimary)
    }

    private func resolved(_ color: NSColor, in appearance: NSAppearance) throws -> NSColor {
        var resolvedColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolvedColor = color.usingColorSpace(.sRGB)
        }
        return try #require(resolvedColor)
    }

    private func contrastRatio(foreground: NSColor, background: NSColor) -> CGFloat {
        let opaqueForeground = composited(foreground, over: background)
        let foregroundLuminance = relativeLuminance(opaqueForeground)
        let backgroundLuminance = relativeLuminance(background)
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func relativeLuminance(_ color: NSColor) -> CGFloat {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        srgb.getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        func linearized(_ component: CGFloat) -> CGFloat {
            component <= 0.03928
                ? component / 12.92
                : CGFloat(pow(Double((component + 0.055) / 1.055), 2.4))
        }

        return 0.2126 * linearized(red)
            + 0.7152 * linearized(green)
            + 0.0722 * linearized(blue)
    }

    private func composited(_ foreground: NSColor, over background: NSColor) -> NSColor {
        let foreground = foreground.usingColorSpace(.sRGB) ?? foreground
        let background = background.usingColorSpace(.sRGB) ?? background
        let alpha = foreground.alphaComponent
        return NSColor(
            srgbRed: foreground.redComponent * alpha + background.redComponent * (1 - alpha),
            green: foreground.greenComponent * alpha + background.greenComponent * (1 - alpha),
            blue: foreground.blueComponent * alpha + background.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    private func hasSameRGBA(_ lhs: NSColor, _ rhs: NSColor) -> Bool {
        let lhs = lhs.usingColorSpace(.sRGB) ?? lhs
        let rhs = rhs.usingColorSpace(.sRGB) ?? rhs
        return abs(lhs.redComponent - rhs.redComponent) < 0.001
            && abs(lhs.greenComponent - rhs.greenComponent) < 0.001
            && abs(lhs.blueComponent - rhs.blueComponent) < 0.001
            && abs(lhs.alphaComponent - rhs.alphaComponent) < 0.001
    }

    private func statusName(_ status: GitFileStatus) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        case .renamed: "renamed"
        case .untracked: "untracked"
        }
    }
}
