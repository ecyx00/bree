import BreeFoundation
import Foundation
import Testing
@testable import BreeTerminalCore

/// Settings > Terminal shows the effective value of each Ghostty option it
/// edits, so the user's own Ghostty config and bree's config (which loads after
/// it) have to fold together the way Ghostty loads them.
@Suite struct GhosttyConfigResolvedDirectiveValuesTests {
    private func withTempDir(_ body: (URL) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bree-terminal-options-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try body(dir)
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @Test func collectsValuesInLoadOrderWithIncludesLast() throws {
        try withTempDir { dir in
            let user = dir.appendingPathComponent("ghostty-config")
            let bree = dir.appendingPathComponent("bree-config")
            let include = dir.appendingPathComponent("extra")
            try write(
                """
                font-family = "Fira Code"
                font-size = 15
                config-file = extra
                cursor-style = underline
                theme = Dracula
                """,
                to: user
            )
            try write("cursor-style = block_hollow\n", to: include)
            try write(
                """
                font-family = ""
                font-family = "SF Mono"
                cursor-style = bar
                """,
                to: bree
            )

            let resolved = GhosttyConfig.resolvedDirectiveValues(
                forKeys: GhosttyTerminalOptions.configKeys,
                configPaths: [user.path, bree.path]
            )
            let values = resolved.values

            #expect(values["font-family"] == ["Fira Code", "", "SF Mono"])
            #expect(values["font-size"] == ["15"])
            // Ghostty reads `config-file` includes after every top-level file.
            #expect(values["cursor-style"] == ["underline", "bar", "block_hollow"])
            #expect(values["theme"] == nil)
            #expect(values["background-opacity"] == nil)
            // The include made the last cursor-style assignment, so it overrides bree's config.
            #expect(resolved.lastSourcePaths["cursor-style"]?.hasSuffix("/extra") == true)
            #expect(resolved.lastSourcePaths["font-size"]?.hasSuffix("/ghostty-config") == true)

            let options = GhosttyTerminalOptions(directives: values)
            #expect(options.fontFamily == "SF Mono")
            #expect(options.fontSize == 15)
            #expect(options.cursorStyle == .blockHollow)
        }
    }

    @Test func missingFilesContributeNothing() throws {
        try withTempDir { dir in
            let values = GhosttyConfig.resolvedDirectiveValues(
                forKeys: GhosttyTerminalOptions.configKeys,
                configPaths: [dir.appendingPathComponent("absent").path]
            ).values
            #expect(values.isEmpty)
            #expect(GhosttyTerminalOptions(directives: values) == .defaults)
        }
    }
}
