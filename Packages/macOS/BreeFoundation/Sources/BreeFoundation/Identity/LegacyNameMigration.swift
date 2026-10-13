public import Foundation

/// One-time copy of Bree's own persisted data from the names it used before the
/// rename away from cmux to the new names.
///
/// This is the only source file that may spell the old names (the zero-name lint
/// lists it explicitly). It copies, never moves, and never overwrites: an existing
/// new name wins, so running it twice is harmless. It touches only Bree's own
/// stores: the defaults domain of the running app, the dev build's previous
/// domain, and the roots owned by ``BreeIdentity`` (`~/.bree`, `Application Support/Bree`,
/// `~/.config/bree`, `~/.local/state/bree`, and their dev twins). It never reads
/// anything the cmux app owns.
///
/// Migrated names:
/// - UserDefaults keys that contain the old name (for example `cmux.session.lastWindowGeometry.v2`),
///   plus the string values `cmux` and `cmuxOnly` (accent mode, keymap preset, socket mode).
/// - Dev build only: the whole defaults domain `com.cmuxterm.app.debug.bree`, the folder
///   `Application Support/com.cmuxterm.app.debug.bree`, and any file named after that bundle id
///   inside `Application Support/Bree Dev` (session, agent journal and its SQLite sidecars, histories).
/// - Direct children of a Bree root whose name contains the old name.
/// - Inside files: quoted setting names in `bree.json`, `CMUX_*` environment names in
///   `session-*.json`, the `cmux-feed-v1:` workstream id prefix and the `cmux-events` protocol tag.
public enum LegacyNameMigration {
    /// Defaults key marking the migration as done for this domain.
    static let doneKey = "breeLegacyNameMigration.v1"
    private static let oldDevBundleIdentifier = "com.cmuxterm.app.debug.bree"
    private static let valueMap = ["cmux": "bree", "cmuxOnly": "breeOnly"]

    /// The new name for an old one: the same case-preserving rewrite the repository rename used.
    public static func newName(for old: String) -> String {
        var s = old.replacingOccurrences(of: "manaflow-ai/cmux", with: "ecyx00/bree")
        s = s.replacingOccurrences(of: "cmuxterm", with: "bree")
        s = s.replacingOccurrences(of: "Cmuxterm", with: "Bree")
        s = s.replacingOccurrences(of: "cmux", with: "bree")
        s = s.replacingOccurrences(of: "Cmux", with: "Bree")
        s = s.replacingOccurrences(of: "CMUX", with: "BREE")
        return s
    }

    private static func hasOldName(_ s: String) -> Bool { s.lowercased().contains("cmux") }

    /// Runs the migration once per defaults domain. Call it before anything reads settings or opens stores.
    public static func runIfNeeded(
        identity: BreeIdentity = .current,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard !defaults.bool(forKey: doneKey) else { return }
        migrateDefaults(identity: identity, defaults: defaults)
        let appSupport = homeDirectory.appendingPathComponent("Library/Application Support", isDirectory: true)
        if identity.kind == .breeDev {
            copyIfMissing(
                from: appSupport.appendingPathComponent(oldDevBundleIdentifier, isDirectory: true),
                to: appSupport.appendingPathComponent(newName(for: oldDevBundleIdentifier), isDirectory: true),
                fileManager: fileManager
            )
        }
        let roots = [
            identity.dotDirectory(homeDirectory: homeDirectory),
            identity.applicationSupportDirectory(in: appSupport),
            identity.configDirectory(homeDirectory: homeDirectory),
            identity.stateDirectory(homeDirectory: homeDirectory),
        ]
        for root in roots { copyRenamedChildren(of: root, fileManager: fileManager) }
        let dot = identity.dotDirectory(homeDirectory: homeDirectory)
        rewrite(dot.appendingPathComponent("workstream.jsonl"), fileManager) {
            $0.replacingOccurrences(of: "cmux-feed-v1:", with: "bree-feed-v1:")
        }
        rewrite(dot.appendingPathComponent("events.jsonl"), fileManager) {
            $0.replacingOccurrences(of: "cmux-events", with: "bree-events")
        }
        rewrite(identity.configFile(homeDirectory: homeDirectory), fileManager) { text in
            replacing(text, pattern: "\"[A-Za-z0-9_.$:/-]*[cC][mM][uU][xX][A-Za-z0-9_.$:/-]*\"") { newName(for: $0) }
        }
        let supportRoot = identity.applicationSupportDirectory(in: appSupport)
        let sessionFiles = (try? fileManager.contentsOfDirectory(atPath: supportRoot.path)) ?? []
        for name in sessionFiles where name.hasPrefix("session-") && name.hasSuffix(".json") {
            rewrite(supportRoot.appendingPathComponent(name), fileManager) {
                replacing($0, pattern: "CMUX_[A-Z0-9_]+") { newName(for: $0) }
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    private static func migrateDefaults(identity: BreeIdentity, defaults: UserDefaults) {
        func copy(_ source: [String: Any]) {
            for (key, value) in source where hasOldName(key) {
                let target = newName(for: key)
                guard defaults.object(forKey: target) == nil else { continue }
                defaults.set(mapped(value), forKey: target)
            }
        }
        if identity.kind == .breeDev, let old = UserDefaults(suiteName: oldDevBundleIdentifier),
           let domain = old.persistentDomain(forName: oldDevBundleIdentifier) {
            for (key, value) in domain {
                let target = newName(for: key)
                guard defaults.object(forKey: target) == nil else { continue }
                defaults.set(mapped(value), forKey: target)
            }
        }
        if let bundleID = Bundle.main.bundleIdentifier,
           let domain = defaults.persistentDomain(forName: bundleID) {
            copy(domain)
        }
        // Values of keys that kept their name (an enum raw value that contained the old name).
        for (key, value) in defaults.dictionaryRepresentation() {
            if let s = value as? String, let new = valueMap[s], !hasOldName(key) {
                defaults.set(new, forKey: key)
            }
        }
    }

    private static func mapped(_ value: Any) -> Any {
        if let s = value as? String, let new = valueMap[s] { return new }
        return value
    }

    private static func copyRenamedChildren(of root: URL, fileManager: FileManager) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        for name in names where hasOldName(name) && !name.hasSuffix("-cli-shims") {
            copyIfMissing(
                from: root.appendingPathComponent(name),
                to: root.appendingPathComponent(newName(for: name)),
                fileManager: fileManager
            )
        }
    }

    private static func copyIfMissing(from source: URL, to target: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: source.path), !fileManager.fileExists(atPath: target.path) else { return }
        try? fileManager.copyItem(at: source, to: target)
    }

    private static func rewrite(_ url: URL, _ fileManager: FileManager, _ transform: (String) -> String) {
        guard fileManager.fileExists(atPath: url.path),
              let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else { return }
        let updated = transform(text)
        guard updated != text else { return }
        try? updated.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func replacing(_ text: String, pattern: String, _ transform: (String) -> String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var result = ""
        var last = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result += text[last..<range.lowerBound]
            result += transform(String(text[range]))
            last = range.upperBound
        }
        return result + text[last...]
    }
}

/// Names the vendored Ghostty tree still reads and writes. That tree is third-party and is not
/// renamed, so the app must keep speaking these names to it. Kept here with the other old names.
public enum VendoredGhosttyEnvironment {
    /// Prefix of the environment variables the bundled theme picker reads (`<prefix>CONFIG`, `TARGET`, ...).
    public static let themePickerPrefix = "CMUX_THEME_PICKER_"
    /// First line of the managed theme block the picker writes into a Ghostty config.
    public static let themesBlockStart = "# cmux themes start"
    /// Last line of the managed theme block.
    public static let themesBlockEnd = "# cmux themes end"
}
