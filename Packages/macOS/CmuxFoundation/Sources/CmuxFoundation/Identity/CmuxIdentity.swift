public import Foundation

/// The running app identity (cmux, Bree, or the tagged Bree dev build) and the
/// on-disk roots it owns.
///
/// Every path that used to hard-code `~/.cmuxterm`, `Application Support/cmux`,
/// `~/.local/state/cmux`, a CLI name or a defaults domain goes through this
/// type, so Bree and cmux can run side by side without sharing state. Any
/// identity other than the two Bree bundle ids resolves to ``Kind/cmux`` and
/// returns the historical cmux values unchanged.
///
/// ```swift
/// let identity = CmuxIdentity.current
/// let dir = identity.dotDirectory(homeDirectory: home) // ~/.bree for Bree
/// ```
public struct CmuxIdentity: Sendable, Equatable {
    /// The identity family.
    public enum Kind: Sendable, Equatable {
        /// cmux and every non-Bree bundle id (stable, nightly, other debug tags).
        case cmux
        /// The released Bree app (`com.bree.app`).
        case bree
        /// The tagged Bree dev build (`com.cmuxterm.app.debug.bree`).
        case breeDev
    }

    /// Bundle id of the released Bree app.
    public static let breeBundleIdentifier = "com.bree.app"
    /// Bundle id of the tagged Bree dev build.
    public static let breeDevBundleIdentifier = "com.cmuxterm.app.debug.bree"
    /// Bundle id of the stable cmux release.
    public static let cmuxBundleIdentifier = "com.cmuxterm.app"

    /// The identity family.
    public let kind: Kind

    /// Maps a bundle id to an identity. Matching is exact; unknown or nil ids are cmux.
    ///
    /// - Parameter bundleIdentifier: The app bundle identifier, if any.
    public init(bundleIdentifier: String?) {
        switch bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case Self.breeBundleIdentifier: kind = .bree
        case Self.breeDevBundleIdentifier: kind = .breeDev
        default: kind = .cmux
        }
    }

    /// Resolves the identity for the CLI and hook processes.
    ///
    /// `CMUX_BUNDLE_ID` wins when set, then the app bundle that contains the
    /// CLI binary, then cmux.
    ///
    /// - Parameters:
    ///   - environment: The process environment.
    ///   - enclosingAppBundleIdentifier: Bundle id of the `.app` containing the CLI binary, if any.
    public static func forCLI(
        environment: [String: String],
        enclosingAppBundleIdentifier: String?
    ) -> CmuxIdentity {
        if let envID = environment["CMUX_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envID.isEmpty {
            return CmuxIdentity(bundleIdentifier: envID)
        }
        return CmuxIdentity(bundleIdentifier: enclosingAppBundleIdentifier)
    }

    /// The identity of this process.
    ///
    /// A process running from an app bundle uses its own bundle id and ignores
    /// `CMUX_BUNDLE_ID`, which a cmux shell could have leaked into it. A bare
    /// CLI uses ``forCLI(environment:enclosingAppBundleIdentifier:)``.
    public static let current: CmuxIdentity = {
        if Bundle.main.bundleURL.pathExtension == "app" {
            return CmuxIdentity(bundleIdentifier: Bundle.main.bundleIdentifier)
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

    /// Name of the dot directory under home (`.cmuxterm`, `.bree`, `.bree-dev`).
    public var dotDirectoryName: String {
        switch kind {
        case .cmux: ".cmuxterm"
        case .bree: ".bree"
        case .breeDev: ".bree-dev"
        }
    }

    /// Folder name under `Application Support` (`cmux`, `Bree`, `Bree Dev`).
    public var applicationSupportDirectoryName: String {
        switch kind {
        case .cmux: "cmux"
        case .bree: "Bree"
        case .breeDev: "Bree Dev"
        }
    }

    /// Product name shown to the user (window title, About, tooltips).
    public var appDisplayName: String {
        switch kind {
        case .cmux: "cmux"
        case .bree: "Bree"
        case .breeDev: "Bree Dev"
        }
    }

    /// Folder name under `Caches` (`cmux`, `Bree`, `Bree Dev`).
    public var cachesDirectoryName: String { applicationSupportDirectoryName }

    /// Folder name under `~/.local/state` holding the socket and marker files
    /// (`cmux`, `bree`, `bree-dev`). The dev build's socket itself lives in `/tmp`.
    public var stateDirectoryName: String {
        switch kind {
        case .cmux: "cmux"
        case .bree: "bree"
        case .breeDev: "bree-dev"
        }
    }

    /// Dot directory Bree owns on a remote SSH host (`$HOME/.bree`): the relay
    /// files, the `bin/cmux` shim, the Codex wrapper and the staged daemon.
    ///
    /// One root for every Bree build, so the Go daemon (`cmuxd-remote`) can hard-code
    /// the same name. It never equals cmux's `.cmux`, so Bree and cmux.app can
    /// share a host without overwriting each other's files.
    public static let remoteDotDirectoryName = ".bree"

    /// Prefix for fixed-name temporary directories and files (`cmux`, `bree`, `bree-dev`),
    /// so two apps running as the same user never share a temp path.
    public var tempNamePrefix: String {
        switch kind {
        case .cmux: "cmux"
        case .bree: "bree"
        case .breeDev: "bree-dev"
        }
    }

    /// File name of the stable control socket inside the state directory.
    public var socketFileName: String {
        kind == .bree ? "bree.sock" : "cmux.sock"
    }

    /// Name under which "Install CLI" links the bundled CLI into `/usr/local/bin`.
    public var cliInstallName: String {
        kind == .cmux ? "cmux" : "bree"
    }

    /// UserDefaults domain the CLI reads app settings from.
    public var defaultsDomain: String {
        switch kind {
        case .cmux: Self.cmuxBundleIdentifier
        case .bree: Self.breeBundleIdentifier
        case .breeDev: Self.breeDevBundleIdentifier
        }
    }

    /// Prefix for keychain service names and cross-process notification ids.
    public var reverseDNSPrefix: String {
        kind == .bree ? "com.bree" : "com.cmuxterm"
    }

    /// `~/.cmuxterm` / `~/.bree` / `~/.bree-dev`.
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
