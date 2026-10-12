import Foundation

/// Display form of a program-set terminal title for the tab label.
///
/// Programs prefix titles with status glyphs (Claude Code sets `✳ Task name`, spinners cycle
/// braille frames). Those are stripped so the label reads as text. An idle shell reports its
/// cwd as the title; only the last path component is shown (`bree-rs`, not `/private/tmp/bree-rs`).
enum TerminalTabTitleDisplay {
    static func display(_ raw: String) -> String {
        var scalars = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines)).unicodeScalars
        while let first = scalars.first, isDecoration(first) {
            scalars = scalars.dropFirst()
        }
        let stripped = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        let base = stripped.isEmpty ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : stripped
        return lastPathComponentIfPath(base)
    }

    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool {
        if CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
        switch scalar.properties.generalCategory {
        case .otherSymbol, .modifierSymbol, .nonspacingMark, .format:
            return true
        default:
            return scalar.value > 0x7F && scalar.properties.isEmojiPresentation
        }
    }

    private static func lastPathComponentIfPath(_ title: String) -> String {
        guard title.hasPrefix("/") || title.hasPrefix("~/") else { return title }
        if title.contains(" ") {
            var isDirectory: ObjCBool = false
            let expanded = (title as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return title }
        }
        let last = (title as NSString).lastPathComponent
        return last.isEmpty ? title : last
    }
}
