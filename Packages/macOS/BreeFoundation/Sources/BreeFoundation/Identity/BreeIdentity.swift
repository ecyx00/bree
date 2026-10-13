public import Foundation

/// The running app identity (Bree or the tagged Bree dev build) and the
/// on-disk roots it owns.
///
/// Every path that used to hard-code a dot directory, an Application Support
/// folder, a CLI name or a defaults domain goes through this type. Bree has no
/// other identity: the released app uses ``Kind/bree``, every `com.bree.app.debug*`
/// build uses ``Kind/breeDev``, and anything else (a nil id, a test host) is ``Kind/bree``.
///
/// ```swift
/// let identity = BreeIdentity.current
/// let dir = identity.dotDirectory(homeDirectory: home) // ~/.bree for Bree
/// ```
public struct BreeIdentity: Sendable, Equatable {
    /// The identity family.
    public enum Kind: Sendable, Equatable {
        /// The released Bree app (`com.bree.app`).
        case bree
        /// Every tagged Bree dev build (`com.bree.app.debug.*`, notably `.bree`).
        case breeDev
    }

    /// Bundle id of the released Bree app.
    public static let breeBundleIdentifier = "com.bree.app"
    /// Bundle id of the tagged Bree dev build.
    public static let breeDevBundleIdentifier = "com.bree.app.debug.bree"
    /// Bundle id prefix shared by every tagged dev build.
    public static let breeDevBundleIdentifierPrefix = "com.bree.app.debug"

    /// The identity family.
    public let kind: Kind

    /// Maps a bundle id to an identity. Dev tags map to ``Kind/breeDev``; unknown or nil ids are ``Kind/bree``.
    ///
    /// - Parameter bundleIdentifier: The app bundle identifier, if any.
    public init(bundleIdentifier: String?) {
        let id = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id == Self.breeDevBundleIdentifierPrefix || id.hasPrefix(Self.breeDevBundleIdentifierPrefix + ".") {
            kind = .breeDev
        } else {
            kind = .bree
        }
    }

    /// Resolves the identity for the CLI and hook processes.
    ///
    /// `BREE_BUNDLE_ID` wins when set, then the app bundle that contains the
    /// CLI binary, then Bree.
    ///
    /// - Parameters:
    ///   - environment: The process environment.
    ///   - enclosingAppBundleIdentifier: Bundle id of the `.app` containing the CLI binary, if any.
    public static func forCLI(
        environment: [String: String],
        enclosingAppBundleIdentifier: String?
    ) -> BreeIdentity {
        if let envID = environment["BREE_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envID.isEmpty {
            return BreeIdentity(bundleIdentifier: envID)
        }
        return BreeIdentity(bundleIdentifier: enclosingAppBundleIdentifier)
    }

    /// The identity of this process.
    ///
    /// A process running from an app bundle uses its own bundle id and ignores
    /// `BREE_BUNDLE_ID`, which a parent shell could have leaked into it. A bare
    /// CLI uses ``forCLI(environment:enclosingAppBundleIdentifier:)``.
    public static let current: BreeIdentity = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return BreeIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
        }
        return forCLI(
            environment: ProcessInfo.processInfo.environment,
            enclosingAppBundleIdentifier: enclosingAppBundleIdentifier()
        )
    }()

    /// Bundle id of the `.app` that contains the running executable, if any.
    static func enclosingAppBundleIdentifier() -> String? {
        var url = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                return Bundle(url: url)?.bundleIdentifier
            }
        }
        return nil
    }

    /// Name of the dot directory under home (`.bree`, `.bree-dev`).
    public var dotDirectoryName: String {
        switch kind {
        case .bree: ".bree"
        case .breeDev: ".bree-dev"
        }
    }

    /// Folder name under `Application Support` (`Bree`, `Bree Dev`).
    public var applicationSupportDirectoryName: String {
        switch kind {
        case .bree: "Bree"
        case .breeDev: "Bree Dev"
        }
    }

    /// Product name shown to the user (window title, About, tooltips).
    public var appDisplayName: String {
        switch kind {
        case .bree: "Bree"
        case .breeDev: "Bree Dev"
        }
    }

    /// Folder name under `Caches` (`Bree`, `Bree Dev`).
    public var cachesDirectoryName: String { applicationSupportDirectoryName }

    /// Folder name under `~/.local/state` holding the socket and marker files
    /// (`bree`, `bree-dev`). The dev build's socket itself lives in `/tmp`.
    public var stateDirectoryName: String {
        switch kind {
        case .bree: "bree"
        case .breeDev: "bree-dev"
        }
    }

    /// Dot directory Bree owns on a remote SSH host (`$HOME/.bree`): the relay
    /// files, the `bin/bree` shim, the Codex wrapper and the staged daemon.
    ///
    /// One root for every Bree build, so the Go daemon (`breed-remote`) can hard-code
    /// the same name.
    public static let remoteDotDirectoryName = ".bree"

    /// Prefix for fixed-name temporary directories and files (`bree`, `bree-dev`),
    /// so two builds running as the same user never share a temp path.
    public var tempNamePrefix: String {
        switch kind {
        case .bree: "bree"
        case .breeDev: "bree-dev"
        }
    }

    /// File name of the stable control socket inside the state directory.
    public var socketFileName: String {
        "bree.sock"
    }

    /// Name under which "Install CLI" links the bundled CLI into `/usr/local/bin`.
    public var cliInstallName: String {
        "bree"
    }

    /// UserDefaults domain the CLI reads app settings from.
    public var defaultsDomain: String {
        switch kind {
        case .bree: Self.breeBundleIdentifier
        case .breeDev: Self.breeDevBundleIdentifier
        }
    }

    /// Prefix for keychain service names and cross-process notification ids.
    public var reverseDNSPrefix: String {
        kind == .bree ? "com.bree" : "com.bree.dev"
    }

    /// `~/.bree` / `~/.bree-dev`.
    public func dotDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(dotDirectoryName, isDirectory: true)
    }

    /// The identity folder inside an Application Support base directory.
    public func applicationSupportDirectory(in base: URL) -> URL {
        base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
    }

    /// The identity folder inside a Caches base directory.
    public func cachesDirectory(in base: URL) -> URL {
        base.appendingPathComponent(cachesDirectoryName, isDirectory: true)
    }

    /// `~/.local/state/<name>` for this identity.
    public func stateDirectory(homeDirectory: URL) -> URL {
        homeDirectory
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("state", isDirectory: true)
            .appendingPathComponent(stateDirectoryName, isDirectory: true)
    }

    /// `~`-prefixed display/expansion form of the dot directory, e.g. `~/.bree`.
    public var dotDirectoryTildePath: String { "~/\(dotDirectoryName)" }
}
