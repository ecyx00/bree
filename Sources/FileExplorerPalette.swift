import AppKit
import BreeFoundation

/// Files-tree colours, read from the Bree chrome palette.
///
/// Each colour is a named dynamic `NSColor` that picks one palette role when it
/// resolves, so the shared instances stay identical across calls while following
/// palette changes. `FileExplorerContainerView` reloads on
/// `BreeChromePaletteStore.didChangeNotification` so cached bitmaps (icon tints)
/// are rebuilt.
struct FileExplorerPalette {
    let fileIconTint: NSColor
    let folderIconTint: NSColor
    private let modifiedText: NSColor
    private let addedText: NSColor
    private let deletedText: NSColor
    private let renamedText: NSColor
    private let untrackedText: NSColor

    func gitColor(for status: GitFileStatus) -> NSColor {
        switch status {
        case .modified: modifiedText
        case .added: addedText
        case .deleted: deletedText
        case .renamed: renamedText
        case .untracked: untrackedText
        }
    }

    /// All five explorer styles share the Bree palette; they differ only in
    /// metrics (row height, indentation, icon size).
    static let bree = FileExplorerPalette(
        fileIconTint: role("icon.file", \.textSecondary),
        folderIconTint: role("icon.folder", \.textSecondary),
        modifiedText: role("status.modified", \.textSecondary),
        addedText: role("status.added", \.signalSuccess),
        deletedText: role("status.deleted", \.signalError),
        renamedText: role("status.renamed", \.textSecondary),
        untrackedText: role("status.untracked", \.textSecondary)
    )

    static let selectedFill = role("selectedFill", \.selectedFill)
    static let selectedQuiet = role("selectedQuiet", \.selectedQuiet)
    static let hoverFill = role("hoverFill", \.hoverFill)
    static let textPrimary = role("textPrimary", \.textPrimary)
    static let textSecondary = role("textSecondary", \.textSecondary)
    static let activeIndicator = role("activeIndicator", \.activeIndicator)
    static let signalError = role("signalError", \.signalError)

    private static func role(
        _ name: String,
        _ pick: @escaping @Sendable (BreeChromePalette.AppKitColors) -> NSColor
    ) -> NSColor {
        NSColor(name: NSColor.Name("bree.fileExplorer.\(name)")) { _ in
            pick(currentPalette().ns)
        }
    }

    /// Dynamic colour providers can run off the main thread; the snapshot is lock-protected.
    private static func currentPalette() -> BreeChromePalette {
        BreeChromePalette.currentSnapshot
    }
}
