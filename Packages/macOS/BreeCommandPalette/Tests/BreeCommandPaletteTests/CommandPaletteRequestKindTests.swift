import Foundation
import Testing

@testable import BreeCommandPalette

@Suite struct CommandPaletteRequestKindTests {
    @Test func notificationNamesMatchLegacyLiterals() {
        #expect(CommandPaletteRequestKind.commands.notificationName == "bree.commandPaletteRequested")
        #expect(CommandPaletteRequestKind.agentInbox.notificationName == "bree.agentInboxRequested")
        #expect(CommandPaletteRequestKind.switcher.notificationName == "bree.commandPaletteSwitcherRequested")
        #expect(CommandPaletteRequestKind.renameTab.notificationName == "bree.commandPaletteRenameTabRequested")
        #expect(CommandPaletteRequestKind.renameWorkspace.notificationName == "bree.commandPaletteRenameWorkspaceRequested")
        #expect(
            CommandPaletteRequestKind.editWorkspaceDescription.notificationName
                == "bree.commandPaletteEditWorkspaceDescriptionRequested"
        )
        #expect(CommandPaletteRequestKind.rename.notificationName == "bree.commandPaletteRenameRequested")
    }

    @Test func everyKindMarksPending() {
        for kind in CommandPaletteRequestKind.allCases {
            #expect(kind.marksPending)
        }
    }

    @Test func notificationNamesAreDistinct() {
        let names = Set(CommandPaletteRequestKind.allCases.map(\.notificationName))
        #expect(names.count == CommandPaletteRequestKind.allCases.count)
    }
}
