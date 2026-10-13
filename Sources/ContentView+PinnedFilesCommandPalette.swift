import AppKit
import BreeCommandPalette
import Foundation

extension ContentView {
    static let openPinnedFileCommandId = "palette.openPinnedFile"

    static func commandPalettePinnedFilesContributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: openPinnedFileCommandId,
                title: { _ in String(localized: "command.openPinnedFile.title", defaultValue: "Open Pinned File…") },
                subtitle: { _ in String(localized: "command.openPinnedFile.subtitle", defaultValue: "Files") },
                keywords: ["pinned", "pin", "file", "files", "plan", "tasks", "docs", "open", "project"]
            ),
        ]
    }

    func registerPinnedFilesCommandPaletteHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: Self.openPinnedFileCommandId) {
            guard let workspace = tabManager.selectedWorkspace else {
                NSSound.beep()
                return
            }
            let window = observedWindow
            // After the palette is gone, so the menu is not dismissed with it.
            DispatchQueue.main.async {
                PinnedFilesMenu.present(for: workspace, in: window)
            }
        }
    }
}
