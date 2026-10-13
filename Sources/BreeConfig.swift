import Bonsplit
import BreeFoundation
import Combine
import CryptoKit
import Foundation
import BreeSettings

extension CodingUserInfoKey {
    static let breeWorkspaceColorDefaults = CodingUserInfoKey(rawValue: "breeWorkspaceColorDefaults")!
}

struct BreeConfigPackReference: Codable, Sendable, Hashable {
    var path: String

    private enum CodingKeys: String, CodingKey {
        case path
    }

    init(path: String) {
        self.path = path
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let rawPath = try? container.decode(String.self) {
            path = try Self.validatedPath(rawPath, codingPath: decoder.codingPath)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try Self.validatedPath(
            try container.decode(String.self, forKey: .path),
            codingPath: decoder.codingPath + [CodingKeys.path]
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(path)
    }

    private static func validatedPath(_ rawPath: String, codingPath: [CodingKey]) throws -> String {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "pack path must not be blank"
                )
            )
        }
        guard !path.lowercased().hasPrefix("http://"),
              !path.lowercased().hasPrefix("https://") else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: codingPath,
                    debugDescription: "pack path must be a local file or directory"
                )
            )
        }
        return path
    }
}

struct BreeConfigFile: Codable, Sendable {
    var packs: [BreeConfigPackReference]
    var actions: [String: BreeConfigActionDefinition]
    var settingPresets: [String: BreeSettingValue]
    var ui: BreeConfigUIDefinition?
    var notifications: BreeNotificationConfigDefinition?
    var newWorkspaceCommand: String?
    var surfaceTabBarButtons: [BreeSurfaceTabBarButton]?
    var commands: [BreeCommandDefinition]
    var vault: BreeVaultConfigDefinition?
    var workspaceGroups: BreeConfigWorkspaceGroupsDefinition?

    private enum CodingKeys: String, CodingKey {
        case packs, actions, settingPresets, ui, notifications, newWorkspaceCommand, surfaceTabBarButtons, commands, vault, workspaceGroups
    }

    init(
        packs: [BreeConfigPackReference] = [],
        actions: [String: BreeConfigActionDefinition] = [:],
        settingPresets: [String: BreeSettingValue] = [:],
        ui: BreeConfigUIDefinition? = nil,
        notifications: BreeNotificationConfigDefinition? = nil,
        newWorkspaceCommand: String? = nil,
        surfaceTabBarButtons: [BreeSurfaceTabBarButton]? = nil,
        commands: [BreeCommandDefinition] = [],
        vault: BreeVaultConfigDefinition? = nil,
        workspaceGroups: BreeConfigWorkspaceGroupsDefinition? = nil
    ) {
        self.packs = packs
        self.actions = actions
        self.settingPresets = settingPresets
        self.ui = ui
        self.notifications = notifications
        self.newWorkspaceCommand = newWorkspaceCommand
        self.surfaceTabBarButtons = surfaceTabBarButtons
        self.commands = commands
        self.vault = vault
        self.workspaceGroups = workspaceGroups
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        packs = try container.decodeIfPresent([BreeConfigPackReference].self, forKey: .packs) ?? []
        let decodedActions = try container.decodeIfPresent(
            BreeConfigActionDefinitionMap.self,
            forKey: .actions
        )?.definitions ?? [:]
        actions = try Self.normalizedActions(
            decodedActions,
            codingPath: decoder.codingPath + [CodingKeys.actions]
        )
        settingPresets = try container.decodeIfPresent(
            [String: BreeSettingValue].self,
            forKey: .settingPresets
        ) ?? [:]
        ui = try container.decodeIfPresent(BreeConfigUIDefinition.self, forKey: .ui)
        notifications = try container.decodeIfPresent(BreeNotificationConfigDefinition.self, forKey: .notifications)

        if let rawNewWorkspaceCommand = try container.decodeIfPresent(String.self, forKey: .newWorkspaceCommand) {
            let trimmed = rawNewWorkspaceCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath + [CodingKeys.newWorkspaceCommand],
                        debugDescription: "newWorkspaceCommand must not be blank"
                    )
                )
            }
            newWorkspaceCommand = trimmed
        } else {
            newWorkspaceCommand = nil
        }

        let rootSurfaceButtons = try container.decodeIfPresent(
            BreeSurfaceTabBarButtonList.self,
            forKey: .surfaceTabBarButtons
        )?.buttons
        let configuredSurfaceButtons = ui?.surfaceTabBar?.buttons ?? rootSurfaceButtons
        if let configuredSurfaceButtons {
            surfaceTabBarButtons = try Self.validatedSurfaceTabBarButtons(
                configuredSurfaceButtons,
                codingPath: decoder.codingPath + [
                    ui?.surfaceTabBar?.buttons == nil ? CodingKeys.surfaceTabBarButtons : CodingKeys.ui
                ]
            )
        } else {
            surfaceTabBarButtons = nil
        }
        commands = try container.decodeIfPresent([BreeCommandDefinition].self, forKey: .commands) ?? []
        vault = try container.decodeIfPresent(BreeVaultConfigDefinition.self, forKey: .vault)
        workspaceGroups = try container.decodeIfPresent(
            BreeConfigWorkspaceGroupsDefinition.self,
            forKey: .workspaceGroups
        )
    }

    private static func normalizedActions(
        _ decodedActions: [String: BreeConfigActionDefinition],
        codingPath: [CodingKey]
    ) throws -> [String: BreeConfigActionDefinition] {
        var actions: [String: BreeConfigActionDefinition] = [:]
        var canonicalIDs: [String: String] = [:]
        for (rawID, action) in decodedActions {
            let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions keys must not be blank"
                    )
                )
            }
            if actions[id] != nil {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate ids"
                    )
                )
            }
            let canonicalID = BreeSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
            if let existingID = canonicalIDs[canonicalID] {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "actions must not contain duplicate aliases for '\(canonicalID)' (found '\(existingID)' and '\(id)')"
                    )
                )
            }
            canonicalIDs[canonicalID] = id
            actions[id] = action
        }
        return actions
    }

    private static func validatedSurfaceTabBarButtons(
        _ buttons: [BreeSurfaceTabBarButton],
        codingPath: [CodingKey]
    ) throws -> [BreeSurfaceTabBarButton] {
        var seen = Set<String>()
        for button in buttons {
            if !seen.insert(button.id).inserted {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: codingPath,
                        debugDescription: "surface tab bar buttons must not contain duplicate ids"
                    )
                )
            }
        }
        return buttons
    }
}

/// Per-cwd customization for sidebar workspace groups. Keyed by the anchor
/// workspace's cwd. Keys containing `*` or `?` are matched as fnmatch globs;
/// otherwise they are path prefixes. Longest match wins. `~` is expanded.
struct BreeConfigWorkspaceGroupsDefinition: Codable, Sendable, Equatable {
    var byCwd: [String: BreeConfigWorkspaceGroupEntry]?

    enum CodingKeys: String, CodingKey {
        case byCwd
    }
}

struct BreeConfigWorkspaceGroupEntry: Codable, Sendable, Equatable {
    var color: String?
    var icon: String?
    var contextMenu: [BreeConfigContextMenuItem]?
    /// Where a newly-created workspace lands inside the group when the user
    /// clicks the header's `+` button or invokes Cmd-N from a group member.
    /// Valid values: `"afterCurrent"` (after the current in-group workspace,
    /// falling back to top), `"top"` (immediately after the anchor), or
    /// `"end"` (after the last member). When omitted,
    /// falls back to the global default
    /// (the stored `workspaceGroups.newWorkspacePlacement` setting).
    var newWorkspacePlacement: String?
}

/// Resolved snapshot of a per-cwd workspace group entry, with the JSON key
/// normalized for matching and any `contextMenu` actions resolved against the
/// loaded action/command tables.
struct BreeResolvedWorkspaceGroupConfig: Sendable, Equatable {
    let originalKey: String
    let normalizedKey: String
    let isGlob: Bool
    let color: String?
    let iconSymbol: String?
    let contextMenuItems: [BreeResolvedConfigContextMenuItem]
    /// Parsed override for where the `+` button places its new workspace.
    /// nil means "fall through to the global default."
    let newWorkspacePlacement: WorkspaceGroupNewPlacement?
}

enum BreeNotificationHooksMode: String, Codable, Sendable, Hashable {
    case append
    case replace
}

struct BreeNotificationConfigDefinition: Codable, Sendable, Hashable {
    var hooks: [BreeNotificationHookDefinition]?
    var hooksMode: BreeNotificationHooksMode?

    private enum CodingKeys: String, CodingKey {
        case hooks
        case hooksMode
    }
}

struct BreeNotificationHookDefinition: Codable, Sendable, Hashable {
    static let defaultTimeoutSeconds: TimeInterval = 20

    var id: String
    var command: String
    var timeoutSeconds: TimeInterval?
    var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case command
        case timeoutSeconds
        case enabled
    }

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try Self.requiredTrimmedString(forKey: .id, in: container)
        let decodedCommand = try Self.requiredTrimmedString(forKey: .command, in: container)
        let decodedTimeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeoutSeconds)
        if let decodedTimeout, !decodedTimeout.isFinite || decodedTimeout <= 0 {
            throw DecodingError.dataCorruptedError(
                forKey: .timeoutSeconds,
                in: container,
                debugDescription: "timeoutSeconds must be greater than 0"
            )
        }

        id = decodedID
        command = decodedCommand
        timeoutSeconds = decodedTimeout
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(command, forKey: .command)
        try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
        try container.encode(enabled, forKey: .enabled)
    }

    var resolvedTimeoutSeconds: TimeInterval {
        timeoutSeconds ?? Self.defaultTimeoutSeconds
    }

    private static func requiredTrimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let value = try container.decode(String.self, forKey: key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return value
    }
}

struct BreeResolvedNotificationHook: Sendable, Hashable {
    let id: String
    let command: String
    let timeoutSeconds: TimeInterval
    let sourcePath: String?
    let cwd: String
    let trustDescriptor: BreeActionTrustDescriptor?

    init(
        id: String,
        command: String,
        timeoutSeconds: TimeInterval,
        sourcePath: String?,
        cwd: String,
        trustDescriptor: BreeActionTrustDescriptor? = nil
    ) {
        self.id = id
        self.command = command
        self.timeoutSeconds = timeoutSeconds
        self.sourcePath = sourcePath
        self.cwd = cwd
        self.trustDescriptor = trustDescriptor
    }

    static func == (lhs: BreeResolvedNotificationHook, rhs: BreeResolvedNotificationHook) -> Bool {
        lhs.id == rhs.id &&
            lhs.command == rhs.command &&
            lhs.timeoutSeconds == rhs.timeoutSeconds &&
            lhs.sourcePath == rhs.sourcePath &&
            lhs.cwd == rhs.cwd &&
            lhs.trustDescriptor?.fingerprint == rhs.trustDescriptor?.fingerprint
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(command)
        hasher.combine(timeoutSeconds)
        hasher.combine(sourcePath)
        hasher.combine(cwd)
        hasher.combine(trustDescriptor?.fingerprint)
    }
}

enum BreeConfigTerminalCommandTarget: String, Codable, Sendable, Hashable {
    case currentTerminal
    case newTabInCurrentPane

    static let defaultForActions: BreeConfigTerminalCommandTarget = .newTabInCurrentPane
}

/// Agent launched by an `agent` action. Known kinds carry presentation
/// defaults (icon, display title); any other CLI name decodes as `.custom`
/// so new agents never require an app change.
enum BreeConfigAgentKind: Sendable, Hashable {
    case codex
    case claudeCode
    case opencode
    case custom(String)

    var commandName: String {
        switch self {
        case .codex:
            return "codex"
        case .claudeCode:
            return "claude"
        case .opencode:
            return "opencode"
        case .custom(let name):
            return name
        }
    }

    var defaultIcon: BreeButtonIcon {
        switch self {
        case .codex:
            return .symbol("sparkles")
        case .claudeCode:
            return .symbol("brain.head.profile")
        case .opencode:
            return .symbol("chevron.left.forwardslash.chevron.right")
        case .custom:
            return .symbol("terminal")
        }
    }
}

extension BreeConfigAgentKind: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch value {
        case "codex":
            self = .codex
        case "claude", "claudeCode", "claude-code":
            self = .claudeCode
        case "opencode", "openCode", "open-code":
            self = .opencode
        default:
            guard !value.isEmpty,
                  value.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "agent must be a single command name with no whitespace; put flags in 'args'"
                    )
                )
            }
            self = .custom(value)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(commandName)
    }
}

enum BreeButtonIcon: Codable, Sendable, Hashable {
    case symbol(String)
    case emoji(String, scale: Double = 1)
    case imagePath(String)

    var symbolName: String {
        if case .symbol(let name) = self {
            return name
        }
        return "questionmark.circle"
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case name
        case value
        case path
        case scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try Self.trimmedString(forKey: .type, in: container)
        switch type {
        case "symbol", "sfSymbol", "systemImage":
            self = .symbol(try Self.trimmedString(forKey: .name, in: container))
        case "emoji":
            self = .emoji(
                try Self.trimmedString(forKey: .value, in: container),
                scale: try Self.emojiScale(in: container)
            )
        case "image", "file":
            self = .imagePath(try Self.trimmedString(forKey: .path, in: container))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown icon type '\(type)'"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .symbol(let name):
            try container.encode("symbol", forKey: .type)
            try container.encode(name, forKey: .name)
        case .emoji(let value, let scale):
            try container.encode("emoji", forKey: .type)
            try container.encode(value, forKey: .value)
            if scale != 1 {
                try container.encode(scale, forKey: .scale)
            }
        case .imagePath(let path):
            try container.encode("image", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }

    func bonsplitIcon(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalImage: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton.Icon {
        switch self {
        case .symbol(let name):
            return .systemImage(name)
        case .emoji(let value, let scale):
            return .emoji(value, scale: scale)
        case .imagePath(let path):
            guard let preparedImage = Self.preparedImageAsset(
                path,
                relativeToConfig: configSourcePath,
                globalConfigPath: globalConfigPath
            ) else {
                NSLog("[BreeConfig] icon image path is not allowed: %@", path)
                return .systemImage("questionmark.circle")
            }
            if preparedImage.isProjectLocal && !allowProjectLocalImage {
                return .systemImage("lock.fill")
            }
            return .imageData(preparedImage.data)
        }
    }

    func projectLocalImageFingerprint(configSourcePath: String?, globalConfigPath: String) -> String? {
        guard case .imagePath(let path) = self,
              let preparedImage = Self.preparedImageAsset(
                  path,
                  relativeToConfig: configSourcePath,
                  globalConfigPath: globalConfigPath
              ),
              preparedImage.isProjectLocal else {
            return nil
        }
        return preparedImage.fingerprint
    }

    func resolvingRelativeImagePath(relativeToConfig configSourcePath: String?) -> BreeButtonIcon {
        guard case .imagePath(let path) = self else { return self }
        return .imagePath(Self.resolvePath(path, relativeToConfig: configSourcePath))
    }

    private static let maxImageBytes = 1_000_000

    private static func emojiScale(in container: KeyedDecodingContainer<CodingKeys>) throws -> Double {
        let scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
        guard scale.isFinite, scale > 0 else {
            throw DecodingError.dataCorruptedError(
                forKey: .scale,
                in: container,
                debugDescription: "Emoji icon scale must be a positive number"
            )
        }
        return scale
    }

    private struct PreparedImageAsset {
        let data: Data
        let fingerprint: String
        let isProjectLocal: Bool
    }

    private static func looksLikeSVGPath(_ value: String) -> Bool {
        (value as NSString).pathExtension.lowercased() == "svg"
    }

    private static func isSafeSVG(data: Data) -> Bool {
        guard let text = String(data: data, encoding: .utf8) else { return false }
        let lowered = text.lowercased()
        guard !lowered.contains("<!doctype"),
              !lowered.contains("<!entity") else {
            return false
        }

        let inspector = SVGSecurityInspector()
        return inspector.parse(data: data)
    }

    private static func resolvePath(_ path: String, relativeToConfig configSourcePath: String?) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        if (expanded as NSString).isAbsolutePath {
            return expanded
        }
        guard let configSourcePath else { return expanded }
        let base = (configSourcePath as NSString).deletingLastPathComponent
        return (base as NSString).appendingPathComponent(expanded)
    }

    private static func safeResolvedImagePath(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("http://"),
              !trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }

        let isGlobal = configSourcePath == nil || configSourcePath == globalConfigPath
        if !isGlobal {
            let expanded = (trimmed as NSString).expandingTildeInPath
            guard !(expanded as NSString).isAbsolutePath,
                  expanded == trimmed else {
                return nil
            }
        }

        let resolvedPath = resolvePath(trimmed, relativeToConfig: configSourcePath)
        guard !resolvedPath.isEmpty else { return nil }
        let standardizedPath = (resolvedPath as NSString).standardizingPath

        guard !isGlobal, let configSourcePath else {
            return standardizedPath
        }

        let allowedRoot = projectRoot(forConfigPath: configSourcePath)
        let resolvedURL = URL(fileURLWithPath: standardizedPath).resolvingSymlinksInPath()
        let allowedURL = URL(fileURLWithPath: allowedRoot).resolvingSymlinksInPath()
        let resolved = resolvedURL.path
        let allowed = allowedURL.path
        guard resolved == allowed || resolved.hasPrefix(allowed + "/") else {
            return nil
        }
        return resolved
    }

    private static func preparedImageAsset(
        _ path: String,
        relativeToConfig configSourcePath: String?,
        globalConfigPath: String
    ) -> PreparedImageAsset? {
        guard let resolvedPath = safeResolvedImagePath(
            path,
            relativeToConfig: configSourcePath,
            globalConfigPath: globalConfigPath
        ) else {
            return nil
        }
        guard let data = FileManager.default.contents(atPath: resolvedPath) else {
            NSLog("[BreeConfig] icon image does not exist: %@", resolvedPath)
            return nil
        }
        guard data.count <= maxImageBytes else {
            NSLog("[BreeConfig] icon image is too large: %@", resolvedPath)
            return nil
        }
        if looksLikeSVGPath(resolvedPath), !isSafeSVG(data: data) {
            NSLog("[BreeConfig] icon SVG contains unsupported content: %@", resolvedPath)
            return nil
        }

        let isProjectLocal = configSourcePath != nil && configSourcePath != globalConfigPath
        let fingerprint = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return PreparedImageAsset(data: data, fingerprint: fingerprint, isProjectLocal: isProjectLocal)
    }

    static func projectRoot(forConfigPath configPath: String) -> String {
        let configDir = (configPath as NSString).deletingLastPathComponent
        if BreeIdentity.isProjectDirectoryName((configDir as NSString).lastPathComponent) {
            return (configDir as NSString).deletingLastPathComponent
        }
        return configDir
    }

    private final class SVGSecurityInspector: NSObject, XMLParserDelegate {
        private var isSafe = true
        private var elementStack: [String] = []

        func parse(data: Data) -> Bool {
            let parser = XMLParser(data: data)
            parser.delegate = self
            parser.shouldProcessNamespaces = false
            parser.shouldResolveExternalEntities = false
            let parsed = parser.parse()
            return parsed && isSafe
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            let loweredName = elementName.lowercased()
            elementStack.append(loweredName)

            if loweredName == "script" || loweredName == "foreignobject" {
                markUnsafe(parser)
                return
            }

            for (name, value) in attributeDict {
                guard Self.isSafeSVGAttribute(name: name, value: value) else {
                    markUnsafe(parser)
                    return
                }
            }
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            guard !elementStack.isEmpty else { return }
            elementStack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard elementStack.last == "style" else { return }
            guard Self.isSafeSVGStyle(string) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard elementStack.last == "style",
                  let text = String(data: CDATABlock, encoding: .utf8) else {
                return
            }
            guard Self.isSafeSVGStyle(text) else {
                markUnsafe(parser)
                return
            }
        }

        func parser(
            _ parser: XMLParser,
            foundProcessingInstructionWithTarget target: String,
            data: String?
        ) {
            if target.lowercased() == "xml-stylesheet" {
                markUnsafe(parser)
            }
        }

        private func markUnsafe(_ parser: XMLParser) {
            isSafe = false
            parser.abortParsing()
        }

        private static func isSafeSVGAttribute(name: String, value: String) -> Bool {
            let loweredName = name.lowercased()
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let loweredValue = trimmedValue.lowercased()

            if loweredName.hasPrefix("on") {
                return false
            }

            if loweredName == "xmlns" || loweredName.hasPrefix("xmlns:") {
                return true
            }

            if loweredName == "href" || loweredName == "xlink:href" {
                return isSafeSVGReference(trimmedValue)
            }

            if containsBlockedSVGValue(loweredValue) {
                return false
            }

            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }

            return true
        }

        private static func isSafeSVGStyle(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            guard !loweredValue.contains("@import"),
                  !containsBlockedSVGValue(loweredValue) else {
                return false
            }
            if loweredValue.contains("url(") {
                return containsOnlyInternalSVGURLs(value)
            }
            return true
        }

        private static func isSafeSVGReference(_ value: String) -> Bool {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedValue.isEmpty else { return true }
            if trimmedValue.hasPrefix("#") {
                return true
            }
            if trimmedValue.lowercased().hasPrefix("url(") {
                return containsOnlyInternalSVGURLs(trimmedValue)
            }
            return false
        }

        private static func containsBlockedSVGValue(_ value: String) -> Bool {
            let blockedFragments = [
                "javascript:",
                "data:",
                "http://",
                "https://",
                "file://",
                "blob:"
            ]
            return blockedFragments.contains { value.contains($0) }
        }

        private static func containsOnlyInternalSVGURLs(_ value: String) -> Bool {
            let loweredValue = value.lowercased()
            var searchStart = loweredValue.startIndex

            while let range = loweredValue.range(
                of: "url(",
                options: [],
                range: searchStart..<loweredValue.endIndex
            ) {
                let contentStart = range.upperBound
                guard let closing = loweredValue[contentStart...].firstIndex(of: ")") else {
                    return false
                }

                var reference = String(loweredValue[contentStart..<closing])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if (reference.hasPrefix("\"") && reference.hasSuffix("\"")) ||
                    (reference.hasPrefix("'") && reference.hasSuffix("'")) {
                    reference.removeFirst()
                    reference.removeLast()
                }

                guard reference.hasPrefix("#") else {
                    return false
                }

                searchStart = loweredValue.index(after: closing)
            }

            return true
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String {
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

enum BreeSurfaceTabBarButtonAction: Sendable, Hashable {
    case builtIn(BreeSurfaceTabBarBuiltInAction)
    case command(String)
    case agent(BreeConfigAgentKind, args: String?)
    case workspaceCommand(String)
    case workspace(BreeWorkspaceDefinition, restart: BreeRestartBehavior?)
    /// `"type": "setting"` / `"type": "settingPreset"`: edits the global
    /// bree.json through ``JSONConfigStore/apply(_:)``.
    case setting(BreeSettingChange)
    case actionReference(String)

    var defaultId: String {
        switch self {
        case .builtIn(let action):
            return action.configID
        case .command(let command):
            return "command." + Self.generatedCommandId(for: command)
        case .agent(let agent, _):
            return agent.commandName
        case .workspaceCommand(let commandName):
            return "workspaceCommand." + Self.generatedCommandId(for: commandName)
        case .workspace(let definition, _):
            return "workspace." + Self.generatedCommandId(for: definition.name ?? "workspace")
        case .setting(let change):
            return "setting." + Self.generatedCommandId(for: change.displayTarget)
        case .actionReference(let identifier):
            return identifier
        }
    }

    var defaultIcon: String {
        defaultButtonIcon.symbolName
    }

    var defaultButtonIcon: BreeButtonIcon {
        switch self {
        case .builtIn(let action):
            return .symbol(action.defaultIcon)
        case .command:
            return .symbol("terminal")
        case .agent(let agent, _):
            return agent.defaultIcon
        case .workspaceCommand, .workspace:
            return .symbol("rectangle.stack.badge.plus")
        case .setting:
            return .symbol("slider.horizontal.3")
        case .actionReference:
            return .symbol("questionmark.circle")
        }
    }

    var terminalCommand: String? {
        switch self {
        case .command(let command):
            return command
        case .agent(let agent, let args):
            let trimmedArgs = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmedArgs.isEmpty ? agent.commandName : "\(agent.commandName) \(trimmedArgs)"
        case .builtIn, .workspaceCommand, .workspace, .setting, .actionReference:
            return nil
        }
    }

    var workspaceCommandName: String? {
        if case .workspaceCommand(let name) = self {
            return name
        }
        return nil
    }

    var isSettingChange: Bool {
        if case .setting = self { return true }
        return false
    }

    /// Inline workspace payload for `type: "workspace"` actions.
    var inlineWorkspace: (definition: BreeWorkspaceDefinition, restart: BreeRestartBehavior?)? {
        if case .workspace(let definition, let restart) = self {
            return (definition, restart)
        }
        return nil
    }

    private static func generatedCommandId(for command: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let encoded = command.addingPercentEncoding(withAllowedCharacters: allowed) ?? command
        return encoded.isEmpty ? "command" : encoded
    }
}

/// Thrown while decoding one surface tab bar button that names a built-in action this build does not have.
struct BreeUnknownSurfaceTabBarBuiltInActionError: Error, Equatable {
    let configID: String
}

/// A `surfaceTabBarButtons` array that skips (and logs) buttons naming an unknown built-in
/// action; every other decode error still fails the block.
struct BreeSurfaceTabBarButtonList: Decodable {
    let buttons: [BreeSurfaceTabBarButton]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var buttons: [BreeSurfaceTabBarButton] = []
        while !container.isAtEnd {
            do {
                buttons.append(try container.decode(BreeSurfaceTabBarButton.self))
            } catch let error as BreeUnknownSurfaceTabBarBuiltInActionError {
                NSLog("[BreeConfig] surfaceTabBarButtons entry skipped: unknown built-in action '%@'", error.configID)
                // The failed decode did not advance the container; consume the entry.
                _ = try container.decode(BreeSurfaceTabBarButtonListDiscardedEntry.self)
            }
        }
        self.buttons = buttons
    }
}

private struct BreeSurfaceTabBarButtonListDiscardedEntry: Decodable {}

/// The `actions` object, skipping (and logging) definitions of a built-in action this build
/// does not have; every other decode error still fails the block.
struct BreeConfigActionDefinitionMap: Decodable {
    let definitions: [String: BreeConfigActionDefinition]

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var definitions: [String: BreeConfigActionDefinition] = [:]
        for key in container.allKeys {
            do {
                definitions[key.stringValue] = try container.decode(BreeConfigActionDefinition.self, forKey: key)
            } catch let error as BreeUnknownSurfaceTabBarBuiltInActionError {
                NSLog("[BreeConfig] action '%@' skipped: unknown built-in action '%@'", key.stringValue, error.configID)
            }
        }
        self.definitions = definitions
    }
}

struct BreeSurfaceTabBarButton: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String?
    var icon: BreeButtonIcon?
    var tooltip: String?
    var action: BreeSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: BreeConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case icon
        case tooltip
        case action
        case builtin
        case command
        case agent
        case args
        case type
        case commandName
        case name
        case workspace
        case restart
        case confirm
        case target
    }

    static let newTerminal = actionReference(BreeSurfaceTabBarBuiltInAction.newTerminal.configID)
    static let newBrowser = actionReference(BreeSurfaceTabBarBuiltInAction.newBrowser.configID)
    static let splitRight = actionReference(BreeSurfaceTabBarBuiltInAction.splitRight.configID)
    static let splitDown = actionReference(BreeSurfaceTabBarBuiltInAction.splitDown.configID)
    static let toggleFiles = actionReference(BreeSurfaceTabBarBuiltInAction.toggleFiles.configID)
    static let toggleArchitecture = actionReference(BreeSurfaceTabBarBuiltInAction.toggleArchitecture.configID)
    static let toggleWiki = actionReference(BreeSurfaceTabBarBuiltInAction.toggleWiki.configID)
    static let showBoard = actionReference(BreeSurfaceTabBarBuiltInAction.showBoard.configID)
    static let newWindow = actionReference(BreeSurfaceTabBarBuiltInAction.newWindow.configID)

    static let defaults: [BreeSurfaceTabBarButton] = [
        .newTerminal,
        .newBrowser,
        .splitRight,
        .splitDown,
        .toggleWiki,
        .toggleArchitecture,
        .showBoard
    ]

    static func builtIn(
        _ action: BreeSurfaceTabBarBuiltInAction,
        id: String? = nil,
        title: String? = nil,
        icon: BreeButtonIcon? = nil,
        tooltip: String? = nil
    ) -> BreeSurfaceTabBarButton {
        BreeSurfaceTabBarButton(
            id: id ?? action.configID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .builtIn(action),
            confirm: nil,
            terminalCommandTarget: nil
        )
    }

    static func actionReference(
        _ actionID: String,
        title: String? = nil,
        icon: BreeButtonIcon? = nil,
        tooltip: String? = nil
    ) -> BreeSurfaceTabBarButton {
        BreeSurfaceTabBarButton(
            id: actionID,
            title: title,
            icon: icon,
            tooltip: tooltip,
            action: .actionReference(actionID)
        )
    }

    var command: String? {
        action.terminalCommand
    }

    var terminalCommand: String? {
        action.terminalCommand
    }

    var resolvedTerminalCommandTarget: BreeConfigTerminalCommandTarget {
        terminalCommandTarget ?? BreeConfigTerminalCommandTarget.defaultForActions
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Synthetic named command for inline `type: "workspace"` buttons/actions so
    /// execution and trust fingerprinting share one definition. Carries the
    /// button's `confirm` so explicit confirmation requests survive the wrap.
    var inlineWorkspaceSyntheticCommand: BreeCommandDefinition? {
        guard let inline = action.inlineWorkspace else { return nil }
        return BreeCommandDefinition(
            name: title ?? tooltip ?? inline.definition.name ?? id,
            restart: inline.restart,
            workspace: inline.definition,
            confirm: confirm
        )
    }

    /// Name plus the user's live shortcut for built-ins that own one. Registry
    /// resolution fills `tooltip` with the plain name, so the shortcut is
    /// appended here instead of being skipped by the `tooltip ??` chain.
    private var resolvedTooltip: String? {
        guard case .builtIn(let builtIn) = action else { return tooltip ?? title ?? terminalCommand }
        let name = tooltip ?? title ?? builtIn.resolvedConfigMetadata.title
        guard let shortcutAction = builtIn.shortcutAction,
              KeyboardShortcutSettings.shortcutIfBound(for: shortcutAction) != nil else { return name }
        return shortcutAction.tooltip(name)
    }

    func bonsplitActionButton(
        configSourcePath: String?,
        globalConfigPath: String,
        allowProjectLocalIcon: Bool = true
    ) -> BonsplitConfiguration.SplitActionButton {
        let bonsplitAction: BonsplitConfiguration.SplitActionButton.Action = {
            switch action {
            case .builtIn(let builtIn):
                return builtIn.bonsplitAction ?? .custom(id)
            case .command, .agent, .workspaceCommand, .workspace, .setting, .actionReference:
                return .custom(id)
            }
        }()

        var button = BonsplitConfiguration.SplitActionButton(
            id: id,
            icon: (icon ?? action.defaultButtonIcon).bonsplitIcon(
                configSourcePath: iconSourcePath ?? configSourcePath,
                globalConfigPath: globalConfigPath,
                allowProjectLocalImage: allowProjectLocalIcon
            ),
            tooltip: resolvedTooltip,
            action: bonsplitAction
        )
        if case .builtIn(let builtIn) = action {
            button.accessibilityName = tooltip ?? title ?? builtIn.resolvedConfigMetadata.title
        }
        return button
    }

    init(
        id: String,
        title: String? = nil,
        icon: BreeButtonIcon? = nil,
        tooltip: String? = nil,
        action: BreeSurfaceTabBarButtonAction,
        confirm: Bool? = nil,
        terminalCommandTarget: BreeConfigTerminalCommandTarget? = nil,
        actionSourcePath: String? = nil,
        iconSourcePath: String? = nil
    ) {
        self.id = id
        self.title = title
        self.icon = icon
        self.tooltip = tooltip
        self.action = action
        self.confirm = confirm
        self.terminalCommandTarget = terminalCommandTarget
        self.actionSourcePath = actionSourcePath
        self.iconSourcePath = iconSourcePath
    }

    init(from decoder: Decoder) throws {
        if let legacy = try? decoder.singleValueContainer().decode(String.self) {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "surface tab bar button action must not be blank"
                    )
                )
            }
            self = BreeSurfaceTabBarButton(
                id: BreeSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed,
                action: .actionReference(BreeSurfaceTabBarBuiltInAction(configID: trimmed)?.configID ?? trimmed)
            )
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let explicitId = try Self.trimmedString(forKey: .id, in: container)
        let explicitTitle = try Self.trimmedString(forKey: .title, in: container, allowBlankAsNil: true)
        let explicitIcon = try container.decodeIfPresent(BreeButtonIcon.self, forKey: .icon)
        let explicitTooltip = try Self.trimmedString(forKey: .tooltip, in: container, allowBlankAsNil: true)
        let rawAction = try Self.trimmedString(forKey: .action, in: container)
        let rawBuiltin = try Self.trimmedString(forKey: .builtin, in: container)
        let rawCommand = try Self.trimmedString(forKey: .command, in: container)
        let rawAgent = try container.decodeIfPresent(BreeConfigAgentKind.self, forKey: .agent)
        let rawArgs = try Self.trimmedString(forKey: .args, in: container, allowBlankAsNil: true)
        let rawType = try Self.trimmedString(forKey: .type, in: container)
        let rawCommandName = try Self.trimmedString(forKey: .commandName, in: container)
            ?? Self.trimmedString(forKey: .name, in: container)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)
        terminalCommandTarget = try container.decodeIfPresent(BreeConfigTerminalCommandTarget.self, forKey: .target)
        actionSourcePath = nil
        iconSourcePath = nil

        let definedActionForms = [
            rawAction != nil,
            rawBuiltin != nil,
            rawCommand != nil,
            rawAgent != nil,
            rawType != nil
        ].filter(\.self).count
        if definedActionForms > 1 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define only one of 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        if let rawType {
            switch rawType {
            case "workspaceCommand":
                guard let rawCommandName else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspaceCommand surface tab bar buttons require commandName"
                        )
                    )
                }
                action = .workspaceCommand(rawCommandName)
            case "workspace":
                guard container.contains(.workspace) else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(
                            codingPath: decoder.codingPath,
                            debugDescription: "workspace surface tab bar buttons require a 'workspace' object"
                        )
                    )
                }
                let definition = try container.decode(BreeWorkspaceDefinition.self, forKey: .workspace)
                let restart = try container.decodeIfPresent(BreeRestartBehavior.self, forKey: .restart)
                action = .workspace(definition, restart: restart)
            default:
                throw DecodingError.dataCorruptedError(
                    forKey: .type,
                    in: container,
                    debugDescription: "Unknown surface tab bar button type '\(rawType)'"
                )
            }
        } else if let rawCommand {
            action = .command(rawCommand)
        } else if let rawAgent {
            action = .agent(rawAgent, args: rawArgs)
        } else if let rawBuiltin {
            guard let builtIn = BreeSurfaceTabBarBuiltInAction(configID: rawBuiltin) else {
                // Not a DecodingError: `BreeSurfaceTabBarButtonList` skips exactly this case so a
                // saved built-in that this build removed (for example `bree.newAgentChat`) does
                // not discard the rest of the block.
                throw BreeUnknownSurfaceTabBarBuiltInActionError(configID: rawBuiltin)
            }
            action = .builtIn(builtIn)
        } else if let rawAction {
            action = .actionReference(rawAction)
        } else if let explicitId,
                  let builtIn = BreeSurfaceTabBarBuiltInAction(configID: explicitId) {
            action = .builtIn(builtIn)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "surfaceTabBarButtons entries must define 'action', 'builtin', 'command', 'agent', or 'type'"
                )
            )
        }

        id = explicitId ?? action.defaultId
        title = explicitTitle
        icon = explicitIcon
        tooltip = explicitTooltip
    }

    func resolved(
        actions: [String: BreeResolvedConfigAction],
        codingPath: [CodingKey]
    ) throws -> BreeSurfaceTabBarButton {
        guard case .actionReference(let identifier) = action else {
            return self
        }

        let resolvedIdentifier = BreeSurfaceTabBarBuiltInAction(configID: identifier)?.configID ?? identifier
        if let definition = actions[resolvedIdentifier] {
            return BreeSurfaceTabBarButton(
                id: id,
                title: title ?? definition.title,
                icon: icon ?? definition.icon,
                tooltip: tooltip ?? definition.tooltip,
                action: definition.action,
                confirm: confirm ?? definition.confirm,
                terminalCommandTarget: terminalCommandTarget ?? definition.terminalCommandTarget,
                actionSourcePath: definition.actionSourcePath,
                iconSourcePath: icon == nil ? definition.iconSourcePath : iconSourcePath
            )
        }

        if let builtIn = BreeSurfaceTabBarBuiltInAction(configID: identifier) {
            return BreeSurfaceTabBarButton(
                id: id,
                title: title,
                icon: icon,
                tooltip: tooltip,
                action: .builtIn(builtIn),
                confirm: confirm,
                terminalCommandTarget: terminalCommandTarget,
                actionSourcePath: actionSourcePath,
                iconSourcePath: iconSourcePath
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(icon, forKey: .icon)
        try container.encodeIfPresent(tooltip, forKey: .tooltip)
        try container.encodeIfPresent(confirm, forKey: .confirm)
        try container.encodeIfPresent(terminalCommandTarget, forKey: .target)

        switch action {
        case .builtIn(let builtIn):
            try container.encode(builtIn.configID, forKey: .builtin)
        case .command(let command):
            try container.encode(command, forKey: .command)
        case .agent(let agent, let args):
            try container.encode(agent, forKey: .agent)
            try container.encodeIfPresent(args, forKey: .args)
        case .workspaceCommand(let commandName):
            try container.encode("workspaceCommand", forKey: .type)
            try container.encode(commandName, forKey: .commandName)
        case .workspace(let definition, let restart):
            try container.encode("workspace", forKey: .type)
            try container.encode(definition, forKey: .workspace)
            try container.encodeIfPresent(restart, forKey: .restart)
        case .setting:
            // Setting changes are only declared in the `actions` registry;
            // a button that runs one references its action id.
            try container.encode(id, forKey: .action)
        case .actionReference(let identifier):
            try container.encode(identifier, forKey: .action)
        }
    }

    private static func trimmedString(
        forKey key: CodingKeys,
        in container: KeyedDecodingContainer<CodingKeys>,
        allowBlankAsNil: Bool = false
    ) throws -> String? {
        guard container.contains(key) else { return nil }
        let raw = try container.decode(String.self, forKey: key)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if allowBlankAsNil { return nil }
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "\(key.stringValue) must not be blank"
            )
        }
        return trimmed
    }
}

struct BreeResolvedConfigAction: Identifiable, Sendable, Hashable {
    var id: String
    var title: String
    var subtitle: String?
    var keywords: [String]
    var palette: Bool
    var shortcut: StoredShortcut?
    var icon: BreeButtonIcon?
    var tooltip: String?
    var action: BreeSurfaceTabBarButtonAction
    var confirm: Bool?
    var terminalCommandTarget: BreeConfigTerminalCommandTarget?
    var actionSourcePath: String?
    var iconSourcePath: String?
    var newWorkspaceMenu: Bool?

    var terminalCommand: String? {
        action.terminalCommand
    }

    var workspaceCommandName: String? {
        action.workspaceCommandName
    }

    /// Whether this action should be auto-offered in the new-workspace
    /// plus-button menu: explicit `newWorkspaceMenu` wins; inline workspace
    /// actions default to true.
    var wantsNewWorkspaceMenu: Bool {
        newWorkspaceMenu ?? (action.inlineWorkspace != nil)
    }

    /// Synthetic named command for inline `type: "workspace"` actions so
    /// execution and trust fingerprinting reuse the named-command path.
    /// Carries the action's `confirm` so explicit confirmation requests
    /// survive the wrap.
    var inlineWorkspaceSyntheticCommand: BreeCommandDefinition? {
        guard let inline = action.inlineWorkspace else { return nil }
        return BreeCommandDefinition(
            name: title,
            restart: inline.restart,
            workspace: inline.definition,
            confirm: confirm
        )
    }

    func applying(
        _ definition: BreeConfigActionDefinition,
        actionSourcePath: String?,
        iconSourcePath: String?
    ) -> BreeResolvedConfigAction? {
        var next = self
        next.title = definition.title ?? next.title
        next.subtitle = definition.subtitle ?? next.subtitle
        if let keywords = definition.keywords {
            next.keywords = keywords
        }
        next.palette = definition.palette ?? next.palette
        next.shortcut = definition.shortcut ?? next.shortcut
        if let icon = definition.icon {
            next.icon = icon
            next.iconSourcePath = iconSourcePath ?? actionSourcePath
        }
        next.tooltip = definition.tooltip ?? next.tooltip
        next.confirm = definition.confirm ?? next.confirm
        next.terminalCommandTarget = definition.terminalCommandTarget ?? next.terminalCommandTarget
        next.newWorkspaceMenu = definition.newWorkspaceMenu ?? next.newWorkspaceMenu
        if let action = definition.action {
            next.action = action
            next.actionSourcePath = actionSourcePath ?? next.actionSourcePath
        }
        return next
    }

    // Compatibility overload for callers that only track one source path.
    static func fromDefinition(
        id: String,
        definition: BreeConfigActionDefinition,
        sourcePath: String?
    ) -> BreeResolvedConfigAction? {
        fromDefinition(
            id: id,
            definition: definition,
            actionSourcePath: sourcePath,
            iconSourcePath: sourcePath
        )
    }

    static func fromDefinition(
        id: String,
        definition: BreeConfigActionDefinition,
        actionSourcePath: String?,
        iconSourcePath: String?
    ) -> BreeResolvedConfigAction? {
        guard let action = definition.action else { return nil }
        let title = definition.title
            ?? definition.tooltip
            ?? Self.defaultTitle(for: id, action: action)
        return BreeResolvedConfigAction(
            id: id,
            title: title,
            subtitle: definition.subtitle,
            keywords: definition.keywords ?? [],
            palette: definition.palette ?? true,
            shortcut: definition.shortcut,
            icon: definition.icon ?? action.defaultButtonIcon,
            tooltip: definition.tooltip,
            action: action,
            confirm: definition.confirm,
            terminalCommandTarget: definition.terminalCommandTarget,
            actionSourcePath: actionSourcePath,
            iconSourcePath: definition.icon == nil ? nil : (iconSourcePath ?? actionSourcePath),
            newWorkspaceMenu: definition.newWorkspaceMenu
        )
    }

    static func builtIn(_ builtIn: BreeSurfaceTabBarBuiltInAction) -> BreeResolvedConfigAction {
        let metadata = builtIn.resolvedConfigMetadata

        return BreeResolvedConfigAction(
            id: builtIn.configID,
            title: metadata.title,
            subtitle: String(localized: "command.breeConfig.builtInSubtitle", defaultValue: "Bree"),
            keywords: metadata.keywords,
            palette: true,
            shortcut: nil,
            icon: .symbol(builtIn.defaultIcon),
            tooltip: nil,
            action: .builtIn(builtIn),
            confirm: nil,
            terminalCommandTarget: nil,
            actionSourcePath: nil,
            iconSourcePath: nil
        )
    }

    private static func defaultTitle(for id: String, action: BreeSurfaceTabBarButtonAction) -> String {
        switch action {
        case .agent(let agent, _):
            switch agent {
            case .codex:
                return String(localized: "command.breeConfig.defaultCodexTitle", defaultValue: "Codex")
            case .claudeCode:
                return String(localized: "command.breeConfig.defaultClaudeCodeTitle", defaultValue: "Claude Code")
            case .opencode:
                return String(localized: "command.breeConfig.defaultOpenCodeTitle", defaultValue: "OpenCode")
            case .custom(let name):
                return name
            }
        case .command:
            return id
        case .workspaceCommand(let commandName):
            return commandName
        case .workspace(let definition, _):
            return definition.name ?? id
        case .setting:
            return id
        case .builtIn(let builtIn):
            return builtIn.configID
        case .actionReference(let identifier):
            return identifier
        }
    }
}

struct BreeCommandDefinition: Codable, Sendable, Identifiable {
    var name: String
    var description: String?
    var keywords: [String]?
    var restart: BreeRestartBehavior?
    var workspace: BreeWorkspaceDefinition?
    var command: String?
    var confirm: Bool?

    var id: String {
        "bree.config.command." + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
    }

    init(
        name: String,
        description: String? = nil,
        keywords: [String]? = nil,
        restart: BreeRestartBehavior? = nil,
        workspace: BreeWorkspaceDefinition? = nil,
        command: String? = nil,
        confirm: Bool? = nil
    ) {
        self.name = name
        self.description = description
        self.keywords = keywords
        self.restart = restart
        self.workspace = workspace
        self.command = command
        self.confirm = confirm
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        keywords = try container.decodeIfPresent([String].self, forKey: .keywords)
        restart = try container.decodeIfPresent(BreeRestartBehavior.self, forKey: .restart)
        workspace = try container.decodeIfPresent(BreeWorkspaceDefinition.self, forKey: .workspace)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        confirm = try container.decodeIfPresent(Bool.self, forKey: .confirm)

        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command name must not be blank"
                )
            )
        }
        if let cmd = command,
           cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define a blank 'command'"
                )
            )
        }

        if workspace != nil && command != nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must not define both 'workspace' and 'command'"
                )
            )
        }
        if workspace == nil && command == nil {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Command '\(name)' must define either 'workspace' or 'command'"
                )
            )
        }
    }
}

indirect enum BreeLayoutNode: Codable, Sendable, Hashable {
    case pane(BreePaneDefinition)
    case split(BreeSplitDefinition)

    private enum CodingKeys: String, CodingKey {
        case pane
        case direction
        case split
        case children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let hasPane = container.contains(.pane)
        let hasDirection = container.contains(.direction)

        if hasPane && hasDirection {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "BreeLayoutNode must not contain both 'pane' and 'direction' keys"
                )
            )
        }

        if hasPane {
            let pane = try container.decode(BreePaneDefinition.self, forKey: .pane)
            self = .pane(pane)
        } else if hasDirection {
            let splitDef = try BreeSplitDefinition(from: decoder)
            self = .split(splitDef)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "BreeLayoutNode must contain either a 'pane' key or a 'direction' key"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .pane(let pane):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try split.encode(to: encoder)
        }
    }
}

struct BreeSplitDefinition: Codable, Sendable, Hashable {
    var direction: BreeSplitDirection
    var split: Double?
    var children: [BreeLayoutNode]

    init(direction: BreeSplitDirection, split: Double? = nil, children: [BreeLayoutNode]) {
        self.direction = direction
        self.split = split
        self.children = children
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        direction = try container.decode(BreeSplitDirection.self, forKey: .direction)
        split = try container.decodeIfPresent(Double.self, forKey: .split)
        children = try container.decode([BreeLayoutNode].self, forKey: .children)
        if children.count != 2 {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Split node requires exactly 2 children, got \(children.count)"
                )
            )
        }
    }

    var clampedSplitPosition: Double {
        let value = split ?? 0.5
        return min(0.9, max(0.1, value))
    }

    var splitOrientation: SplitOrientation {
        switch direction {
        case .horizontal: return .horizontal
        case .vertical: return .vertical
        }
    }
}

enum BreeSplitDirection: String, Codable, Sendable {
    case horizontal
    case vertical
}

struct BreePaneDefinition: Codable, Sendable, Hashable {
    var surfaces: [BreeSurfaceDefinition]

    init(surfaces: [BreeSurfaceDefinition]) {
        self.surfaces = surfaces
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        surfaces = try container.decode([BreeSurfaceDefinition].self, forKey: .surfaces)
        if surfaces.isEmpty {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Pane node must contain at least one surface"
                )
            )
        }
    }
}

struct BreeSurfaceDefinition: Codable, Sendable, Hashable {
    var type: BreeSurfaceType
    var name: String?
    var command: String?
    var cwd: String?
    var env: [String: String]?
    var url: String?
    var focus: Bool?
}

enum BreeSurfaceType: String, Codable, Sendable {
    case terminal
    case browser
    case project
}

struct BreeResolvedCommand: Sendable {
    let command: BreeCommandDefinition
    let sourcePath: String?
}

struct BreeConfigIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable {
        case newWorkspaceActionNotFound
        case newWorkspaceCommandNotFound
        case newWorkspaceCommandRequiresWorkspace
        case schemaError
    }

    let kind: Kind
    let settingName: String
    let commandName: String?
    let sourcePath: String?
    let message: String?

    init(
        kind: Kind,
        settingName: String,
        commandName: String? = nil,
        sourcePath: String? = nil,
        message: String? = nil
    ) {
        self.kind = kind
        self.settingName = settingName
        self.commandName = commandName
        self.sourcePath = sourcePath
        self.message = message
    }

    var id: String {
        [
            kind.rawValue,
            settingName,
            commandName ?? "",
            sourcePath ?? "",
            message ?? ""
        ].joined(separator: "|")
    }

    var logMessage: String {
        switch kind {
        case .newWorkspaceActionNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded action"
        case .newWorkspaceCommandNotFound:
            return "\(settingName) '\(commandName ?? "")' does not match any loaded command"
        case .newWorkspaceCommandRequiresWorkspace:
            return "\(settingName) '\(commandName ?? "")' must reference a workspace command"
        case .schemaError:
            return "\(settingName) has a schema error: \(message ?? "unknown error")"
        }
    }
}

@MainActor
final class BreeConfigStore: ObservableObject {
    /// Plus-menu rows when `ui.newWorkspace.contextMenu` is not configured.
    /// Feature-gated rows (browser) are filtered at menu-build time by
    /// `AppDelegate.isBuiltInActionAvailableInNewWorkspaceMenu` so a flag flip
    /// takes effect without a config reload.
    static let defaultNewWorkspaceContextMenu: [BreeConfigContextMenuItem] = [
        .action(BreeConfigContextMenuActionItem(action: BreeSurfaceTabBarBuiltInAction.newWorkspace.configID)),
        .action(BreeConfigContextMenuActionItem(action: BreeSurfaceTabBarBuiltInAction.newTerminal.configID)),
        .action(BreeConfigContextMenuActionItem(action: BreeSurfaceTabBarBuiltInAction.newBrowser.configID)),
    ]

    @Published private(set) var loadedCommands: [BreeCommandDefinition] = []
    @Published private(set) var loadedActions: [BreeResolvedConfigAction] = []
    @Published private(set) var newWorkspaceCommandName: String?
    @Published private(set) var newWorkspaceActionID: String?
    @Published private(set) var newWorkspaceContextMenuItems: [BreeResolvedConfigContextMenuItem] = []
    @Published private(set) var newWorkspaceContextMenuIsConfigured = false
    /// Resolved per-cwd workspace group customization, keyed by the JSON cwd key.
    /// Use `resolveWorkspaceGroupConfig(forCwd:)` to find the best match for an
    /// anchor workspace's cwd. Empty when no `workspaceGroups.byCwd` block is
    /// configured.
    @Published private(set) var workspaceGroupConfigs: [BreeResolvedWorkspaceGroupConfig] = []
    @Published private(set) var surfaceTabBarButtons: [BreeSurfaceTabBarButton] = BreeSurfaceTabBarButton.defaults
    /// Original action-registry reference keyed by resolved surface-tab button id.
    /// Inline buttons have no entry; this survives resolution so discovery UI
    /// never has to infer action identity from equal payloads.
    @Published private(set) var surfaceTabBarActionReferenceIDs: [String: String] = [:]
    @Published private(set) var notificationHooks: [BreeResolvedNotificationHook] = []
    @Published private(set) var configurationIssues: [BreeConfigIssue] = []
    @Published private(set) var configRevision: UInt64 = 0

    /// Which config file each command came from, keyed by command id.
    private(set) var commandSourcePaths: [String: String] = [:]
    private(set) var actionLookup: [String: BreeResolvedConfigAction] = [:]
    private(set) var settingPresets: [String: BreeSettingValue] = [:]
    private(set) var surfaceTabBarButtonSourcePath: String?
    private(set) var surfaceTabBarCommandSourcePaths: [String: String] = [:]
    private(set) var newWorkspaceActionSourcePath: String?

    private(set) var localConfigPath: String?
    private weak var tabManager: TabManager?
    let globalConfigPath: String
    private let fileWatchingEnabled: Bool

    nonisolated static func defaultGlobalConfigPath() -> String {
        BreeIdentity.currentGlobalConfigFile().path
    }

    private struct ActionEntry {
        let definition: BreeConfigActionDefinition
        let actionSourcePath: String?
        let iconSourcePath: String?
    }

    private struct ResolvedSurfaceTabBarButtonEntry {
        let button: BreeSurfaceTabBarButton
        let terminalCommandSourcePath: String?
        let actionReferenceID: String?
    }

    private struct ResolvedSurfaceTabBarButtons {
        let buttons: [BreeSurfaceTabBarButton]
        let terminalCommandSourcePaths: [String: String]
        let actionReferenceIDs: [String: String]
    }

    private struct ResolvedContextMenuItems {
        let items: [BreeResolvedConfigContextMenuItem]
        let issues: [BreeConfigIssue]
    }

    private struct NewWorkspaceCommandResolution {
        let command: BreeResolvedCommand?
        let issue: BreeConfigIssue?
    }

    private struct NewWorkspaceActionResolution {
        let action: BreeResolvedConfigAction?
        let command: BreeResolvedCommand?
        let issue: BreeConfigIssue?
    }

    private struct ParsedConfigCacheEntry {
        let fileSize: UInt64
        let modificationDate: Date?
        let workspaceColorPaletteFingerprint: String
        let config: BreeConfigFile?
        let issue: BreeConfigIssue?
    }

    private struct ParsedConfigResult {
        let config: BreeConfigFile?
        let issue: BreeConfigIssue?
    }

    private struct PackLoadBudget {
        static let maxFiles = 32
        static let maxFileBytes: UInt64 = 512 * 1024
        static let maxTotalBytes: UInt64 = 2 * 1024 * 1024

        var filesVisited = 0
        var bytesReserved: UInt64 = 0
    }

    private struct ConfigEntry {
        let path: String
        let sourcePath: String
        let config: BreeConfigFile
    }

    private var surfaceTabBarWorkspaceCommands: [String: BreeResolvedCommand] = [:]
    private var resolvedNewWorkspaceCommandCache: BreeResolvedCommand?
    private var resolvedNewWorkspaceActionCache: BreeResolvedConfigAction?
    private var parsedConfigCache: [String: ParsedConfigCacheEntry] = [:]
    private var lifetimeCancellables = Set<AnyCancellable>()
    private var trackingCancellables = Set<AnyCancellable>()
    // The local config still uses a bespoke DispatchSource watcher because it
    // performs search-directory *path re-resolution* (not just reload-on-change).
    // The global config and hook files use BreeFileWatch.FileWatcher.
    private var localFileWatchSource: DispatchSourceFileSystemObject?
    private var localFileDescriptor: Int32 = -1
    private var localConfigSearchDirectory: String?
    private var hookWatchers: [String: FileWatcher] = [:]
    private var hookWatchTasks: [String: Task<Void, Never>] = [:]
    private var localFallbackDirectoryWatchSource: DispatchSourceFileSystemObject?
    private var localFallbackDirectoryDescriptor: Int32 = -1
    private var globalWatcher: FileWatcher?
    private var globalWatchTask: Task<Void, Never>?
    private let watchQueue = DispatchQueue(label: "com.bree.config-file-watch")

    private static let maxReattachAttempts = 5
    private static let reattachDelay: TimeInterval = 0.5

    private static func searchDirectoryForLocalConfigPath(_ path: String) -> String {
        let configDirectory = (path as NSString).deletingLastPathComponent
        if BreeIdentity.isProjectDirectoryName((configDirectory as NSString).lastPathComponent) {
            return (configDirectory as NSString).deletingLastPathComponent
        }
        return configDirectory
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    init(
        globalConfigPath: String = BreeConfigStore.defaultGlobalConfigPath(),
        localConfigPath: String? = nil,
        startFileWatchers: Bool = false
    ) {
        self.globalConfigPath = globalConfigPath
        self.localConfigPath = localConfigPath
        self.fileWatchingEnabled = startFileWatchers
        self.localConfigSearchDirectory = localConfigPath.map(Self.searchDirectoryForLocalConfigPath(_:))
        NotificationCenter.default.publisher(for: BreeActionTrust.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.loadAll()
            }
            .store(in: &lifetimeCancellables)
        if startFileWatchers {
            if localConfigPath != nil {
                startLocalFileWatcher()
            }
            startGlobalWatching()
        }
    }

    deinit {
        localFileWatchSource?.cancel()
        localFallbackDirectoryWatchSource?.cancel()
        hookWatchTasks.values.forEach { $0.cancel() }
        globalWatchTask?.cancel()
    }

    // MARK: - Public API

    func wireDirectoryTracking(tabManager: TabManager) {
        trackingCancellables.removeAll()
        self.tabManager = tabManager

        tabManager.selectedTabIdPublisher
            .compactMap { [weak tabManager] tabId -> Workspace? in
                guard let tabId, let tabManager else { return nil }
                return tabManager.tabs.first(where: { $0.id == tabId })
            }
            .removeDuplicates(by: { $0.id == $1.id })
            .map { workspace -> AnyPublisher<String?, Never> in
                workspace.$surfaceTabBarDirectory.eraseToAnyPublisher()
            }
            .switchToLatest()
            .removeDuplicates()
            .sink { [weak self] directory in
                self?.updateLocalConfigPath(directory)
            }
            .store(in: &trackingCancellables)

        // The Architecture window follows the focused workspace's directory.
        tabManager.selectedTabIdPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak tabManager] _ in
                if let workspace = tabManager?.selectedWorkspace { ArchitectureWindowController.shared.follow(workspace) }
            }
            .store(in: &trackingCancellables)
        NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)
            .receive(on: DispatchQueue.main)
            .sink { notification in
                if let workspace = notification.object as? Workspace {
                    ArchitectureWindowController.shared.workspaceDirectoryChanged(workspace)
                }
            }
            .store(in: &trackingCancellables)

        // Pane tab bar buttons that depend on the workspace directory (Obsidian) or on
        // open panels (Files, Architecture) are rebuilt when either changes.
        NotificationCenter.default.publisher(for: .workspaceCurrentDirectoryDidChange)
            .merge(with: NotificationCenter.default.publisher(for: .surfaceTabBarDynamicStateDidChange))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applySurfaceTabBarButtonsToCurrentManager() }
            .store(in: &trackingCancellables)

        tabManager.tabsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySurfaceTabBarButtonsToCurrentManager()
            }
            .store(in: &trackingCancellables)

        updateLocalConfigPath(tabManager.selectedWorkspace?.surfaceTabBarDirectory)
    }

    func notificationHooks(startingFrom directory: String?) -> [BreeResolvedNotificationHook] {
        let globalConfig = parseConfig(at: globalConfigPath).config
        let localConfigs: [(path: String, config: BreeConfigFile)]
        if let directory, !directory.isEmpty {
            localConfigs = findBreeConfigHierarchy(startingFrom: directory).compactMap { path in
                parseConfig(at: path).config.map { (path: path, config: $0) }
            }
        } else {
            localConfigs = []
        }
        return resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localConfigs
        )
    }

    private func updateLocalConfigPath(_ directory: String?) {
        let newPath: String?
        if let directory, !directory.isEmpty {
            localConfigSearchDirectory = directory
            newPath = resolvedLocalConfigPath(startingFrom: directory)
        } else {
            localConfigSearchDirectory = nil
            newPath = nil
        }

        guard newPath != localConfigPath else { return }
        stopLocalFileWatcher()
        localConfigPath = newPath
        if fileWatchingEnabled, newPath != nil {
            startLocalFileWatcher()
        }
        loadAll()
    }

    private func resolvedLocalConfigPath(startingFrom directory: String) -> String {
        findBreeConfig(startingFrom: directory)
            ?? defaultLocalConfigPath(startingFrom: directory)
    }

    private func defaultLocalConfigPath(startingFrom directory: String) -> String {
        BreeIdentity.current.projectConfigCandidates(in: directory)[0]
    }

    private func findBreeConfig(startingFrom directory: String) -> String? {
        var current = directory
        let fs = FileManager.default
        while true {
            let candidates = BreeIdentity.current.projectConfigCandidates(in: current)
            for candidate in candidates where fs.fileExists(atPath: candidate) {
                return candidate
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return nil
    }

    private func findBreeConfigHierarchy(startingFrom directory: String) -> [String] {
        var current = directory
        let fs = FileManager.default
        var paths: [String] = []
        while true {
            let candidates = BreeIdentity.current.projectConfigCandidates(in: current)
            if let candidate = candidates.first(where: { fs.fileExists(atPath: $0) }) {
                paths.append(candidate)
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current { break }
            current = parent
        }
        return paths.reversed()
    }

    func loadAll() {
        var commands: [BreeCommandDefinition] = []
        var seenNames = Set<String>()
        var sourcePaths: [String: String] = [:]
        var configuredNewWorkspaceCommandName: String?
        var configuredNewWorkspaceCommandSourcePath: String?
        var configuredNewWorkspaceActionID: String?
        var configuredNewWorkspaceActionSourcePath: String?
        var configuredNewWorkspaceContextMenu: [BreeConfigContextMenuItem]?
        var configuredNewWorkspaceContextMenuSourcePath: String?
        var configuredSurfaceTabBarButtons: [BreeSurfaceTabBarButton]?
        var configuredSurfaceTabBarButtonSourcePath: String?
        let localPath = localConfigPath
        let localParseResult = localPath.map { parseConfig(at: $0) }
        let globalParseResult = parseConfig(at: globalConfigPath)
        let localConfig = localParseResult?.config
        let globalConfig = globalParseResult.config
        var issues = [BreeConfigIssue]()
        if let issue = localParseResult?.issue {
            issues.append(issue)
        }
        if let issue = globalParseResult.issue {
            issues.append(issue)
        }
        var globalPackWatchPaths: [String] = []
        let globalPackEntries = packEntries(
            declaredBy: globalConfig,
            sourcePath: globalConfigPath,
            inheritedSourcePath: globalConfigPath,
            issues: &issues,
            watchPaths: &globalPackWatchPaths
        )
        var localPackWatchPaths: [String] = []
        let localPackEntries = packEntries(
            declaredBy: localConfig,
            sourcePath: localPath,
            inheritedSourcePath: nil,
            issues: &issues,
            watchPaths: &localPackWatchPaths
        )
        let localHookPaths = resolvedLocalNotificationHookPaths(fallbackLocalPath: localPath)
        let localHookParseResults = localHookPaths.map { path in
            (path: path, result: parseConfig(at: path))
        }
        for hookParseResult in localHookParseResults {
            guard hookParseResult.path != localPath,
                  let issue = hookParseResult.result.issue else { continue }
            issues.append(issue)
        }
        let localActions = mergedActionEntries(
            primary: localConfig.map {
                actionEntries(from: $0.actions, actionSourcePath: localPath, iconSourcePath: localPath)
            } ?? [:],
            fallback: actionEntries(from: localPackEntries)
        )
        let globalActions = mergedActionEntries(
            primary: globalConfig.map {
                actionEntries(
                    from: $0.actions,
                    actionSourcePath: globalConfigPath,
                    iconSourcePath: globalConfigPath
                )
            } ?? [:],
            fallback: actionEntries(from: globalPackEntries)
        )
        let localDirectEntries: [ConfigEntry] = {
            guard let localPath, let localConfig else { return [] }
            return [ConfigEntry(path: localPath, sourcePath: localPath, config: localConfig)]
        }()
        let globalDirectEntries = globalConfig.map {
            [ConfigEntry(path: globalConfigPath, sourcePath: globalConfigPath, config: $0)]
        } ?? []
        let localConfigEntries = localDirectEntries + Array(localPackEntries.reversed())
        let globalConfigEntries = globalDirectEntries + Array(globalPackEntries.reversed())
        let packWatchPaths = globalPackWatchPaths + localPackWatchPaths

        // Local config takes precedence
        for entry in localConfigEntries {
            let localConfig = entry.config
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceActionID = localConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = entry.sourcePath
            }
            if configuredNewWorkspaceContextMenu == nil,
               let contextMenu = localConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = entry.sourcePath
            }
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceCommand = localConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = entry.sourcePath
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = localConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = surfaceTabBarButtons(buttons, from: entry)
                configuredSurfaceTabBarButtonSourcePath = entry.sourcePath
            }
            for command in localConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = entry.sourcePath
                }
            }
        }

        // Global config fills in the rest
        for entry in globalConfigEntries {
            let globalConfig = entry.config
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceActionID = globalConfig.ui?.newWorkspace?.action {
                configuredNewWorkspaceActionID = newWorkspaceActionID
                configuredNewWorkspaceActionSourcePath = entry.sourcePath
            }
            if configuredNewWorkspaceContextMenu == nil,
               let contextMenu = globalConfig.ui?.newWorkspace?.contextMenu {
                configuredNewWorkspaceContextMenu = contextMenu
                configuredNewWorkspaceContextMenuSourcePath = entry.sourcePath
            }
            if configuredNewWorkspaceActionID == nil,
               configuredNewWorkspaceCommandName == nil,
               let newWorkspaceCommand = globalConfig.newWorkspaceCommand {
                configuredNewWorkspaceCommandName = newWorkspaceCommand
                configuredNewWorkspaceCommandSourcePath = entry.sourcePath
            }
            if configuredSurfaceTabBarButtons == nil,
               let buttons = globalConfig.surfaceTabBarButtons {
                configuredSurfaceTabBarButtons = surfaceTabBarButtons(buttons, from: entry)
                configuredSurfaceTabBarButtonSourcePath = entry.sourcePath
            }
            for command in globalConfig.commands {
                if !seenNames.contains(command.name) {
                    commands.append(command)
                    seenNames.insert(command.name)
                    sourcePaths[command.id] = entry.sourcePath
                }
            }
        }

        let resolvedActions = resolvedActionRegistry(
            globalActions: globalActions,
            localActions: localActions,
            commands: commands,
            commandSourcePaths: sourcePaths
        )
        let resolvedActionLookup = Dictionary(uniqueKeysWithValues: resolvedActions.map { ($0.id, $0) })
        let configuredButtons = configuredSurfaceTabBarButtons ?? BreeSurfaceTabBarButton.defaults
        let defaultResolvedButtons = (try? BreeSurfaceTabBarButton.defaults.map {
            try $0.resolved(actions: resolvedActionLookup, codingPath: [])
        }) ?? [
            .builtIn(.newTerminal),
            .builtIn(.newBrowser),
            .builtIn(.splitRight),
            .builtIn(.splitDown),
            .builtIn(.toggleWiki),
            .builtIn(.toggleArchitecture),
            .builtIn(.showBoard),
            .builtIn(.newWindow)
        ]
        let resolvedButtons = resolvedSurfaceTabBarButtons(
            configuredButtons,
            actions: resolvedActionLookup,
            settingName: "ui.surfaceTabBar.buttons"
        ) ?? ResolvedSurfaceTabBarButtons(
            buttons: defaultResolvedButtons,
            terminalCommandSourcePaths: [:],
            actionReferenceIDs: [:]
        )
        let resolvedWorkspaceButtons = resolvedSurfaceTabBarWorkspaceCommands(
            resolvedButtons.buttons,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceAction = resolvedConfiguredNewWorkspaceAction(
            actionID: configuredNewWorkspaceActionID,
            actionSourcePath: configuredNewWorkspaceActionSourcePath,
            commandName: configuredNewWorkspaceCommandName,
            commandSourcePath: configuredNewWorkspaceCommandSourcePath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNewWorkspaceContextMenuItems = appendingAutoNewWorkspaceMenuActions(
            to: resolvedConfigContextMenuItems(
                configuredNewWorkspaceContextMenu ?? Self.defaultNewWorkspaceContextMenu,
                actions: resolvedActionLookup,
                commands: commands,
                sourcePaths: sourcePaths,
                settingName: "ui.newWorkspace.contextMenu",
                settingSourcePath: configuredNewWorkspaceContextMenuSourcePath
            ),
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths
        )
        let resolvedNotificationHooks = resolveNotificationHooks(
            globalConfig: globalConfig,
            localConfigs: localHookParseResults.compactMap { entry in
                entry.result.config.map { (path: entry.path, config: $0) }
            }
        )
        loadedCommands = commands
        loadedActions = resolvedActions
        settingPresets = mergedSettingPresets(from: globalConfigEntries)
        commandSourcePaths = sourcePaths
        actionLookup = resolvedActionLookup
        newWorkspaceActionID = configuredNewWorkspaceActionID
        newWorkspaceActionSourcePath = configuredNewWorkspaceActionSourcePath
        newWorkspaceCommandName = configuredNewWorkspaceCommandName
        newWorkspaceContextMenuItems = resolvedNewWorkspaceContextMenuItems.items
        newWorkspaceContextMenuIsConfigured = configuredNewWorkspaceContextMenu != nil
        let resolvedGroupConfigs = resolveWorkspaceGroupConfigsFromLayers(
            localConfig: localConfig,
            globalConfig: globalConfig,
            localPath: localPath,
            globalPath: globalConfigPath,
            actions: resolvedActionLookup,
            commands: commands,
            sourcePaths: sourcePaths,
            issues: &issues
        )
        workspaceGroupConfigs = resolvedGroupConfigs
        surfaceTabBarButtonSourcePath = configuredSurfaceTabBarButtonSourcePath
        surfaceTabBarCommandSourcePaths = resolvedButtons.terminalCommandSourcePaths
        let visibleSurfaceButtonIDs = Set(resolvedWorkspaceButtons.buttons.map(\.id))
        surfaceTabBarActionReferenceIDs = resolvedButtons.actionReferenceIDs.filter {
            visibleSurfaceButtonIDs.contains($0.key)
        }
        surfaceTabBarWorkspaceCommands = resolvedWorkspaceButtons.workspaceCommands
        surfaceTabBarButtons = resolvedWorkspaceButtons.buttons
        notificationHooks = resolvedNotificationHooks
        resolvedNewWorkspaceActionCache = resolvedNewWorkspaceAction.action
        resolvedNewWorkspaceCommandCache = resolvedNewWorkspaceAction.command
        if let issue = resolvedNewWorkspaceAction.issue {
            issues.append(issue)
        }
        issues.append(contentsOf: resolvedNewWorkspaceContextMenuItems.issues)
        configurationIssues = issues
        if fileWatchingEnabled {
            updateLocalHookFileWatchers(
                paths: localHookPaths + packWatchPaths,
                primaryLocalPath: localPath
            )
        }
        applySurfaceTabBarButtonsToCurrentManager()
        configRevision &+= 1
    }

    private func resolvedLocalNotificationHookPaths(fallbackLocalPath: String?) -> [String] {
        if let searchDirectory = localConfigSearchDirectory {
            var paths = findBreeConfigHierarchy(startingFrom: searchDirectory)
            if let fallbackLocalPath, !paths.contains(fallbackLocalPath) {
                paths.append(fallbackLocalPath)
            }
            return paths
        }
        return fallbackLocalPath.map { [$0] } ?? []
    }

    private func resolveNotificationHooks(
        globalConfig: BreeConfigFile?,
        localConfigs: [(path: String, config: BreeConfigFile)]
    ) -> [BreeResolvedNotificationHook] {
        var hooks: [BreeResolvedNotificationHook] = []
        if let globalHooks = globalConfig?.notifications?.hooks {
            hooks.append(contentsOf: resolvedNotificationHooks(
                globalHooks,
                sourcePath: globalConfigPath
            ))
        }

        for entry in localConfigs {
            guard let notifications = entry.config.notifications else { continue }
            if notifications.hooksMode == .replace {
                hooks.removeAll()
            }
            if let localHooks = notifications.hooks {
                hooks.append(contentsOf: resolvedNotificationHooks(
                    localHooks,
                    sourcePath: entry.path
                ))
            }
        }
        return hooks
    }

    private func resolvedNotificationHooks(
        _ definitions: [BreeNotificationHookDefinition],
        sourcePath: String
    ) -> [BreeResolvedNotificationHook] {
        let cwd = BreeButtonIcon.projectRoot(forConfigPath: sourcePath)
        let canonicalSourcePath = Self.canonicalPath(sourcePath)
        let canonicalGlobalConfigPath = Self.canonicalPath(globalConfigPath)
        let isGlobalHook = canonicalSourcePath == canonicalGlobalConfigPath
        return definitions.compactMap { definition in
            guard definition.enabled else { return nil }
            let trustDescriptor: BreeActionTrustDescriptor?
            if isGlobalHook {
                trustDescriptor = nil
            } else {
                trustDescriptor = BreeActionTrustDescriptor(
                    actionID: definition.id,
                    kind: "notificationHook",
                    command: definition.command,
                    target: "notificationPolicy",
                    workspaceCommand: nil,
                    configPath: canonicalSourcePath,
                    projectRoot: Self.canonicalPath(cwd),
                    iconFingerprint: nil
                )
            }
            return BreeResolvedNotificationHook(
                id: definition.id,
                command: definition.command,
                timeoutSeconds: definition.resolvedTimeoutSeconds,
                sourcePath: sourcePath,
                cwd: cwd,
                trustDescriptor: trustDescriptor
            )
        }
    }

    private func surfaceTabBarButtons(
        _ buttons: [BreeSurfaceTabBarButton],
        from entry: ConfigEntry
    ) -> [BreeSurfaceTabBarButton] {
        buttons.map { button in
            var sourced = button
            sourced.actionSourcePath = sourced.actionSourcePath ?? entry.sourcePath
            if sourced.icon != nil {
                sourced.iconSourcePath = sourced.iconSourcePath ?? entry.path
            }
            return sourced
        }
    }

    private func actionEntries(
        from actions: [String: BreeConfigActionDefinition],
        actionSourcePath: String?,
        iconSourcePath: String?
    ) -> [String: ActionEntry] {
        var entries: [String: ActionEntry] = [:]
        for (id, definition) in actions {
            entries[canonicalActionID(id)] = ActionEntry(
                definition: definition,
                actionSourcePath: actionSourcePath,
                iconSourcePath: iconSourcePath
            )
        }
        return entries
    }

    private func actionEntries(from entries: [ConfigEntry]) -> [String: ActionEntry] {
        var merged: [String: ActionEntry] = [:]
        for entry in entries {
            merged = mergedActionEntries(
                primary: actionEntries(
                    from: entry.config.actions,
                    actionSourcePath: entry.sourcePath,
                    iconSourcePath: entry.path
                ),
                fallback: merged
            )
        }
        return merged
    }

    private func mergedSettingPresets(from entries: [ConfigEntry]) -> [String: BreeSettingValue] {
        var merged: [String: BreeSettingValue] = [:]
        for entry in entries {
            for (name, preset) in entry.config.settingPresets where merged[name] == nil {
                merged[name] = preset
            }
        }
        return merged
    }

    private func mergedActionEntries(
        primary: [String: ActionEntry],
        fallback: [String: ActionEntry]
    ) -> [String: ActionEntry] {
        fallback.merging(primary) { fallbackEntry, primaryEntry in
            let primaryDefinition = primaryEntry.definition
            let fallbackDefinition = fallbackEntry.definition
            return ActionEntry(
                definition: BreeConfigActionDefinition(
                    action: primaryDefinition.action ?? fallbackDefinition.action,
                    title: primaryDefinition.title ?? fallbackDefinition.title,
                    subtitle: primaryDefinition.subtitle ?? fallbackDefinition.subtitle,
                    keywords: primaryDefinition.keywords ?? fallbackDefinition.keywords,
                    palette: primaryDefinition.palette ?? fallbackDefinition.palette,
                    shortcut: primaryDefinition.shortcut ?? fallbackDefinition.shortcut,
                    icon: primaryDefinition.icon ?? fallbackDefinition.icon,
                    tooltip: primaryDefinition.tooltip ?? fallbackDefinition.tooltip,
                    confirm: primaryDefinition.confirm ?? fallbackDefinition.confirm,
                    terminalCommandTarget: primaryDefinition.terminalCommandTarget
                        ?? fallbackDefinition.terminalCommandTarget,
                    newWorkspaceMenu: primaryDefinition.newWorkspaceMenu
                        ?? fallbackDefinition.newWorkspaceMenu
                ),
                actionSourcePath: primaryDefinition.action == nil
                    ? fallbackEntry.actionSourcePath
                    : primaryEntry.actionSourcePath,
                iconSourcePath: primaryDefinition.icon == nil
                    ? fallbackEntry.iconSourcePath
                    : primaryEntry.iconSourcePath
            )
        }
    }

    private func packEntries(
        declaredBy config: BreeConfigFile?,
        sourcePath: String?,
        inheritedSourcePath: String?,
        issues: inout [BreeConfigIssue],
        watchPaths: inout [String]
    ) -> [ConfigEntry] {
        guard let config, let sourcePath else { return [] }
        var pathStack = Set<String>()
        var budget = PackLoadBudget()
        return packEntries(
            references: config.packs,
            declaringConfigPath: sourcePath,
            inheritedSourcePath: inheritedSourcePath,
            depth: 0,
            pathStack: &pathStack,
            budget: &budget,
            issues: &issues,
            watchPaths: &watchPaths
        )
    }

    private func packEntries(
        references: [BreeConfigPackReference],
        declaringConfigPath: String,
        inheritedSourcePath: String?,
        depth: Int,
        pathStack: inout Set<String>,
        budget: inout PackLoadBudget,
        issues: inout [BreeConfigIssue],
        watchPaths: inout [String]
    ) -> [ConfigEntry] {
        guard depth < 8 else {
            issues.append(schemaIssue(path: declaringConfigPath, message: String(localized: "config.pack.error.nestingTooDeep", defaultValue: "Pack nesting is too deep.", table: "ConfigPackErrors")))
            return []
        }

        var entries: [ConfigEntry] = []
        for reference in references {
            // Charge every declared reference before any path, cycle, existence,
            // or recovery-watch work so malformed/missing fanout is bounded too.
            guard budget.filesVisited < PackLoadBudget.maxFiles else {
                issues.append(schemaIssue(
                    path: declaringConfigPath,
                    message: String(localized: "config.pack.error.loadLimitExceeded", defaultValue: "Pack loading limit exceeded.", table: "ConfigPackErrors")
                ))
                break
            }
            budget.filesVisited += 1

            let path = resolvedPackPath(reference.path, relativeToConfig: declaringConfigPath)
            let canonical = Self.canonicalPath(path)
            guard !pathStack.contains(canonical) else {
                issues.append(schemaIssue(path: declaringConfigPath, message: String(localized: "config.pack.error.cycleIgnored", defaultValue: "Pack cycle ignored.", table: "ConfigPackErrors")))
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else {
                issues.append(schemaIssue(path: path, message: String(localized: "config.pack.error.fileMissing", defaultValue: "Pack file does not exist.", table: "ConfigPackErrors")))
                if let recoveryWatchPath = packRecoveryWatchPath(for: path) {
                    watchPaths.append(recoveryWatchPath)
                }
                continue
            }

            watchPaths.append(path)

            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            guard let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value else {
                issues.append(schemaIssue(path: path, message: String(localized: "config.pack.error.fileSizeUnreadable", defaultValue: "Pack file size could not be read.", table: "ConfigPackErrors")))
                continue
            }
            guard fileSize <= PackLoadBudget.maxFileBytes else {
                issues.append(schemaIssue(
                    path: path,
                    message: String(localized: "config.pack.error.loadLimitExceeded", defaultValue: "Pack loading limit exceeded.", table: "ConfigPackErrors")
                ))
                continue
            }
            guard budget.bytesReserved <= PackLoadBudget.maxTotalBytes - fileSize else {
                issues.append(schemaIssue(
                    path: declaringConfigPath,
                    message: String(localized: "config.pack.error.loadLimitExceeded", defaultValue: "Pack loading limit exceeded.", table: "ConfigPackErrors")
                ))
                break
            }
            budget.bytesReserved += fileSize

            pathStack.insert(canonical)
            let result = parseConfig(at: path)
            if let issue = result.issue {
                issues.append(issue)
            }
            if let packConfig = result.config {
                entries.append(contentsOf: packEntries(
                    references: packConfig.packs,
                    declaringConfigPath: path,
                    inheritedSourcePath: inheritedSourcePath,
                    depth: depth + 1,
                    pathStack: &pathStack,
                    budget: &budget,
                    issues: &issues,
                    watchPaths: &watchPaths
                ))
                entries.append(ConfigEntry(
                    path: path,
                    sourcePath: inheritedSourcePath ?? path,
                    config: packConfig
                ))
            }
            pathStack.remove(canonical)
        }
        return entries
    }

    private func packRecoveryWatchPath(for path: String) -> String? {
        var candidate = (path as NSString).deletingLastPathComponent
        while !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { return nil }
            candidate = parent
        }
        return nil
    }

    private func resolvedPackPath(_ rawPath: String, relativeToConfig configPath: String) -> String {
        let expanded = (rawPath as NSString).expandingTildeInPath
        let resolved: String
        if (expanded as NSString).isAbsolutePath {
            resolved = expanded
        } else {
            let base = (configPath as NSString).deletingLastPathComponent
            resolved = (base as NSString).appendingPathComponent(expanded)
        }

        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory), isDirectory.boolValue {
            return ((resolved as NSString).appendingPathComponent("bree.pack.json") as NSString).standardizingPath
        }
        return (resolved as NSString).standardizingPath
    }

    private func sanitizeConfigText(_ text: String) -> String {
        let dangerous: Set<Unicode.Scalar> = [
            "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
            "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
            "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
            "\u{FEFF}",
        ]
        let filtered = String(text.unicodeScalars.filter { !dangerous.contains($0) })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sanitizeConfigText(_ text: String, fallback: String) -> String {
        let sanitized = sanitizeConfigText(text)
        return sanitized.isEmpty ? fallback : sanitized
    }

    private func resolvedActionRegistry(
        globalActions: [String: ActionEntry],
        localActions: [String: ActionEntry],
        commands: [BreeCommandDefinition],
        commandSourcePaths: [String: String]
    ) -> [BreeResolvedConfigAction] {
        var registry = Dictionary(
            uniqueKeysWithValues: BreeSurfaceTabBarBuiltInAction.allCases.map {
                ($0.configID, BreeResolvedConfigAction.builtIn($0))
            }
        )

        func apply(_ entries: [String: ActionEntry]) {
            for (id, entry) in entries {
                // A setting action rewrites the global bree.json, so only the
                // user's global config (and packs it references, which inherit
                // its source path) may declare one. A project config or project
                // pack could otherwise ship a harmless-looking button that flips
                // a security setting such as automation.socketControlMode.
                if case .setting = entry.definition.action,
                   !BreeSettingActionTrust.allowsSettingAction(
                       actionSourcePath: entry.actionSourcePath,
                       globalConfigPath: globalConfigPath
                   ) {
                    NSLog("[BreeConfig] setting action '%@' ignored: setting actions are only read from the global bree.json", id)
                    continue
                }
                let registryID = BreeSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
                if let existing = registry[registryID] {
                    // Only the global config may retitle, rebind, or drop the
                    // confirm of a setting action; a project override would
                    // otherwise dress one up as something harmless.
                    if case .setting = existing.action,
                       !BreeSettingActionTrust.allowsSettingAction(
                           actionSourcePath: entry.actionSourcePath,
                           globalConfigPath: globalConfigPath
                       ) {
                        NSLog("[BreeConfig] override of setting action '%@' ignored: only the global bree.json may change it", id)
                        continue
                    }
                    guard let resolved = existing.applying(
                        entry.definition,
                        actionSourcePath: entry.actionSourcePath,
                        iconSourcePath: entry.iconSourcePath
                    ) else { continue }
                    registry[registryID] = resolved
                } else if let resolved = BreeResolvedConfigAction.fromDefinition(
                    id: id,
                    definition: entry.definition,
                    actionSourcePath: entry.actionSourcePath,
                    iconSourcePath: entry.iconSourcePath
                ) {
                    registry[id] = resolved
                } else {
                    NSLog("[BreeConfig] action '%@' ignored because it does not define a runnable action", id)
                }
            }
        }

        apply(globalActions)
        apply(localActions)

        for command in commands where registry[command.id] == nil {
            let sourcePath = commandSourcePaths[command.id]
            registry[command.id] = BreeResolvedConfigAction(
                id: command.id,
                title: String(
                    localized: "command.breeConfig.customTitle",
                    defaultValue: "Custom: \(sanitizeConfigText(command.name))"
                ),
                subtitle: command.description.map { sanitizeConfigText($0) }
                    ?? String(localized: "command.breeConfig.subtitle", defaultValue: "bree.json"),
                keywords: command.keywords ?? [],
                palette: true,
                shortcut: nil,
                icon: .symbol(command.workspace == nil ? "terminal" : "rectangle.stack.badge.plus"),
                tooltip: command.description,
                action: command.workspace == nil
                    ? .command(command.command ?? "")
                    : .workspaceCommand(command.name),
                confirm: command.confirm,
                terminalCommandTarget: command.workspace == nil ? .currentTerminal : nil,
                actionSourcePath: sourcePath,
                iconSourcePath: nil
            )
        }

        return registry.values.sorted { lhs, rhs in
            lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedSurfaceTabBarButtons(
        _ buttons: [BreeSurfaceTabBarButton],
        actions: [String: BreeResolvedConfigAction],
        settingName: String
    ) -> ResolvedSurfaceTabBarButtons? {
        var resolvedButtons: [BreeSurfaceTabBarButton] = []
        var terminalCommandSourcePaths: [String: String] = [:]
        var actionReferenceIDs: [String: String] = [:]
        resolvedButtons.reserveCapacity(buttons.count)

        for button in buttons {
            // A reference into the reserved `bree.` built-in namespace that this build no longer
            // has (for example a saved `bree.newAgentChat`) skips the button, not the whole bar.
            if case .actionReference(let identifier) = button.action,
               identifier.hasPrefix("bree."),
               actions[canonicalActionID(identifier)] == nil,
               BreeSurfaceTabBarBuiltInAction(configID: identifier) == nil {
                NSLog("[BreeConfig] %@ entry skipped: unknown built-in action '%@'", settingName, identifier)
                continue
            }
            do {
                let resolved = try resolvedSurfaceTabBarButton(button, actions: actions)
                resolvedButtons.append(resolved.button)
                if let actionReferenceID = resolved.actionReferenceID {
                    actionReferenceIDs[resolved.button.id] = actionReferenceID
                }
                guard resolved.button.terminalCommand != nil else { continue }
                if let commandSourcePath = resolved.terminalCommandSourcePath {
                    terminalCommandSourcePaths[resolved.button.id] = commandSourcePath
                }
            } catch {
                NSLog("[BreeConfig] %@ ignored: %@", settingName, String(describing: error))
                return nil
            }
        }

        return ResolvedSurfaceTabBarButtons(
            buttons: resolvedButtons,
            terminalCommandSourcePaths: terminalCommandSourcePaths,
            actionReferenceIDs: actionReferenceIDs
        )
    }

    private func resolvedSurfaceTabBarButton(
        _ button: BreeSurfaceTabBarButton,
        actions: [String: BreeResolvedConfigAction]
    ) throws -> ResolvedSurfaceTabBarButtonEntry {
        guard case .actionReference(let identifier) = button.action else {
            return ResolvedSurfaceTabBarButtonEntry(
                button: button,
                terminalCommandSourcePath: nil,
                actionReferenceID: nil
            )
        }

        let resolvedIdentifier = canonicalActionID(identifier)
        if let entry = actions[resolvedIdentifier] {
            // A project button may show a global setting action, but not
            // relabel it or drop its confirm.
            if case .setting = entry.action,
               !BreeSettingActionTrust.allowsSettingAction(
                   actionSourcePath: button.actionSourcePath,
                   globalConfigPath: globalConfigPath
               ) {
                return ResolvedSurfaceTabBarButtonEntry(
                    button: BreeSurfaceTabBarButton(
                        id: button.id,
                        title: entry.title,
                        icon: entry.icon,
                        tooltip: entry.tooltip ?? entry.title,
                        action: entry.action,
                        confirm: entry.confirm,
                        terminalCommandTarget: nil,
                        actionSourcePath: entry.actionSourcePath,
                        iconSourcePath: entry.iconSourcePath
                    ),
                    terminalCommandSourcePath: nil,
                    actionReferenceID: resolvedIdentifier
                )
            }
            let resolvedButton = BreeSurfaceTabBarButton(
                id: button.id,
                title: button.title ?? entry.title,
                icon: button.icon ?? entry.icon,
                tooltip: button.tooltip ?? entry.tooltip ?? entry.title,
                action: entry.action,
                confirm: button.confirm ?? entry.confirm,
                terminalCommandTarget: button.terminalCommandTarget ?? entry.terminalCommandTarget,
                // Built-in registry entries have no config source, so the
                // declaring button's source stays the trust owner, matching
                // the unregistered built-in fallback below.
                actionSourcePath: entry.actionSourcePath ?? button.actionSourcePath,
                iconSourcePath: button.icon == nil ? entry.iconSourcePath : button.iconSourcePath
            )
            return ResolvedSurfaceTabBarButtonEntry(
                button: resolvedButton,
                terminalCommandSourcePath: resolvedButton.terminalCommand == nil ? nil : entry.actionSourcePath,
                actionReferenceID: resolvedIdentifier
            )
        }

        if let builtIn = BreeSurfaceTabBarBuiltInAction(configID: identifier) {
            return ResolvedSurfaceTabBarButtonEntry(
                button: BreeSurfaceTabBarButton(
                    id: button.id,
                    title: button.title,
                    icon: button.icon,
                    tooltip: button.tooltip,
                    action: .builtIn(builtIn),
                    confirm: button.confirm,
                    terminalCommandTarget: button.terminalCommandTarget,
                    actionSourcePath: button.actionSourcePath,
                    iconSourcePath: button.iconSourcePath
                ),
                terminalCommandSourcePath: nil,
                actionReferenceID: builtIn.configID
            )
        }

        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: [],
                debugDescription: "Unknown action reference '\(identifier)'"
            )
        )
    }

    private func applySurfaceTabBarButtonsToCurrentManager() {
        tabManager?.applySurfaceTabBarButtons(
            surfaceTabBarButtons,
            sourcePath: surfaceTabBarButtonSourcePath,
            globalConfigPath: globalConfigPath,
            settingPresets: settingPresets,
            terminalCommandSourcePaths: surfaceTabBarCommandSourcePaths,
            workspaceCommands: surfaceTabBarWorkspaceCommands
        )
    }

    private func resolvedSurfaceTabBarWorkspaceCommands(
        _ buttons: [BreeSurfaceTabBarButton],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String]
    ) -> (buttons: [BreeSurfaceTabBarButton], workspaceCommands: [String: BreeResolvedCommand]) {
        var visibleButtons: [BreeSurfaceTabBarButton] = []
        var workspaceCommands: [String: BreeResolvedCommand] = [:]
        visibleButtons.reserveCapacity(buttons.count)

        for button in buttons {
            guard let commandName = button.workspaceCommandName else {
                visibleButtons.append(button)
                continue
            }

            guard let command = resolvedWorkspaceCommand(
                named: commandName,
                settingName: "surfaceTabBarButtons action",
                commands: commands,
                sourcePaths: sourcePaths
            ) else {
                NSLog(
                    "[BreeConfig] surfaceTabBarButtons action '%@' hidden because workspace command '%@' is unavailable",
                    button.id,
                    commandName
                )
                continue
            }

            visibleButtons.append(button)
            workspaceCommands[button.id] = command
        }

        return (visibleButtons, workspaceCommands)
    }

    func resolvedNewWorkspaceCommand() -> BreeResolvedCommand? {
        resolvedNewWorkspaceCommandCache
    }

    func resolvedNewWorkspaceAction() -> BreeResolvedConfigAction? {
        resolvedNewWorkspaceActionCache
    }

    func resolvedAction(id: String) -> BreeResolvedConfigAction? {
        actionLookup[canonicalActionID(id)]
    }

    func paletteCustomActions() -> [BreeResolvedConfigAction] {
        let builtInIDs = Set(BreeSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.palette && !builtInIDs.contains(action.id)
        }
    }

    func shortcutActions() -> [BreeResolvedConfigAction] {
        let builtInIDs = Set(BreeSurfaceTabBarBuiltInAction.allCases.map(\.configID))
        return loadedActions.filter { action in
            action.shortcut != nil && (builtInIDs.contains(action.id) || action.actionSourcePath != nil)
        }.sorted { lhs, rhs in
            let lhsPriority = builtInIDs.contains(lhs.id) ? 0 : 1
            let rhsPriority = builtInIDs.contains(rhs.id) ? 0 : 1
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private func resolvedConfiguredNewWorkspaceAction(
        actionID: String?,
        actionSourcePath: String?,
        commandName: String?,
        commandSourcePath: String?,
        actions: [String: BreeResolvedConfigAction],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceActionResolution {
        if let actionID {
            let resolvedActionID = canonicalActionID(actionID)
            guard let action = actions[resolvedActionID] else {
                let issue = BreeConfigIssue(
                    kind: .newWorkspaceActionNotFound,
                    settingName: "ui.newWorkspace.action",
                    commandName: actionID,
                    sourcePath: actionSourcePath
                )
                NSLog("[BreeConfig] %@", issue.logMessage)
                return NewWorkspaceActionResolution(action: nil, command: nil, issue: issue)
            }
            if let actionCommandName = action.workspaceCommandName {
                let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                    named: actionCommandName,
                    settingName: "ui.newWorkspace.action",
                    settingSourcePath: action.actionSourcePath ?? actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                guard commandResolution.issue == nil else {
                    return NewWorkspaceActionResolution(
                        action: nil,
                        command: commandResolution.command,
                        issue: commandResolution.issue
                    )
                }
                return NewWorkspaceActionResolution(
                    action: action,
                    command: commandResolution.command,
                    issue: nil
                )
            }
            return NewWorkspaceActionResolution(action: action, command: nil, issue: nil)
        }

        guard let commandName else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: nil)
        }
        let commandResolution = resolvedConfiguredNewWorkspaceCommand(
            named: commandName,
            settingName: "newWorkspaceCommand",
            settingSourcePath: commandSourcePath,
            commands: commands,
            sourcePaths: sourcePaths
        )
        guard let command = commandResolution.command else {
            return NewWorkspaceActionResolution(action: nil, command: nil, issue: commandResolution.issue)
        }
        return NewWorkspaceActionResolution(
            action: BreeResolvedConfigAction(
                id: command.command.id,
                title: command.command.name,
                subtitle: command.command.description
                    ?? String(localized: "command.breeConfig.subtitle", defaultValue: "bree.json"),
                keywords: command.command.keywords ?? [],
                palette: false,
                shortcut: nil,
                icon: .symbol("rectangle.stack.badge.plus"),
                tooltip: command.command.description,
                action: .workspaceCommand(command.command.name),
                confirm: command.command.confirm,
                terminalCommandTarget: nil,
                actionSourcePath: command.sourcePath,
                iconSourcePath: nil
            ),
            command: command,
            issue: nil
        )
    }

    /// Public lookup: given an anchor workspace's cwd, return the best-matching
    /// resolved group config. Matching uses auto-glob detection (keys with `*`
    /// or `?` are treated as fnmatch globs, others as path prefixes). Longest
    /// matching key wins. Returns nil when nothing matches.
    func resolveWorkspaceGroupConfig(forCwd cwd: String?) -> BreeResolvedWorkspaceGroupConfig? {
        guard let cwd, !cwd.isEmpty, !workspaceGroupConfigs.isEmpty else { return nil }
        let normalizedCwd = Self.normalizeAbsolutePath(cwd)
        var best: (BreeResolvedWorkspaceGroupConfig, Int)?
        for entry in workspaceGroupConfigs {
            guard Self.cwdEntryMatches(entry, cwd: normalizedCwd) else { continue }
            let score = entry.normalizedKey.count
            if best == nil || score > best!.1 {
                best = (entry, score)
            }
        }
        return best?.0
    }

    /// Replace a leading `~` with the user's home directory while preserving
    /// the rest of the pattern (including `*`/`?` glob characters). Unlike
    /// `normalizeAbsolutePath`, this skips `standardizingPath` so trailing
    /// glob segments aren't collapsed.
    private static func expandTildePreservingGlob(_ pattern: String) -> String {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("~") else { return trimmed }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let suffix = trimmed.dropFirst()
        return suffix.isEmpty ? home : home + String(suffix)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("~") {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            let suffix = trimmed.dropFirst()
            return suffix.isEmpty ? home : home + String(suffix)
        }
        return (trimmed as NSString).standardizingPath
    }

    private static func cwdEntryMatches(
        _ entry: BreeResolvedWorkspaceGroupConfig,
        cwd: String
    ) -> Bool {
        let key = entry.normalizedKey
        if entry.isGlob {
            return fnmatchStyle(pattern: key, candidate: cwd)
        }
        if cwd == key { return true }
        // Root prefix `/` is a documented catch-all; without this branch
        // any non-root cwd would be tested against "//" and fail. Other
        // keys append `/` so `/Users/example` doesn't also match
        // `/Users/example-fork`.
        if key == "/" {
            return cwd.hasPrefix("/")
        }
        return cwd.hasPrefix(key + "/")
    }

    /// Minimal fnmatch: `*` matches any run of characters within a path segment
    /// (and across path separators); `?` matches a single character. Sufficient
    /// for the byCwd matching contract — full fnmatch features can come later.
    private static func fnmatchStyle(pattern: String, candidate: String) -> Bool {
        let p = Array(pattern)
        let s = Array(candidate)
        var pi = 0
        var si = 0
        var starP = -1
        var starS = -1
        while si < s.count {
            if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
                pi += 1
                si += 1
            } else if pi < p.count && p[pi] == "*" {
                starP = pi
                starS = si
                pi += 1
            } else if starP != -1 {
                pi = starP + 1
                starS += 1
                si = starS
            } else {
                return false
            }
        }
        while pi < p.count && p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private func resolveWorkspaceGroupConfigsFromLayers(
        localConfig: BreeConfigFile?,
        globalConfig: BreeConfigFile?,
        localPath: String?,
        globalPath: String,
        actions: [String: BreeResolvedConfigAction],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [BreeConfigIssue]
    ) -> [BreeResolvedWorkspaceGroupConfig] {
        var resolved: [String: BreeResolvedWorkspaceGroupConfig] = [:]
        if let globalEntries = globalConfig?.workspaceGroups?.byCwd {
            for (key, entry) in globalEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r
                }
            }
        }
        if let localEntries = localConfig?.workspaceGroups?.byCwd {
            for (key, entry) in localEntries {
                if let r = resolveWorkspaceGroupConfigEntry(
                    key: key, entry: entry, sourcePath: localPath ?? globalPath,
                    actions: actions, commands: commands,
                    sourcePaths: sourcePaths, issues: &issues
                ) {
                    resolved[r.normalizedKey] = r // local overrides global
                }
            }
        }
        return Array(resolved.values).sorted { $0.normalizedKey.count > $1.normalizedKey.count }
    }

    private func resolveWorkspaceGroupConfigEntry(
        key: String,
        entry: BreeConfigWorkspaceGroupEntry,
        sourcePath: String,
        actions: [String: BreeResolvedConfigAction],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String],
        issues: inout [BreeConfigIssue]
    ) -> BreeResolvedWorkspaceGroupConfig? {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let isGlob = trimmed.contains("*") || trimmed.contains("?")
        // Expand `~` in both glob and prefix keys so a key like
        // `~/projects/*` matches workspace cwds that are already normalized to
        // absolute paths (`/Users/<you>/projects/foo`). Prefix keys also go
        // through `standardizingPath` so trailing `/.` and similar are
        // canonicalized.
        let normalizedKey = isGlob
            ? Self.expandTildePreservingGlob(trimmed)
            : Self.normalizeAbsolutePath(trimmed)
        let menuResolution = resolvedConfigContextMenuItems(
            entry.contextMenu,
            actions: actions,
            commands: commands,
            sourcePaths: sourcePaths,
            settingName: "workspaceGroups.byCwd[\(key)].contextMenu",
            settingSourcePath: sourcePath
        )
        issues.append(contentsOf: menuResolution.issues)
        return BreeResolvedWorkspaceGroupConfig(
            originalKey: trimmed,
            normalizedKey: normalizedKey,
            isGlob: isGlob,
            color: entry.color.map(sanitizeConfigText),
            iconSymbol: entry.icon.map(sanitizeConfigText),
            contextMenuItems: menuResolution.items,
            newWorkspacePlacement: WorkspaceGroupNewPlacement(rawString: entry.newWorkspacePlacement)
        )
    }

    private func resolvedConfigContextMenuItems(
        _ configuredItems: [BreeConfigContextMenuItem]?,
        actions: [String: BreeResolvedConfigAction],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String],
        settingName: String,
        settingSourcePath: String?
    ) -> ResolvedContextMenuItems {
        guard let configuredItems, !configuredItems.isEmpty else {
            return ResolvedContextMenuItems(items: [], issues: [])
        }
        var resolvedItems: [BreeResolvedConfigContextMenuItem] = []
        var issues: [BreeConfigIssue] = []
        resolvedItems.reserveCapacity(configuredItems.count)

        for (index, configuredItem) in configuredItems.enumerated() {
            let itemSettingName = "\(settingName)[\(index)]"
            switch configuredItem {
            case .separator:
                guard !resolvedItems.isEmpty else { continue }
                if let last = resolvedItems.last, case .separator = last {
                    continue
                }
                resolvedItems.append(.separator(id: "\(settingName).separator.\(index)"))
            case .action(let item):
                let resolvedActionID = canonicalActionID(item.action)
                guard let action = actions[resolvedActionID] else {
                    let issue = BreeConfigIssue(
                        kind: .newWorkspaceActionNotFound,
                        settingName: itemSettingName,
                        commandName: item.action,
                        sourcePath: settingSourcePath
                    )
                    NSLog("[BreeConfig] %@", issue.logMessage)
                    issues.append(issue)
                    continue
                }
                if let actionCommandName = action.workspaceCommandName {
                    let commandResolution = resolvedConfiguredNewWorkspaceCommand(
                        named: actionCommandName,
                        settingName: itemSettingName,
                        settingSourcePath: action.actionSourcePath ?? settingSourcePath,
                        commands: commands,
                        sourcePaths: sourcePaths
                    )
                    if let issue = commandResolution.issue {
                        issues.append(issue)
                        continue
                    }
                    guard commandResolution.command != nil else {
                        continue
                    }
                }
                resolvedItems.append(
                    .action(
                        BreeResolvedConfigMenuAction(
                            id: "\(settingName).\(index).\(action.id)",
                            title: sanitizeConfigText(item.title ?? action.title, fallback: action.id),
                            icon: item.icon ?? action.icon,
                            iconSourcePath: item.icon == nil ? action.iconSourcePath : settingSourcePath,
                            tooltip: (item.tooltip ?? action.tooltip).map(sanitizeConfigText),
                            action: action
                        )
                    )
                )
            }
        }

        if let last = resolvedItems.last, case .separator = last {
            resolvedItems.removeLast()
        }
        return ResolvedContextMenuItems(items: resolvedItems, issues: issues)
    }

    private func canonicalActionID(_ id: String) -> String {
        BreeSurfaceTabBarBuiltInAction(configID: id)?.configID ?? id
    }

    /// Auto-offers qualifying actions (inline workspace actions by default, plus
    /// anything with `newWorkspaceMenu: true`) in the plus-button menu without
    /// requiring the user to hand-edit `ui.newWorkspace.contextMenu`. Explicitly
    /// listed actions are not duplicated; `newWorkspaceMenu: false` opts out.
    /// `workspaceCommand` actions get the same named-command validation the
    /// explicit menu path applies, so a dead reference surfaces as a config
    /// issue instead of a no-op menu item.
    private func appendingAutoNewWorkspaceMenuActions(
        to resolved: ResolvedContextMenuItems,
        actions: [String: BreeResolvedConfigAction],
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String]
    ) -> ResolvedContextMenuItems {
        let existingActionIDs = Set(resolved.items.compactMap { item -> String? in
            if case .action(let menuAction) = item {
                return menuAction.action.id
            }
            return nil
        })
        let candidates = actions.values
            .filter { $0.wantsNewWorkspaceMenu && !existingActionIDs.contains($0.id) }
            .sorted {
                ($0.title, $0.id) < ($1.title, $1.id)
            }
        guard !candidates.isEmpty else { return resolved }

        var issues = resolved.issues
        var autoActions: [BreeResolvedConfigAction] = []
        for action in candidates {
            if let commandName = action.workspaceCommandName {
                let resolution = resolvedConfiguredNewWorkspaceCommand(
                    named: commandName,
                    settingName: "ui.newWorkspace.contextMenu.auto.\(action.id)",
                    settingSourcePath: action.actionSourcePath,
                    commands: commands,
                    sourcePaths: sourcePaths
                )
                if let issue = resolution.issue {
                    issues.append(issue)
                    continue
                }
                guard resolution.command != nil else { continue }
            }
            autoActions.append(action)
        }
        guard !autoActions.isEmpty else {
            return ResolvedContextMenuItems(items: resolved.items, issues: issues)
        }

        var items = resolved.items
        if let last = items.last, case .action = last {
            items.append(.separator(id: "ui.newWorkspace.contextMenu.auto.separator"))
        }
        items.append(contentsOf: autoActions.map { action in
            .action(
                BreeResolvedConfigMenuAction(
                    id: "ui.newWorkspace.contextMenu.auto.\(action.id)",
                    title: sanitizeConfigText(action.title, fallback: action.id),
                    icon: action.icon,
                    iconSourcePath: action.iconSourcePath,
                    tooltip: action.tooltip.map(sanitizeConfigText),
                    action: action
                )
            )
        })
        return ResolvedContextMenuItems(items: items, issues: issues)
    }

    private func resolvedConfiguredNewWorkspaceCommand(
        named commandName: String,
        settingName: String,
        settingSourcePath: String?,
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String]
    ) -> NewWorkspaceCommandResolution {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandNotFound,
                settingName: settingName,
                commandName: commandName,
                sourcePath: settingSourcePath
            )
        }
        guard command.workspace != nil else {
            return newWorkspaceResolutionIssue(
                kind: .newWorkspaceCommandRequiresWorkspace,
                settingName: settingName,
                commandName: commandName,
                sourcePath: sourcePaths[command.id] ?? settingSourcePath
            )
        }
        return NewWorkspaceCommandResolution(
            command: BreeResolvedCommand(command: command, sourcePath: sourcePaths[command.id]),
            issue: nil
        )
    }

    private func newWorkspaceResolutionIssue(
        kind: BreeConfigIssue.Kind,
        settingName: String,
        commandName: String?,
        sourcePath: String?
    ) -> NewWorkspaceCommandResolution {
        let issue = BreeConfigIssue(
            kind: kind,
            settingName: settingName,
            commandName: commandName,
            sourcePath: sourcePath
        )
        NSLog("[BreeConfig] %@", issue.logMessage)
        return NewWorkspaceCommandResolution(command: nil, issue: issue)
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String
    ) -> BreeResolvedCommand? {
        resolvedWorkspaceCommand(
            named: commandName,
            settingName: settingName,
            commands: loadedCommands,
            sourcePaths: commandSourcePaths
        )
    }

    private func resolvedWorkspaceCommand(
        named commandName: String,
        settingName: String,
        commands: [BreeCommandDefinition],
        sourcePaths: [String: String]
    ) -> BreeResolvedCommand? {
        guard let command = commands.first(where: { $0.name == commandName }) else {
            NSLog("[BreeConfig] %@ '%@' does not match any loaded command", settingName, commandName)
            return nil
        }
        guard command.workspace != nil else {
            NSLog("[BreeConfig] %@ '%@' must reference a workspace command", settingName, commandName)
            return nil
        }
        return BreeResolvedCommand(command: command, sourcePath: sourcePaths[command.id])
    }

    // MARK: - Parsing

    private func parseConfig(at path: String) -> ParsedConfigResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: path) else {
            parsedConfigCache.removeValue(forKey: path)
            return ParsedConfigResult(config: nil, issue: nil)
        }

        // Key the parse cache on stat(2), which follows symlinks, rather than
        // attributesOfItem(atPath:), which has lstat semantics and does not.
        // When bree.json is a symlink into a dotfiles repo, editing the target
        // leaves the link's own size/mtime unchanged, so an lstat-based key would
        // never invalidate and reload-config / file watching would appear to do
        // nothing until a full app restart. contents(atPath:) below also follows
        // the symlink, so this keeps the cache key consistent with what we read.
        var statBuffer = stat()
        let statSucceeded = stat(path, &statBuffer) == 0
        let fileSize = statSucceeded ? UInt64(statBuffer.st_size) : 0
        let modificationDate: Date? = statSucceeded
            ? Date(timeIntervalSince1970: TimeInterval(statBuffer.st_mtimespec.tv_sec)
                + TimeInterval(statBuffer.st_mtimespec.tv_nsec) / 1_000_000_000)
            : nil
        let paletteFingerprint = WorkspaceTabColorSettings.paletteCacheFingerprint()

        if let cached = parsedConfigCache[path],
           cached.fileSize == fileSize,
           cached.modificationDate == modificationDate,
           cached.workspaceColorPaletteFingerprint == paletteFingerprint {
            return ParsedConfigResult(config: cached.config, issue: cached.issue)
        }

        guard let data = fileManager.contents(atPath: path),
              !data.isEmpty else {
            let issue = schemaIssue(path: path, message: "\(BreeIdentity.current.configFileName) is empty")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            return ParsedConfigResult(config: nil, issue: issue)
        }
        let sanitized: Data
        do {
            sanitized = try JSONCParser.preprocess(data: data)
        } catch {
            let issue = schemaIssue(path: path, message: "JSONC preprocessing failed: \(schemaErrorMessage(error))")
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[BreeConfig] JSONC preprocessing error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }

        do {
            let config = try JSONDecoder().decode(BreeConfigFile.self, from: sanitized)
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: config,
                issue: nil
            )
            return ParsedConfigResult(config: config, issue: nil)
        } catch {
            let issue = schemaIssue(path: path, message: schemaErrorMessage(error))
            parsedConfigCache[path] = ParsedConfigCacheEntry(
                fileSize: fileSize,
                modificationDate: modificationDate,
                workspaceColorPaletteFingerprint: paletteFingerprint,
                config: nil,
                issue: issue
            )
            NSLog("[BreeConfig] parse error at %@: %@", path, String(describing: error))
            return ParsedConfigResult(config: nil, issue: issue)
        }
    }

    private func schemaIssue(path: String, message: String) -> BreeConfigIssue {
        BreeConfigIssue(
            kind: .schemaError,
            settingName: (path as NSString).lastPathComponent,
            sourcePath: path,
            message: message
        )
    }

    private func schemaErrorMessage(_ error: Error) -> String {
        switch error {
        case DecodingError.typeMismatch(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.valueNotFound(_, let context):
            return schemaErrorMessage(context)
        case DecodingError.keyNotFound(let key, let context):
            let path = schemaCodingPath(context.codingPath + [key])
            let detail = sanitizeConfigText(context.debugDescription)
            return "\(path): \(detail)"
        case DecodingError.dataCorrupted(let context):
            return schemaErrorMessage(context)
        default:
            let message = sanitizeConfigText(error.localizedDescription)
            return message.isEmpty ? String(describing: error) : message
        }
    }

    private func schemaErrorMessage(_ context: DecodingError.Context) -> String {
        let path = schemaCodingPath(context.codingPath)
        let detail = sanitizeConfigText(context.debugDescription)
        return detail.isEmpty ? path : "\(path): \(detail)"
    }

    private func schemaCodingPath(_ codingPath: [CodingKey]) -> String {
        let path = codingPath.map(\.stringValue).filter { !$0.isEmpty }.joined(separator: ".")
        return path.isEmpty ? "root" : path
    }

    // MARK: - File watching (local)

    private func startLocalFileWatcher() {
        guard let path = localConfigPath else { return }
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // File doesn't exist yet — watch the directory instead
            startLocalDirectoryWatcher()
            return
        }
        localFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopLocalFileWatcher()
                    self.loadAll()
                    self.scheduleLocalReattach(attempt: 1)
                }
            } else {
                DispatchQueue.main.async {
                    self.loadAll()
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        localFileWatchSource = source
    }

    private func updateLocalHookFileWatchers(
        paths: [String],
        primaryLocalPath: String?
    ) {
        let desiredPaths = Set(paths.filter { path in
            path != primaryLocalPath && FileManager.default.fileExists(atPath: path)
        })
        for path in Array(hookWatchers.keys) where !desiredPaths.contains(path) {
            stopLocalHookFileWatcher(at: path)
        }
        for path in desiredPaths where hookWatchers[path] == nil {
            startLocalHookFileWatcher(at: path)
        }
    }

    private func startLocalHookFileWatcher(at path: String) {
        let watcher = FileWatcher(path: path)
        hookWatchers[path] = watcher
        let events = watcher.events
        hookWatchTasks[path] = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopLocalHookFileWatcher(at path: String) {
        hookWatchTasks.removeValue(forKey: path)?.cancel()
        hookWatchers.removeValue(forKey: path)
    }

    private func stopLocalHookFileWatchers() {
        hookWatchTasks.values.forEach { $0.cancel() }
        hookWatchTasks.removeAll()
        hookWatchers.removeAll()
    }

    private func startLocalDirectoryWatcher() {
        guard let path = localConfigPath else { return }
        let configDirectory = (path as NSString).deletingLastPathComponent
        let fs = FileManager.default
        let dirPath: String
        if fs.fileExists(atPath: configDirectory) {
            dirPath = configDirectory
        } else if let searchDirectory = localConfigSearchDirectory,
                  fs.fileExists(atPath: searchDirectory) {
            dirPath = searchDirectory
        } else {
            dirPath = (configDirectory as NSString).deletingLastPathComponent
        }
        let eventHandler = { [weak self] in
            DispatchQueue.main.async {
                self?.handleLocalDirectoryWatchEvent()
            }
        }

        guard let primaryWatch = startLocalDirectoryWatchSource(at: dirPath, eventHandler: eventHandler) else {
            return
        }
        localFileWatchSource = primaryWatch.source
        localFileDescriptor = primaryWatch.fileDescriptor

        if let searchDirectory = localConfigSearchDirectory,
           fs.fileExists(atPath: configDirectory),
           searchDirectory != dirPath,
           let fallbackWatch = startLocalDirectoryWatchSource(at: searchDirectory, eventHandler: eventHandler) {
            localFallbackDirectoryWatchSource = fallbackWatch.source
            localFallbackDirectoryDescriptor = fallbackWatch.fileDescriptor
        }
    }

    private func startLocalDirectoryWatchSource(
        at dirPath: String,
        eventHandler: @escaping () -> Void
    ) -> (source: DispatchSourceFileSystemObject, fileDescriptor: Int32)? {
        let fd = open(dirPath, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .link, .rename],
            queue: watchQueue
        )
        source.setEventHandler(handler: eventHandler)
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
        return (source, fd)
    }

    private func handleLocalDirectoryWatchEvent() {
        if let searchDirectory = localConfigSearchDirectory {
            let resolvedPath = resolvedLocalConfigPath(startingFrom: searchDirectory)
            if resolvedPath != localConfigPath {
                localConfigPath = resolvedPath
            }
        }
        guard let configPath = localConfigPath else { return }
        let configDirectory = (configPath as NSString).deletingLastPathComponent
        guard FileManager.default.fileExists(atPath: configPath) ||
            FileManager.default.fileExists(atPath: configDirectory) else { return }
        // File or its parent directory appeared — switch to file-level watching.
        stopLocalFileWatcher()
        loadAll()
        startLocalFileWatcher()
    }

    private func scheduleLocalReattach(attempt: Int) {
        guard attempt <= Self.maxReattachAttempts else { return }
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard let path = self.localConfigPath else { return }
                if FileManager.default.fileExists(atPath: path) {
                    self.loadAll()
                    self.startLocalFileWatcher()
                } else {
                    self.startLocalDirectoryWatcher()
                }
            }
        }
    }

    private func stopLocalFileWatcher() {
        if let source = localFileWatchSource {
            source.cancel()
            localFileWatchSource = nil
        }
        stopLocalHookFileWatchers()
        if let source = localFallbackDirectoryWatchSource {
            source.cancel()
            localFallbackDirectoryWatchSource = nil
        }
        localFileDescriptor = -1
        localFallbackDirectoryDescriptor = -1
    }

    // MARK: - File watching (global)

    /// Watches the global config via ``BreeFileWatch/FileWatcher``, which handles
    /// inode reattachment and nearest-existing-ancestor recovery internally; each
    /// change reloads. Ensures the config directory exists first (the previous
    /// directory-watcher created it).
    private func startGlobalWatching() {
        stopGlobalWatching()
        let dirPath = (globalConfigPath as NSString).deletingLastPathComponent
        if !FileManager.default.fileExists(atPath: dirPath) {
            try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        }
        let watcher = FileWatcher(path: globalConfigPath)
        globalWatcher = watcher
        let events = watcher.events
        globalWatchTask = Task { @MainActor [weak self] in
            for await _ in events {
                guard let self else { break }
                self.loadAll()
            }
        }
    }

    private func stopGlobalWatching() {
        globalWatchTask?.cancel()
        globalWatchTask = nil
        globalWatcher = nil
    }
}

extension BreeConfigStore {
    static func resolveCwd(_ cwd: String?, relativeTo baseCwd: String) -> String {
        guard let cwd, !cwd.isEmpty, cwd != "." else {
            return baseCwd
        }
        if cwd.hasPrefix("~/") || cwd == "~" {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if cwd == "~" { return home }
            return (home as NSString).appendingPathComponent(String(cwd.dropFirst(2)))
        }
        if cwd.hasPrefix("/") {
            return cwd
        }
        return (baseCwd as NSString).appendingPathComponent(cwd)
    }
}
