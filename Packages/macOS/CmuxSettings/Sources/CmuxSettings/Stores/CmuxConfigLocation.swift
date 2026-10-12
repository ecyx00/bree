import CmuxFoundation
import Foundation

/// Conventional on-disk locations for the JSON config of the running identity
/// (`~/.config/bree/bree.json` for Bree, `~/.config/cmux/cmux.json` for cmux).
///
/// A small value-typed bundle of URLs. Construct one with an explicit `home`
/// directory and inject it into the parts of the app that need to know where
/// the config file lives. No shared singletons; tests use a custom `home` URL
/// pointing into a temp directory.
///
/// ```swift
/// let locations = CmuxConfigLocation()
/// let store = JSONConfigStore(fileURL: locations.userConfigFile)
/// ```
public struct CmuxConfigLocation: Sendable, Hashable {
    /// The primary config file: `<home>/.config/<identity>/<identity>.json`.
    public let userConfigFile: URL

    /// The legacy fallback: `settings.json` next to the primary file. The app's
    /// settings reader checks this when the primary file is absent.
    public let legacyFallbackFile: URL

    /// Creates a location bundle anchored at the given home directory.
    ///
    /// - Parameter home: The home directory to anchor paths to. Defaults to
    ///   `FileManager.default.homeDirectoryForCurrentUser`. Pass a temp URL
    ///   in tests.
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.init(home: home, identity: .current, migrating: true)
    }

    /// Creates a location bundle for an explicit identity. Production code uses
    /// ``init(home:)``; tests pass a Bree identity and `migrating: false`.
    ///
    /// - Parameters:
    ///   - home: The home directory to anchor paths to.
    ///   - identity: The identity whose config folder is used.
    ///   - migrating: Seed the identity's file once from the cmux file when missing.
    public init(home: URL, identity: CmuxIdentity, migrating: Bool = false) {
        if migrating, identity == .current {
            self.userConfigFile = CmuxConfigMigration.currentGlobalConfigFile(homeDirectory: home)
        } else {
            self.userConfigFile = identity.configFile(homeDirectory: home)
        }
        self.legacyFallbackFile = identity.legacySettingsFile(homeDirectory: home)
    }
}
