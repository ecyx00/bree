import Foundation
import Testing

#if canImport(Bree_Dev)
@testable import Bree_Dev
#elseif canImport(bree)
@testable import bree
#endif

/// Pure-logic coverage for the file explorer double-click action setting
/// (`fileExplorer.doubleClickAction`). Verifies parse/validation (unknown
/// values fall back to `preview`), UserDefaults round-tripping, and the
/// action-resolution function that maps a configured action plus the
/// preferred-editor availability to the concrete open behavior — including the
/// `preferredEditor` → `defaultEditor` fallback when no command is configured.
///
/// The NSOutlineView / NSTableView gesture wiring itself (doubleAction targets)
/// is AppKit-bound and not cleanly unit-testable; it is exercised manually and
/// not faked here.
@Suite struct FileExplorerDoubleClickActionTests {
    private func makeDefaults() -> UserDefaults {
        let suiteName = "bree-file-explorer-double-click-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    // MARK: - Parse / validation

    @Test func defaultIsPreview() {
        #expect(FileExplorerDoubleClickActionSettings.defaultValue == .preview)
    }

    @Test func parsesEachKnownRawValue() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preview") == .preview)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "defaultEditor") == .defaultEditor)
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: "preferredEditor") == .preferredEditor)
    }

    @Test func nilRawValueFallsBackToPreview() {
        #expect(FileExplorerDoubleClickActionSettings.action(forRawValue: nil) == .preview)
    }

    @Test func unknownRawValueFallsBackToPreview() {
        for raw in ["", "  ", "Preview", "PREVIEW", "editor", "default", "preferred", "garbage"] {
            #expect(
                FileExplorerDoubleClickActionSettings.action(forRawValue: raw) == .preview,
                "unknown raw value \(raw.debugDescription) should fall back to preview"
            )
        }
    }

    @Test func rawValuesMatchConfigSchema() {
        #expect(FileExplorerDoubleClickAction.preview.rawValue == "preview")
        #expect(FileExplorerDoubleClickAction.defaultEditor.rawValue == "defaultEditor")
        #expect(FileExplorerDoubleClickAction.preferredEditor.rawValue == "preferredEditor")
        #expect(
            FileExplorerDoubleClickAction.allCases == [.preview, .defaultEditor, .preferredEditor]
        )
    }

    // MARK: - UserDefaults round-trip

    @Test func resolvedActionDefaultsToPreviewWhenUnset() {
        let defaults = makeDefaults()
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    @Test func resolvedActionReadsStoredValue() {
        for action in FileExplorerDoubleClickAction.allCases {
            let defaults = makeDefaults()
            FileExplorerDoubleClickActionSettings.setAction(
                action,
                defaults: defaults,
                notificationCenter: NotificationCenter()
            )
            #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == action)
        }
    }

    @Test func resolvedActionFallsBackForCorruptedStoredValue() {
        let defaults = makeDefaults()
        defaults.set("not-a-real-action", forKey: FileExplorerDoubleClickActionSettings.key)
        #expect(FileExplorerDoubleClickActionSettings.resolvedAction(defaults: defaults) == .preview)
    }

    // MARK: - Action resolution (setting + preferred-editor availability)

    @Test func previewResolvesToPreviewRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .preview,
                    hasPreferredEditorCommand: hasEditor
                ) == .preview
            )
        }
    }

    @Test func defaultEditorResolvesToDefaultEditorRegardlessOfPreferredEditor() {
        for hasEditor in [true, false] {
            #expect(
                FileExplorerDoubleClickActionSettings.fileActivation(
                    action: .defaultEditor,
                    hasPreferredEditorCommand: hasEditor
                ) == .defaultEditor
            )
        }
    }

    @Test func preferredEditorResolvesToPreferredEditorWhenCommandConfigured() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: true
            ) == .preferredEditor
        )
    }

    @Test func preferredEditorFallsBackToDefaultEditorWhenNoCommand() {
        #expect(
            FileExplorerDoubleClickActionSettings.fileActivation(
                action: .preferredEditor,
                hasPreferredEditorCommand: false
            ) == .defaultEditor
        )
    }
}

@Suite("File explorer file operations")
struct FileExplorerFileOperationsTests {
    @Test("Duplicate names follow Finder: copy, copy 2, extension kept")
    func copyNames() {
        let taken: Set<String> = ["a copy.txt", "a copy 2.txt", "dir copy"]
        #expect(FileExplorerFileOperations.copyName(for: "a.txt", isDirectory: false) { taken.contains($0) } == "a copy 3.txt")
        #expect(FileExplorerFileOperations.copyName(for: "b.txt", isDirectory: false) { taken.contains($0) } == "b copy.txt")
        #expect(FileExplorerFileOperations.copyName(for: ".env", isDirectory: false) { taken.contains($0) } == ".env copy")
        #expect(FileExplorerFileOperations.copyName(for: "dir", isDirectory: true) { taken.contains($0) } == "dir copy 2")
        #expect(FileExplorerFileOperations.copyName(for: "v1.2", isDirectory: true) { _ in false } == "v1.2 copy")
    }

    @Test("Rename validation refuses empty, slash, dot names and existing targets")
    func renameValidation() throws {
        let exists: (String) -> Bool = { $0 == "/tmp/taken" }
        #expect(try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/a", newName: " b ", fileExists: exists) == "/tmp/b")
        #expect(throws: FileExplorerFileOperations.RenameError.empty) {
            try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/a", newName: "  ", fileExists: exists)
        }
        #expect(throws: FileExplorerFileOperations.RenameError.invalid) {
            try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/a", newName: "x/y", fileExists: exists)
        }
        #expect(throws: FileExplorerFileOperations.RenameError.invalid) {
            try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/a", newName: "..", fileExists: exists)
        }
        #expect(throws: FileExplorerFileOperations.RenameError.exists("taken")) {
            try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/a", newName: "taken", fileExists: exists)
        }
        // case-only rename of an existing item is allowed
        #expect(try FileExplorerFileOperations.renameTarget(oldPath: "/tmp/Taken", newName: "taken", fileExists: exists) == "/tmp/taken")
    }

    @Test("Paste keeps a free name and adds copy suffixes on collision")
    func pasteNames() {
        let taken: Set<String> = ["a.txt", "a copy.txt", "dir"]
        #expect(FileExplorerFileOperations.pasteName(for: "new.txt", isDirectory: false) { taken.contains($0) } == "new.txt")
        #expect(FileExplorerFileOperations.pasteName(for: "a.txt", isDirectory: false) { taken.contains($0) } == "a copy 2.txt")
        #expect(FileExplorerFileOperations.pasteName(for: "dir", isDirectory: true) { taken.contains($0) } == "dir copy")
    }

    @Test("Descendant check does not match sibling prefixes")
    func descendantCheck() {
        #expect(FileExplorerFileOperations.isSameOrDescendant("/tmp/a/b", of: "/tmp/a"))
        #expect(FileExplorerFileOperations.isSameOrDescendant("/tmp/a", of: "/tmp/a"))
        #expect(!FileExplorerFileOperations.isSameOrDescendant("/tmp/ab", of: "/tmp/a"))
    }

    private func makeTempRoot() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bree-fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test("Paste copies into the folder and renames collisions")
    func pasteIntoFolder() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/src/a.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: root + "/dst/a.txt", atomically: true, encoding: .utf8)

        let first = try FileExplorerFileOperations.paste(sources: [root + "/src/a.txt"], intoFolder: root + "/dst")
        #expect(first == [root + "/dst/a copy.txt"])
        let second = try FileExplorerFileOperations.paste(sources: [root + "/src/a.txt"], intoFolder: root + "/dst")
        #expect(second == [root + "/dst/a copy 2.txt"])
        #expect(fm.fileExists(atPath: root + "/src/a.txt"))
        // Pasting into the file's own folder duplicates it.
        let same = try FileExplorerFileOperations.paste(sources: [root + "/src/a.txt"], intoFolder: root + "/src")
        #expect(same == [root + "/src/a copy.txt"])
    }

    @Test("Paste refuses a folder into itself")
    func pasteIntoItself() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/d/sub", withIntermediateDirectories: true)
        #expect(throws: FileExplorerFileOperations.TransferError.intoItself("d")) {
            try FileExplorerFileOperations.paste(sources: [root + "/d"], intoFolder: root + "/d/sub")
        }
    }

    @Test("Move relocates items, skips same-folder items and refuses collisions")
    func moveIntoFolder() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/dst", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8)
        try "x".write(toFile: root + "/b.txt", atomically: true, encoding: .utf8)
        try "y".write(toFile: root + "/dst/b.txt", atomically: true, encoding: .utf8)

        let moved = try FileExplorerFileOperations.move(sources: [root + "/a.txt"], intoFolder: root + "/dst")
        #expect(moved.map(\.to) == [root + "/dst/a.txt"])
        #expect(!fm.fileExists(atPath: root + "/a.txt"))
        #expect(throws: FileExplorerFileOperations.TransferError.exists("b.txt")) {
            try FileExplorerFileOperations.move(sources: [root + "/b.txt"], intoFolder: root + "/dst")
        }
        #expect(fm.fileExists(atPath: root + "/b.txt"))
        // Moving an item into the folder it already lives in is a no-op.
        let noop = try FileExplorerFileOperations.move(sources: [root + "/dst/a.txt"], intoFolder: root + "/dst")
        #expect(noop.isEmpty)
    }

    @Test("Move refuses a folder into its own descendant")
    func moveIntoDescendant() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try FileManager.default.createDirectory(atPath: root + "/d/sub", withIntermediateDirectories: true)
        #expect(throws: FileExplorerFileOperations.TransferError.intoItself("d")) {
            try FileExplorerFileOperations.move(sources: [root + "/d"], intoFolder: root + "/d/sub")
        }
    }

    @Test("Paste and move never write into an Obsidian vault")
    func vaultIsReadOnly() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root + "/vault/.obsidian", withIntermediateDirectories: true)
        try "x".write(toFile: root + "/a.md", atomically: true, encoding: .utf8)
        #expect(throws: FileExplorerFileOperations.TransferError.vaultReadOnly("vault")) {
            try FileExplorerFileOperations.paste(sources: [root + "/a.md"], intoFolder: root + "/vault")
        }
        #expect(throws: FileExplorerFileOperations.TransferError.vaultReadOnly("vault")) {
            try FileExplorerFileOperations.move(sources: [root + "/a.md"], intoFolder: root + "/vault")
        }
        #expect(fm.fileExists(atPath: root + "/a.md"))
    }
}
