public import Foundation

/// Resolves which bree-managed Ghostty config file under Application Support is
/// active for a given bundle identifier.
///
/// TRANSITIONAL: faithful lift of the app-target config-path namespace cluster
/// the engine and ``GhosttyConfig`` recurse through. These stateless
/// bundle-id→URL transforms have no natural receiver type; modernization into
/// an instantiated, dependency-injected resolver is deferred to the engine lift.
public struct BreeGhosttyConfigPathResolver {
    /// The bundle identifier of the released app, used as the canonical config
    /// location when no bundle identifier is known.
    public static let releaseBundleIdentifier = BreeIdentity.breeBundleIdentifier

    public init() {}

    /// The path bree writes edits to: always `config.ghostty` under the active
    /// bundle's Application Support directory.
    public func editableConfigURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL
    ) -> URL {
        configDirectoryURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
        .appendingPathComponent("config.ghostty", isDirectory: false)
    }

    /// The currently active config URL if one exists on disk, otherwise the
    /// editable target that a first write should create.
    public func activeOrEditableConfigURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> URL {
        loadConfigURLs(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
        .first
        ?? editableConfigURL(
            currentBundleIdentifier: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory
        )
    }

    /// The ordered list of bree-managed config files to load, applying the
    /// release-channel fallback when the current bundle has none of its own.
    public func loadConfigURLs(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL,
        fileManager: FileManager = .default
    ) -> [URL] {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return preferredExistingConfigURLs(
                for: Self.releaseBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            )
        }

        let currentURLs = preferredExistingConfigURLs(
            for: currentBundleIdentifier,
            appSupportDirectory: appSupportDirectory,
            fileManager: fileManager
        )
        return currentURLs
    }

    /// The Application Support directory that holds the config files for a bundle.
    public func configDirectoryURL(
        currentBundleIdentifier: String?,
        appSupportDirectory: URL
    ) -> URL {
        guard let currentBundleIdentifier, !currentBundleIdentifier.isEmpty else {
            return appSupportDirectory.appendingPathComponent(directoryName(for: Self.releaseBundleIdentifier), isDirectory: true)
        }
        return appSupportDirectory.appendingPathComponent(directoryName(for: currentBundleIdentifier), isDirectory: true)
    }

    /// Config lives under the identity's own Application Support folder (`Bree`, `Bree Dev`).
    private func directoryName(for bundleIdentifier: String) -> String {
        BreeIdentity(bundleIdentifier: bundleIdentifier).applicationSupportDirectoryName
    }

    private func preferredExistingConfigURLs(
        for bundleIdentifier: String,
        appSupportDirectory: URL,
        fileManager: FileManager
    ) -> [URL] {
        let directory = appSupportDirectory.appendingPathComponent(directoryName(for: bundleIdentifier), isDirectory: true)
        let legacyConfig = directory.appendingPathComponent("config", isDirectory: false)
        let configGhostty = directory.appendingPathComponent("config.ghostty", isDirectory: false)
        if isNonEmptyConfigFile(configGhostty, fileManager: fileManager) {
            // Do not layer legacy config under config.ghostty. Older builds wrote
            // explicit dark colors there, which blocks appearance-driven themes.
            return [configGhostty]
        }
        if isNonEmptyConfigFile(legacyConfig, fileManager: fileManager) {
            return [legacyConfig]
        }
        return []
    }

    private func isNonEmptyConfigFile(_ url: URL, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }

        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            return isNonEmptySymlinkTarget(url, fileManager: fileManager)
        }

        return isNonEmptyRegularFile(url, fileManager: fileManager)
    }

    private func isNonEmptySymlinkTarget(_ url: URL, fileManager: FileManager) -> Bool {
        isNonEmptyRegularFile(url.resolvingSymlinksInPath(), fileManager: fileManager)
    }

    private func isNonEmptyRegularFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let type = attrs[.type] as? FileAttributeType,
              type == .typeRegular,
              let size = attrs[.size] as? NSNumber else {
            return false
        }
        return size.intValue > 0
    }
}
