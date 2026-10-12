public import Foundation

/// Where each identity keeps its own JSON config.
///
/// Bree and the tagged Bree dev build own `~/.config/bree/bree.json` and
/// `~/.config/bree-dev/bree.json`; project-local config is `.bree/bree.json`.
/// The cmux identity keeps the historical `~/.config/cmux/cmux.json` and
/// `.cmux/cmux.json`. Bree never writes under `~/.config/cmux` (see
/// ``CmuxConfigMigration``); it reads `.cmux/cmux.json` of a repository only as
/// a read-only fallback.
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

    /// The shared cmux config file. Bree reads it once to seed its own file and never writes it.
    public static func cmuxConfigFile(homeDirectory: URL) -> URL {
        CmuxIdentity(bundleIdentifier: cmuxBundleIdentifier).configFile(homeDirectory: homeDirectory)
    }

    /// `~/.config/bree/bree.json` style path for display.
    public var configFileDisplayPath: String { "~/.config/\(configDirectoryName)/\(configFileName)" }

    /// `.bree/bree.json` style path for display.
    public var projectConfigDisplayPath: String { "\(projectDirectoryName)/\(configFileName)" }

    /// Project config candidates inside one directory, most specific first.
    ///
    /// Bree identities list their own files first, then the read-only cmux
    /// fallbacks (`.cmux/cmux.json`, `cmux.json`) that repositories may still carry.
    public func projectConfigCandidates(in directory: String) -> [String] {
        func join(_ parts: String...) -> String {
            parts.reduce(directory) { ($0 as NSString).appendingPathComponent($1) }
        }
        var result: [String] = []
        if kind != .cmux {
            result.append(join(projectDirectoryName, configFileName))
            result.append(join(configFileName))
        }
        result.append(join(".cmux", "cmux.json"))
        result.append(join("cmux.json"))
        return result
    }

    /// Whether `name` is a global or project config file name of this identity,
    /// including the read-only cmux fallback name.
    public func isConfigFileName(_ name: String) -> Bool {
        name == configFileName || name == "cmux.json"
    }

    /// Whether a directory name is a hidden project config folder (`.bree` or `.cmux`).
    public static func isProjectDirectoryName(_ name: String) -> Bool {
        name == ".bree" || name == ".cmux"
    }
}

/// One-time seeding of Bree's own config file from the shared cmux file.
///
/// If the identity's file does not exist and `~/.config/cmux/cmux.json` does,
/// the cmux file is read and its bytes are written to the identity's file once.
/// Nothing under `~/.config/cmux` is ever written, moved or watched by this
/// code. After the copy the two files are independent.
public enum CmuxConfigMigration {
    /// What ``migrateIfNeeded(identity:homeDirectory:fileManager:)`` did.
    public enum Outcome: Sendable, Equatable {
        /// The cmux identity keeps using the shared file.
        case notApplicable
        /// The identity's own file already exists.
        case alreadyPresent
        /// There was no cmux file to copy.
        case noLegacyFile
        /// The cmux file was copied.
        case copied
        /// Reading the cmux file or writing the new one failed.
        case failed
    }

    /// Copies the cmux config to the identity's own file when that file is missing.
    ///
    /// - Parameters:
    ///   - identity: The running identity.
    ///   - homeDirectory: The home directory to anchor paths to.
    ///   - fileManager: File manager used for existence checks and directory creation.
    public static func migrateIfNeeded(
        identity: CmuxIdentity,
        homeDirectory: URL,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard identity.kind != .cmux else { return .notApplicable }
        let target = identity.configFile(homeDirectory: homeDirectory)
        if fileManager.fileExists(atPath: target.path) { return .alreadyPresent }
        let legacy = CmuxIdentity.cmuxConfigFile(homeDirectory: homeDirectory)
        guard fileManager.fileExists(atPath: legacy.path) else { return .noLegacyFile }
        do {
            let data = try Data(contentsOf: legacy)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: target, options: [.atomic])
            return .copied
        } catch {
            return .failed
        }
    }

    private final class Once: @unchecked Sendable {
        let lock = NSLock()
        var done = Set<String>()
    }
    private static let once = Once()

    /// The global config path of the running identity, seeding it first (at most once per process and home).
    public static func currentGlobalConfigFile(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let identity = CmuxIdentity.current
        once.lock.lock()
        let first = once.done.insert(homeDirectory.path).inserted
        once.lock.unlock()
        if first { _ = migrateIfNeeded(identity: identity, homeDirectory: homeDirectory) }
        return identity.configFile(homeDirectory: homeDirectory)
    }
}
