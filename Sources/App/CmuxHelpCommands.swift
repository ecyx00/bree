import AppKit
import SwiftUI

extension cmuxApp {
    @CommandsBuilder
    var helpCommands: some Commands {
        CommandGroup(replacing: .help) {
            splitCommandButton(
                title: String(localized: "menu.help.keyboardShortcuts", defaultValue: "Keyboard Shortcuts…"),
                shortcut: menuShortcut(for: .showKeyboardShortcuts)
            ) {
                KeyboardShortcutsCheatSheetController.shared.show()
            }
            Button(String(localized: "menu.help.keyboardShortcutsSettings", defaultValue: "Keyboard Shortcuts Settings…")) {
                openKeyboardShortcutsFromHelpMenu()
            }
        }
    }

    private func openKeyboardShortcutsFromHelpMenu() {
        if let appDelegate = AppDelegate.shared {
            appDelegate.openPreferencesWindow(
                debugSource: "helpMenu.keyboardShortcuts",
                navigationTarget: .keyboardShortcuts
            )
        } else {
            AppDelegate.presentPreferencesWindow(navigationTarget: .keyboardShortcuts)
        }
    }
}
