import Foundation
import BreeFoundation

extension BREECLI {
    struct ConfigDoctorOptions {
        let paths: [String]
        let scope: BreeConfigSemanticScope?
    }

    struct ConfigDoctorTarget {
        let label: String
        let displayPath: String
        let path: String
        let missingIsError: Bool
        let scope: BreeConfigSemanticScope
    }

    struct ConfigDoctorFinding {
        let label: String
        let displayPath: String
        let path: String
        let status: String
        let message: String?
        let keys: [String]
        let byteCount: Int?
        let issues: [BreeConfigSemanticIssue]

        init(
            label: String,
            displayPath: String,
            path: String,
            status: String,
            message: String?,
            keys: [String],
            byteCount: Int?,
            issues: [BreeConfigSemanticIssue] = []
        ) {
            self.label = label
            self.displayPath = displayPath
            self.path = path
            self.status = status
            self.message = message
            self.keys = keys
            self.byteCount = byteCount
            self.issues = issues
        }

        var isError: Bool { status == "error" }

        var payload: [String: Any] {
            var result: [String: Any] = [
                "label": label,
                "display_path": displayPath,
                "path": path,
                "status": status,
                "ok": !isError,
                "keys": keys,
            ]
            if let message {
                result["message"] = message
            }
            if let byteCount {
                result["bytes"] = byteCount
            }
            if !issues.isEmpty {
                result["issues"] = issues.map { ["path": $0.path, "message": $0.message] }
            }
            return result
        }
    }

    struct ConfigDoctorReport {
        let findings: [ConfigDoctorFinding]

        var errorCount: Int {
            findings.filter(\.isError).count
        }

        var payload: [String: Any] {
            [
                "ok": errorCount == 0,
                "error_count": errorCount,
                "findings": findings.map(\.payload),
                "reload_command": "bree reload-config",
                "docs_url": BREECLI.settingsDocsURL,
                "schema_url": BREECLI.settingsSchemaURL,
            ]
        }
    }

    func runConfigDoctor(
        arguments: [String],
        jsonOutput: Bool,
        commandName: String
    ) throws -> ConfigDoctorReport {
        let options = try parseConfigDoctorOptions(arguments, commandName: commandName)
        let targets = options.paths.isEmpty
            ? defaultConfigDoctorTargets()
            : options.paths.enumerated().map { index, rawPath in
                let path = Self.absoluteConfigPath(rawPath)
                return ConfigDoctorTarget(
                    label: "custom \(index + 1)",
                    displayPath: Self.tildePath(path),
                    path: path,
                    missingIsError: true,
                    scope: options.scope ?? configSemanticScope(for: path)
                )
            }
        let findings = targets.map(configDoctorFinding(for:))
        let report = ConfigDoctorReport(findings: findings)

        if jsonOutput {
            print(jsonString(report.payload))
        } else {
            printConfigDoctorReport(report, commandName: commandName)
        }
        return report
    }

    private func parseConfigDoctorOptions(
        _ arguments: [String],
        commandName: String
    ) throws -> ConfigDoctorOptions {
        var paths: [String] = []
        var scope: BreeConfigSemanticScope?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--path" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count else {
                    throw CLIError(
                        message: BreeConfigValidationLocalization().format(
                            "config.validation.cli.pathRequired",
                            defaultValue: "bree config %@ --path requires a path",
                            commandName
                        )
                    )
                }
                paths.append(arguments[nextIndex])
                index += 2
                continue
            }
            if argument.hasPrefix("--path=") {
                let rawPath = String(argument.dropFirst("--path=".count))
                guard !rawPath.isEmpty else {
                    throw CLIError(
                        message: BreeConfigValidationLocalization().format(
                            "config.validation.cli.pathRequired",
                            defaultValue: "bree config %@ --path requires a path",
                            commandName
                        )
                    )
                }
                paths.append(rawPath)
                index += 1
                continue
            }
            if argument == "--scope" {
                let nextIndex = index + 1
                guard nextIndex < arguments.count,
                      let parsedScope = BreeConfigSemanticScope(rawValue: arguments[nextIndex].lowercased()) else {
                    throw CLIError(
                        message: BreeConfigValidationLocalization().format(
                            "config.validation.cli.scopeRequired",
                            defaultValue: "bree config %@ --scope requires global or project",
                            commandName
                        )
                    )
                }
                scope = parsedScope
                index += 2
                continue
            }
            if argument.hasPrefix("--scope=") {
                let rawScope = String(argument.dropFirst("--scope=".count)).lowercased()
                guard let parsedScope = BreeConfigSemanticScope(rawValue: rawScope) else {
                    throw CLIError(
                        message: BreeConfigValidationLocalization().format(
                            "config.validation.cli.scopeRequired",
                            defaultValue: "bree config %@ --scope requires global or project",
                            commandName
                        )
                    )
                }
                scope = parsedScope
                index += 1
                continue
            }
            if argument.hasPrefix("-") {
                throw CLIError(
                    message: BreeConfigValidationLocalization().format(
                        "config.validation.cli.unknownOption",
                        defaultValue: "Unknown config %@ option '%@'",
                        commandName,
                        argument
                    )
                )
            }
            throw CLIError(
                message: BreeConfigValidationLocalization().format(
                    "config.validation.cli.unknownArgument",
                    defaultValue: "Unknown config %@ argument '%@'. Use --path <path>.",
                    commandName,
                    argument
                )
            )
        }
        return ConfigDoctorOptions(paths: paths, scope: scope)
    }

    private func defaultConfigDoctorTargets() -> [ConfigDoctorTarget] {
        let primary = Self.absoluteConfigPath(Self.primarySettingsDisplayPath)
        var targets = [
            ConfigDoctorTarget(
                label: "primary",
                displayPath: Self.primarySettingsDisplayPath,
                path: primary,
                missingIsError: false,
                scope: .global
            )
        ]

        if let projectPath = findProjectConfigPath(), projectPath != primary {
            targets.append(
                ConfigDoctorTarget(
                    label: "project",
                    displayPath: Self.tildePath(projectPath),
                    path: projectPath,
                    missingIsError: false,
                    scope: .project
                )
            )
        }

        let optionalPaths = [
            ("legacy config", Self.legacySettingsDisplayPath),
            ("legacy app support", Self.fallbackSettingsDisplayPath),
        ]
        for (label, displayPath) in optionalPaths {
            let path = Self.absoluteConfigPath(displayPath)
            guard path != primary,
                  FileManager.default.fileExists(atPath: path),
                  !targets.contains(where: { $0.path == path }) else {
                continue
            }
            targets.append(
                ConfigDoctorTarget(
                    label: label,
                    displayPath: displayPath,
                    path: path,
                    missingIsError: false,
                    scope: .global
                )
            )
        }
        return targets
    }

    private func findProjectConfigPath() -> String? {
        let fileManager = FileManager.default
        let rawHomePath = ProcessInfo.processInfo.environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        let homePath = URL(fileURLWithPath: rawHomePath).standardizedFileURL.path
        var current = URL(fileURLWithPath: fileManager.currentDirectoryPath).standardizedFileURL.path
        while true {
            if current == homePath {
                return nil
            }
            let candidates = BreeIdentity.current.projectConfigCandidates(in: current)
            for candidate in candidates {
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: candidate, isDirectory: &isDirectory),
                   !isDirectory.boolValue {
                    return URL(fileURLWithPath: candidate).standardizedFileURL.path
                }
            }
            let parent = (current as NSString).deletingLastPathComponent
            if parent == current {
                return nil
            }
            current = parent
        }
    }

    private func configDoctorFinding(for target: ConfigDoctorTarget) -> ConfigDoctorFinding {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory) else {
            let message = target.missingIsError
                ? BreeConfigValidationLocalization().string(
                    "config.validation.cli.doctor.fileNotFound",
                    defaultValue: "file not found"
                )
                : BreeConfigValidationLocalization().string(
                    "config.validation.cli.doctor.missingDefaults",
                    defaultValue: "not found; Bree will use defaults until this file exists"
                )
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: target.missingIsError ? "error" : "missing",
                message: message,
                keys: [],
                byteCount: nil
            )
        }
        if isDirectory.boolValue {
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: "error",
                message: BreeConfigValidationLocalization().string(
                    "config.validation.cli.doctor.pathIsDirectory",
                    defaultValue: "path is a directory, expected a file"
                ),
                keys: [],
                byteCount: nil
            )
        }

        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: target.path))
            guard !data.isEmpty else {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: BreeConfigValidationLocalization().string(
                        "config.validation.cli.doctor.fileEmpty",
                        defaultValue: "file is empty"
                    ),
                    keys: [],
                    byteCount: 0
                )
            }
            let sanitized = try JSONCParser.preprocess(data: data)
            let object = try JSONSerialization.jsonObject(with: sanitized)
            guard let dictionary = object as? [String: Any] else {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: BreeConfigValidationLocalization().string(
                        "config.validation.cli.doctor.topLevelObject",
                        defaultValue: "top-level value must be a JSON object"
                    ),
                    keys: [],
                    byteCount: data.count
                )
            }
            let validator = BreeConfigSemanticValidator(scope: target.scope)
            let issues = try validator.validate(jsonData: sanitized)
            if !issues.isEmpty {
                return ConfigDoctorFinding(
                    label: target.label,
                    displayPath: target.displayPath,
                    path: target.path,
                    status: "error",
                    message: BreeConfigValidationLocalization().string(
                        "config.validation.cli.failed",
                        defaultValue: "semantic validation failed"
                    ),
                    keys: dictionary.keys.sorted(),
                    byteCount: data.count,
                    issues: issues
                )
            }
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: "ok",
                message: BreeConfigValidationLocalization().string(
                    "config.validation.cli.passed",
                    defaultValue: "JSONC syntax and semantic validation passed"
                ),
                keys: dictionary.keys.sorted(),
                byteCount: data.count
            )
        } catch {
            return ConfigDoctorFinding(
                label: target.label,
                displayPath: target.displayPath,
                path: target.path,
                status: "error",
                message: Self.configDoctorErrorMessage(error),
                keys: [],
                byteCount: nil
            )
        }
    }

    private func printConfigDoctorReport(_ report: ConfigDoctorReport, commandName: String) {
        let localization = BreeConfigValidationLocalization()
        let pathLabel = localization.string(
            "config.validation.cli.doctor.report.path",
            defaultValue: "path"
        )
        let bytesLabel = localization.string(
            "config.validation.cli.doctor.report.bytes",
            defaultValue: "bytes"
        )
        let keysLabel = localization.string(
            "config.validation.cli.doctor.report.keys",
            defaultValue: "keys"
        )
        print("bree config \(commandName)")
        for finding in report.findings {
            let status = Self.localizedConfigDoctorStatus(finding.status)
            let label = Self.localizedConfigDoctorLabel(finding.label)
            print("\(status) \(label): \(finding.displayPath)")
            print("  \(pathLabel): \(finding.path)")
            if let byteCount = finding.byteCount {
                print("  \(bytesLabel): \(byteCount)")
            }
            if !finding.keys.isEmpty {
                print("  \(keysLabel): \(finding.keys.joined(separator: ", "))")
            }
            if let message = finding.message {
                print("  \(message)")
            }
            for issue in finding.issues {
                print("  \(issue.path): \(issue.message)")
            }
        }
        print()
        let docsLabel = localization.string(
            "config.validation.cli.doctor.report.docs",
            defaultValue: "Docs"
        )
        let schemaLabel = localization.string(
            "config.validation.cli.doctor.report.schema",
            defaultValue: "Schema"
        )
        let reloadLabel = localization.string(
            "config.validation.cli.doctor.report.reload",
            defaultValue: "Reload"
        )
        print("\(docsLabel): \(Self.settingsDocsURL)")
        print("\(schemaLabel): \(Self.settingsSchemaURL)")
        print("\(reloadLabel): bree reload-config")
    }

    private static func localizedConfigDoctorStatus(_ status: String) -> String {
        let localization = BreeConfigValidationLocalization()
        switch status {
        case "ok":
            return localization.string(
                "config.validation.cli.doctor.status.ok",
                defaultValue: "OK"
            )
        case "error":
            return localization.string(
                "config.validation.cli.doctor.status.error",
                defaultValue: "ERROR"
            )
        case "missing":
            return localization.string(
                "config.validation.cli.doctor.status.missing",
                defaultValue: "MISSING"
            )
        default:
            return status.uppercased()
        }
    }

    private static func localizedConfigDoctorLabel(_ label: String) -> String {
        let localization = BreeConfigValidationLocalization()
        switch label {
        case "primary":
            return localization.string(
                "config.validation.cli.doctor.label.primary",
                defaultValue: "primary"
            )
        case "project":
            return localization.string(
                "config.validation.cli.doctor.label.project",
                defaultValue: "project"
            )
        case "legacy config":
            return localization.string(
                "config.validation.cli.doctor.label.legacyConfig",
                defaultValue: "legacy config"
            )
        case "legacy app support":
            return localization.string(
                "config.validation.cli.doctor.label.legacyAppSupport",
                defaultValue: "legacy app support"
            )
        default:
            guard label.hasPrefix("custom ") else { return label }
            let suffix = String(label.dropFirst("custom ".count))
            return localization.format(
                "config.validation.cli.doctor.label.custom",
                defaultValue: "custom %@",
                suffix
            )
        }
    }

    private func configSemanticScope(for path: String) -> BreeConfigSemanticScope {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let globalPaths = [
            Self.primarySettingsDisplayPath,
            Self.legacySettingsDisplayPath,
            Self.fallbackSettingsDisplayPath,
        ].map(Self.absoluteConfigPath)
        if globalPaths.contains(normalized) {
            return .global
        }
        if let projectPath = findProjectConfigPath(),
           URL(fileURLWithPath: projectPath).standardizedFileURL.path == normalized {
            return .project
        }
        let parent = (normalized as NSString).deletingLastPathComponent
        if BreeIdentity.isProjectDirectoryName((parent as NSString).lastPathComponent) {
            return .project
        }
        return .global
    }

    private static func absoluteConfigPath(_ rawPath: String) -> String {
        let homePath = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let expanded: String
        if rawPath == "~" {
            expanded = homePath
        } else if rawPath.hasPrefix("~/") {
            expanded = (homePath as NSString).appendingPathComponent(String(rawPath.dropFirst(2)))
        } else {
            expanded = rawPath
        }

        let absolute = (expanded as NSString).isAbsolutePath
            ? expanded
            : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(expanded)
        return URL(fileURLWithPath: absolute).standardizedFileURL.path
    }

    static func tildePath(_ path: String) -> String {
        let homePath = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory())
            .standardizedFileURL
            .path
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        if normalized == homePath {
            return "~"
        }
        let prefix = homePath.hasSuffix("/") ? homePath : homePath + "/"
        if normalized.hasPrefix(prefix) {
            return "~/" + String(normalized.dropFirst(prefix.count))
        }
        return normalized
    }

    static func configDoctorErrorMessage(_ error: Error) -> String {
        let nsError = error as NSError
        if let debug = nsError.userInfo[NSDebugDescriptionErrorKey] as? String {
            let trimmed = debug.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        let described = String(describing: error).trimmingCharacters(in: .whitespacesAndNewlines)
        if !described.isEmpty {
            return described
        }
        let localized = nsError.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if !localized.isEmpty {
            return localized
        }
        return BreeConfigValidationLocalization().string(
            "config.validation.cli.doctor.unknownParseError",
            defaultValue: "unknown config parse error"
        )
    }

}
