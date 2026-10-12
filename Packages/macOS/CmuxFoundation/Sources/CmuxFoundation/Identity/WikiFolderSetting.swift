public import Foundation

/// Where the global Wiki folder lives: the one the user picks in Settings > Wiki, else `<Bree home>/wiki`
/// (`~/.bree/wiki`, `~/.bree-dev/wiki`; never a hard-coded path). Shared by the Settings pane and the Wiki popover.
public enum WikiFolderSetting {
    /// UserDefaults key holding the picked folder (absolute path or `~/...`). Absent or empty: the default.
    public static let defaultsKey = "wiki.folder"

    /// `<Bree home>/wiki` for `identity`.
    public static func defaultFolder(
        identity: CmuxIdentity = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        identity.dotDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("wiki", isDirectory: true).path
    }

    /// The picked folder, else the default. Always an absolute path without a trailing slash.
    public static func resolved(
        defaults: UserDefaults = .standard,
        identity: CmuxIdentity = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let picked = defaults.string(forKey: defaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !picked.isEmpty else { return defaultFolder(identity: identity, homeDirectory: homeDirectory) }
        var path = (picked as NSString).expandingTildeInPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
