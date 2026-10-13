import AppKit
import BreeWorkspaces
import BreeFoundation
import Foundation

/// Opens workspace-group configuration surfaces.
enum SidebarWorkspaceGroupConfigOpener {
    /// Opens the bree config file (`~/.config/bree/bree.json`) in the user's
    /// configured editor, materializing an empty config first if none exists.
    @MainActor
    static func openBreeConfigInEditor() {
        let opener = PreferredEditorService(defaults: .standard)
        openBreeConfigInEditor(
            home: FileManager.default.homeDirectoryForCurrentUser,
            open: { opener.open($0) }
        )
    }

    /// Testable seam: resolves the bree config path under `home`, materializes
    /// an empty config if absent, then hands the file to `open`.
    ///
    /// The public ``openBreeConfigInEditor()`` entry point passes
    /// `PreferredEditorService.open` so the config file honors
    /// `preferredEditorCommand` (with an OS-default fallback). Tests inject a
    /// capturing closure to assert the config file is routed through `open`.
    static func openBreeConfigInEditor(home: URL, open: (URL) -> Void) {
        open(materializedBreeConfigURL(home: home))
    }

    /// Resolves `~/.config/bree/bree.json` under `home`, materializing an empty
    /// config first if none exists. Shared by the external-editor path above and
    /// in-app openers (e.g. the plus-button menu's "Customize Workspace Layouts…").
    static func materializedBreeConfigURL(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let configURL = BreeIdentity.currentGlobalConfigFile(homeDirectory: home)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            try? FileManager.default.createDirectory(
                at: configURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try? Data("{}\n".utf8).write(to: configURL, options: .atomic)
            // The config later holds saved actions (commands, URLs, env
            // values); keep it owner-only from the start.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: configURL.path
            )
        }
        return configURL
    }
}
