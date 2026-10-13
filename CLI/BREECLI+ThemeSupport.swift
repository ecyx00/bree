import Foundation
import BreeFoundation

extension BREECLI {
    func availableThemeNames() -> [String] {
        GhosttyThemeCatalog(directories: themeDirectoryURLs()).entries().map(\.name)
    }

    func themeDirectoryURLs() -> [URL] {
        GhosttyThemeDirectories(
            environment: ProcessInfo.processInfo.environment,
            bundledThemeDirectories: bundledThemeDirectoryURLs()
        ).urls
    }

    /// Theme directories inside this CLI's app bundle, or the repo checkout
    /// when running a development build.
    private func bundledThemeDirectoryURLs() -> [URL] {
        let fileManager = FileManager.default
        var urls: [URL] = []
        if let resourceURL = Bundle.main.resourceURL {
            urls.append(resourceURL.appendingPathComponent("ghostty/themes", isDirectory: true))
        }
        guard let executableURL = resolvedExecutableURL() else { return urls }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.lastPathComponent == "Resources" {
                urls.append(current.appendingPathComponent("ghostty/themes", isDirectory: true))
            }
            if current.lastPathComponent == "Contents" {
                urls.append(current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true))
            }

            let projectMarker = current.appendingPathComponent("bree.xcodeproj/project.pbxproj", isDirectory: false)
            let repoThemes = current.appendingPathComponent("Resources/ghostty/themes", isDirectory: true)
            if fileManager.fileExists(atPath: projectMarker.path),
               fileManager.fileExists(atPath: repoThemes.path) {
                urls.append(repoThemes)
                break
            }

            guard let parent = parentSearchURL(for: current) else { break }
            current = parent
        }
        return urls
    }

    func validatedThemeName(_ rawValue: String, availableThemes: [String]) throws -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CLIError(message: "Theme name cannot be empty")
        }
        if let matched = availableThemes.first(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return matched
        }
        if availableThemes.isEmpty {
            return trimmed
        }
        throw CLIError(message: "Unknown theme '\(trimmed)'. Run 'bree themes' to list available themes.")
    }

    func themeConfigSearchURLs(targetBundleIdentifier: String) -> [URL] {
        let fileManager = FileManager.default
        var urls = [
            configURL("~/.config/ghostty/config"),
            configURL("~/.config/ghostty/config.ghostty"),
        ]
        var seen = Set(urls.map { $0.standardizedFileURL.path })

        func append(_ url: URL) {
            let standardized = url.standardizedFileURL
            if seen.insert(standardized.path).inserted {
                urls.append(standardized)
            }
        }

        for appSupportDirectory in BreeApplicationSupportDirectories(
            environment: ProcessInfo.processInfo.environment
        ).userDirectories {
            let ghosttyDirectory = appSupportDirectory.appendingPathComponent(
                "com.mitchellh.ghostty",
                isDirectory: true
            )
            let legacyGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config", isDirectory: false)
            let currentGhosttyConfigURL = ghosttyDirectory.appendingPathComponent("config.ghostty", isDirectory: false)

            append(currentGhosttyConfigURL)
            if shouldLoadLegacyGhosttyConfig(
                newConfigURL: currentGhosttyConfigURL,
                legacyConfigURL: legacyGhosttyConfigURL,
                fileManager: fileManager
            ) {
                append(legacyGhosttyConfigURL)
            }

            for url in BreeGhosttyConfigPathResolver().loadConfigURLs(
                currentBundleIdentifier: targetBundleIdentifier,
                appSupportDirectory: appSupportDirectory,
                fileManager: fileManager
            ) {
                append(url)
            }
        }

        return urls
    }

    private func configURL(_ rawPath: String) -> URL {
        homeExpandedURL(rawPath, isDirectory: false)
    }

    private func homeExpandedURL(_ rawPath: String, isDirectory: Bool) -> URL {
        if rawPath.hasPrefix("~/"),
           let home = ProcessInfo.processInfo.environment["HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !home.isEmpty {
            let relativePath = String(rawPath.dropFirst(2))
            return URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(relativePath, isDirectory: isDirectory)
        }
        return URL(fileURLWithPath: NSString(string: rawPath).expandingTildeInPath, isDirectory: isDirectory)
    }

    private func shouldLoadLegacyGhosttyConfig(
        newConfigURL: URL,
        legacyConfigURL: URL,
        fileManager: FileManager
    ) -> Bool {
        guard let newConfigFileSize = configFileSize(at: newConfigURL, fileManager: fileManager),
              newConfigFileSize == 0 else { return false }
        guard let legacyConfigFileSize = configFileSize(at: legacyConfigURL, fileManager: fileManager),
              legacyConfigFileSize > 0 else { return false }
        return true
    }

    private func configFileSize(at url: URL, fileManager: FileManager) -> Int? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    func lastThemeDirective(in contents: String) -> String? {
        var lastValue: String?

        for line in contents.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                continue
            }

            let parts = trimmed.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            guard parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == "theme" else { continue }

            let value = parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !value.isEmpty {
                lastValue = value
            }
        }

        return lastValue
    }

    func breeThemeOverrideConfigURL(targetBundleIdentifier: String) throws -> URL {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CLIError(message: "Failed to locate the Application Support directory")
        }
        return BreeGhosttyConfigPathResolver().editableConfigURL(
            currentBundleIdentifier: targetBundleIdentifier,
            appSupportDirectory: appSupport
        )
    }

    func writeManagedThemeOverride(
        rawThemeValue: String,
        targetBundleIdentifier: String
    ) throws -> URL {
        let configURL = try breeThemeOverrideConfigURL(targetBundleIdentifier: targetBundleIdentifier)
        try BreeManagedThemeConfigFile(url: configURL).write(rawThemeValue: rawThemeValue)
        return configURL
    }

    func clearManagedThemeOverride(targetBundleIdentifier: String) throws -> URL {
        let configURL = try breeThemeOverrideConfigURL(targetBundleIdentifier: targetBundleIdentifier)
        try BreeManagedThemeConfigFile(url: configURL).clear()
        return configURL
    }

    func reloadThemesIfPossible(
        socketPath: String,
        targetBundleIdentifier: String,
        explicitPassword _: String?
    ) -> ThemeReloadStatus {
        DistributedNotificationCenter.default().post(
            name: Notification.Name(Self.breeThemesReloadNotificationName),
            object: nil,
            userInfo: [
                "bundleIdentifier": targetBundleIdentifier,
                "socketPath": socketPath,
                "phase": "final",
            ]
        )
        return ThemeReloadStatus(requested: true, targetBundleIdentifier: targetBundleIdentifier)
    }

    func themeTargetBundleIdentifier(socketPath: String) -> String {
        bundleIdentifierForThemeReloadSocketPath(socketPath)
            ?? currentBreeAppBundleIdentifier()
            ?? BreeIdentity.current.defaultsDomain
    }

    private func bundleIdentifierForThemeReloadSocketPath(_ socketPath: String) -> String? {
        let name = URL(fileURLWithPath: socketPath).lastPathComponent
        switch name {
        // identity-lint: allow legacy shared socket path kept for reading/cleanup of bree.app sockets, never created by Bree
        case "bree.sock":
            return Self.breeThemeOverrideBundleIdentifier
        case "bree.sock":
            return BreeIdentity.breeBundleIdentifier
        case "bree-debug.sock":
            return "com.bree.app.debug"
        case "bree-nightly.sock":
            return "com.bree.app.nightly"
        case "bree-rc.sock":
            return "com.bree.app.rc"
        case "bree-staging.sock":
            return "com.bree.app.staging"
        default:
            break
        }

        if name.range(of: #"^bree-\d+\.sock$"#, options: .regularExpression) != nil {
            return Self.breeThemeOverrideBundleIdentifier
        }

        if let slug = themeReloadSocketSlug(name, prefix: "bree-debug-", suffix: ".sock") {
            return "com.bree.app.debug.\(slug)"
        }
        if let slug = themeReloadSocketSlug(name, prefix: "bree-nightly-", suffix: ".sock") {
            return "com.bree.app.nightly.\(slug)"
        }
        if let slug = themeReloadSocketSlug(name, prefix: "bree-rc-", suffix: ".sock") {
            return "com.bree.app.rc.\(slug)"
        }
        if let slug = themeReloadSocketSlug(name, prefix: "bree-staging-", suffix: ".sock") {
            return "com.bree.app.staging.\(slug)"
        }
        return nil
    }

    private func themeReloadSocketSlug(_ name: String, prefix: String, suffix: String) -> String? {
        guard name.hasPrefix(prefix), name.hasSuffix(suffix) else {
            return nil
        }
        let start = name.index(name.startIndex, offsetBy: prefix.count)
        let end = name.index(name.endIndex, offsetBy: -suffix.count)
        let rawSlug = String(name[start..<end])
        let bundleSlug = rawSlug
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return bundleSlug.isEmpty ? nil : bundleSlug
    }

    func currentBreeAppBundleIdentifier() -> String? {
        if let bundleIdentifier = ProcessInfo.processInfo.environment["BREE_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        if let bundleIdentifier = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        guard let executableURL = resolvedExecutableURL() else {
            return nil
        }

        var current = executableURL.deletingLastPathComponent().standardizedFileURL
        while true {
            if current.pathExtension == "app",
               let bundleIdentifier = Bundle(url: current)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !bundleIdentifier.isEmpty {
                return bundleIdentifier
            }

            if current.lastPathComponent == "Contents" {
                let appURL = current.deletingLastPathComponent().standardizedFileURL
                if appURL.pathExtension == "app",
                   let bundleIdentifier = Bundle(url: appURL)?.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleIdentifier.isEmpty {
                    return bundleIdentifier
                }
            }

            guard let parent = parentSearchURL(for: current) else {
                break
            }
            current = parent
        }

        return nil
    }

    func isRightSidebarCLIMode(_ value: String) -> Bool {
        switch value.lowercased() {
        case "files", "vault", "sessions", "activity", "architecture", "custom", "custom-sidebar":
            return true
        default:
            return false
        }
    }

    func normalizedRightSidebarCLIArgument(_ value: String) -> String {
        switch value.lowercased() {
        case "files", "vault", "sessions", "activity", "architecture", "custom", "custom-sidebar":
            return value.lowercased()
        default:
            return value
        }
    }
}
