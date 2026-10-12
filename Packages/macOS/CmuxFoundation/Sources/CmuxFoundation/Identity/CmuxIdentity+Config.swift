public import Foundation

/// Where each identity keeps its own JSON config.
///
/// Bree and the tagged Bree dev build own `~/.config/bree/bree.json` and
/// `~/.config/bree-dev/bree.json`; project-local config is `.bree/bree.json`.
/// The cmux identity keeps the historical `~/.config/cmux/cmux.json` and
/// `.cmux/cmux.json`. Bree never reads, writes, copies or watches
/// `~/.config/cmux` or a repository's `.cmux` folder.
extension CmuxIdentity {
    /// Folder under `~/.config` (`cmux`, `bree`, `bree-dev`).
    public var configDirectoryName: String {
        switch kind {
        case .cmux: "cmux"
        case .bree: "bree"
        case .breeDev: "bree-dev"
        }
    }

    /// Global config file name (`cmux.json` or `bree.json`).
    public var configFileName: String { kind == .cmux ? "cmux.json" : "bree.json" }

    /// Hidden project folder (`.cmux` or `.bree`).
    public var projectDirectoryName: String { kind == .cmux ? ".cmux" : ".bree" }

    /// `<home>/.config/<configDirectoryName>`.
    public func configDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent(configDirectoryName, isDirectory: true)
    }

    /// The global config file of this identity.
    public func configFile(homeDirectory: URL) -> URL {
        configDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(configFileName, isDirectory: false)
    }

    /// The `settings.json` legacy fallback next to the global config file.
    public func legacySettingsFile(homeDirectory: URL) -> URL {
        configDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// The sidebars folder of this identity.
    public func sidebarsDirectory(homeDirectory: URL) -> URL {
        configDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("sidebars", isDirectory: true)
    }

    /// The global config path of the running identity. Bree never reads, copies or
    /// watches `~/.config/cmux`; its own file starts empty until the user writes it.
    public static func currentGlobalConfigFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        current.configFile(homeDirectory: homeDirectory)
    }

    /// `~/.config/bree/bree.json` style path for display.
    public var configFileDisplayPath: String { "~/.config/\(configDirectoryName)/\(configFileName)" }

    /// `.bree/bree.json` style path for display.
    public var projectConfigDisplayPath: String { "\(projectDirectoryName)/\(configFileName)" }

    /// Project config candidates inside one directory, most specific first.
    ///
    /// Each identity lists only its own files (`.bree/bree.json`, `bree.json`).
    public func projectConfigCandidates(in directory: String) -> [String] {
        func join(_ parts: String...) -> String {
            parts.reduce(directory) { ($0 as NSString).appendingPathComponent($1) }
        }
        return [join(projectDirectoryName, configFileName), join(configFileName)]
    }

    /// Whether `name` is a global or project config file name of this identity.
    public func isConfigFileName(_ name: String) -> Bool {
        name == configFileName
    }

    /// Whether a directory name is the hidden project config folder of the running identity.
    public static func isProjectDirectoryName(_ name: String) -> Bool {
        name == current.projectDirectoryName
    }
}
