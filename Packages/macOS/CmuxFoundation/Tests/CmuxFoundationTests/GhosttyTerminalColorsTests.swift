import Foundation
import Testing
@testable import CmuxFoundation

/// Covers the Themes color editor's config mapping: the lines each override
/// writes to cmux's config, reading them back, and removing only those lines.
@Suite("Ghostty terminal colors")
struct GhosttyTerminalColorsTests {
    private let editor = CmuxGhosttyConfigSettingEditor()

    /// Writes `colors` the way the host does: one replace-or-remove per key.
    private func write(_ colors: GhosttyTerminalColors, into contents: String) -> String {
        GhosttyTerminalColorSlot.configKeys.reduce(contents) { text, key in
            editor.updatedContents(text, setting: key, values: colors.configValues(forKey: key))
        }
    }

    /// Reads assignments back like `GhosttyConfig.resolvedDirectiveValues`.
    private func directives(in contents: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for line in contents.split(separator: "\n") {
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            result[key, default: []].append(value)
        }
        return result
    }

    @Test("Overrides survive a write and read round trip")
    func roundTrip() {
        let colors = GhosttyTerminalColors(hexBySlot: [
            .background: "#101010", .foreground: "#eeeeee", .cursor: "#ff8800",
            .selectionBackground: "#223344", .selectionForeground: "#ffffff",
            .palette(1): "#cc0000", .palette(15): "#fafafa",
        ])
        let contents = write(colors, into: "font-size = 14\n")
        #expect(contents.contains("palette = 1=#cc0000"))
        #expect(contents.contains("palette = 15=#fafafa"))
        #expect(GhosttyTerminalColors(directives: directives(in: contents)) == colors)
    }

    @Test("Reset removes only the color lines")
    func resetKeepsOtherSettings() {
        let colors = GhosttyTerminalColors(hexBySlot: [.background: "#101010", .palette(2): "#00aa00"])
        let written = write(colors, into: "font-size = 14\ntheme = nord\n")
        let reset = write(GhosttyTerminalColors(), into: written)
        #expect(reset.trimmingCharacters(in: .whitespacesAndNewlines) == "font-size = 14\ntheme = nord")
    }

    @Test("Hex parsing accepts short and bare forms and rejects the rest")
    func hexNormalization() {
        #expect(GhosttyTerminalColors.normalizedHex("#ABC") == "#aabbcc")
        #expect(GhosttyTerminalColors.normalizedHex("A1B2C3") == "#a1b2c3")
        #expect(GhosttyTerminalColors.normalizedHex("cell-foreground") == nil)
        #expect(GhosttyTerminalColors.normalizedHex("#12345") == nil)
    }

    @Test("Contrast ratio matches the WCAG extremes")
    func contrast() throws {
        let ratio = try #require(GhosttyTerminalColors.contrastRatio("#000000", "#ffffff"))
        #expect(abs(ratio - 21) < 0.01)
    }
}
