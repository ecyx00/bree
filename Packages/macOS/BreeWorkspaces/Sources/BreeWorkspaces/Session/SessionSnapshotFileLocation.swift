public import Foundation
public import BreeFoundation

/// Where a bree install keeps its session snapshot files.
///
/// Every install (stable, nightly, rc, staging, tagged debug builds) writes
/// `Application Support/bree/session-<bundleId>.json` plus a
/// `session-<bundleId>-previous.json` manual-restore backup. Keying the file
/// on the bundle identifier keeps channels from clobbering each other; this
/// type lets one install locate another install's files so a session can be
/// moved between channels (`bree restore-session --from nightly`).
public struct SessionSnapshotFileLocation: Sendable, Equatable {
    /// The released app's bundle identifier, also the fallback when the
    /// running bundle has none.
    public static let stableBundleIdentifier = BreeIdentity.breeBundleIdentifier

    /// Maps a release channel name to its bundle identifier.
    ///
    /// Accepts `stable` (alias `release`), `nightly`, `rc`, `staging`,
    /// `debug` (the untagged Debug build), and `debug:<tag>` / `dev:<tag>`
    /// for tagged Debug builds. The tag is normalized the way
    /// `scripts/reload.sh --tag` builds the bundle id (lowercased, every run
    /// of other characters becomes `.`), so `debug:My-Tag` is
    /// `com.bree.app.debug.my.tag`. A value that already is a bree bundle
    /// identifier (`com.bree.app…`) is returned unchanged. Names are
    /// case-insensitive; returns nil for anything else.
    ///
    /// - Parameter name: The channel name or bundle identifier.
    /// - Returns: The bundle identifier, or nil when `name` is not a channel.
    public static func bundleIdentifier(forChannel name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == stableBundleIdentifier || trimmed.hasPrefix(stableBundleIdentifier + ".") {
            return trimmed
        }
        let lowered = trimmed.lowercased()
        switch lowered {
        case "stable", "release":
            return stableBundleIdentifier
        case "nightly", "rc", "staging", "debug":
            return "\(stableBundleIdentifier).\(lowered)"
        default:
            break
        }
        for prefix in ["debug:", "dev:"] where lowered.hasPrefix(prefix) {
            let tag = String(lowered.dropFirst(prefix.count))
                .replacingOccurrences(of: "[^a-z0-9]+", with: ".", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !tag.isEmpty else { return nil }
            return "\(stableBundleIdentifier).debug.\(tag)"
        }
        return nil
    }

    /// The user's Application Support directory the `bree/` folder lives in.
    public let appSupportDirectory: URL

    /// Creates a location rooted at an Application Support directory.
    ///
    /// - Parameters:
    ///   - appSupportDirectory: The user's Application Support
    ///     directory (tests pass a temporary directory).
    ///   - identity: The running install's identity.
    /// The identity whose folder holds the snapshots (tests inject one).
    public let identity: BreeIdentity

    public init(appSupportDirectory: URL, identity: BreeIdentity = .current) {
        self.appSupportDirectory = appSupportDirectory
        self.identity = identity
    }

    /// The primary snapshot file for `bundleIdentifier`.
    ///
    /// - Parameter bundleIdentifier: The install's bundle identifier; nil or
    ///   blank falls back to ``stableBundleIdentifier``.
    /// - Returns: `<appSupport>/bree/session-<sanitized id>.json`.
    public func primaryFileURL(bundleIdentifier: String?) -> URL {
        fileURL(bundleIdentifier: bundleIdentifier, suffix: "")
    }

    /// The manual-restore backup snapshot file for `bundleIdentifier`.
    ///
    /// - Parameter bundleIdentifier: The install's bundle identifier; nil or
    ///   blank falls back to ``stableBundleIdentifier``.
    /// - Returns: `<appSupport>/bree/session-<sanitized id>-previous.json`.
    public func backupFileURL(bundleIdentifier: String?) -> URL {
        fileURL(bundleIdentifier: bundleIdentifier, suffix: "-previous")
    }

    /// The side file that keeps a snapshot written by a newer schema version,
    /// next to the file it was found in (`session-<id>.json` becomes
    /// `session-<id>.schema-v<N>.json`).
    ///
    /// - Parameters:
    ///   - fileURL: The snapshot file that holds the newer snapshot.
    ///   - schemaVersion: The newer snapshot's schema version.
    /// - Returns: The side file location.
    public static func newerSchemaSideFileURL(for fileURL: URL, schemaVersion: Int) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return directory.appendingPathComponent("\(baseName).schema-v\(schemaVersion).json", isDirectory: false)
    }

    /// `<appSupport>/<identity folder>/` (`Bree` or `Bree Dev`), the folder holding the snapshot files and the shared
    /// `session-history/` archive.
    public var breeDirectoryURL: URL {
        identity.applicationSupportDirectory(in: appSupportDirectory)
    }

    /// The file-name-safe form of `bundleIdentifier` used in snapshot and
    /// history file names; nil or blank falls back to
    /// ``stableBundleIdentifier``.
    static func safeBundleIdentifier(_ bundleIdentifier: String?) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bundleId = trimmed.isEmpty ? stableBundleIdentifier : bundleIdentifier!
        return bundleId.replacingOccurrences(
            of: "[^A-Za-z0-9._-]",
            with: "_",
            options: .regularExpression
        )
    }

    func fileURL(bundleIdentifier: String?, suffix: String) -> URL {
        let safeBundleId = Self.safeBundleIdentifier(bundleIdentifier)
        return breeDirectoryURL
            .appendingPathComponent("session-\(safeBundleId)\(suffix).json", isDirectory: false)
    }
}
