public import Foundation
import BreeFoundation
public import BreeTerminalCore

extension TerminalSurface {
    /// Writes every available bundled agent wrapper shim into one per-surface directory.
    ///
    /// Adding an agent to ``TerminalSurfaceAgentCommandShimDefinition/bundled``
    /// automatically gives it the same lifecycle, permissions, `PATH`, bundle-
    /// replacement fallback, and environment behavior as existing agents.
    ///
    /// - Parameters:
    ///   - wrapperDirectoryURL: The app bundle directory containing bree's launch wrappers.
    ///   - surfaceId: The terminal surface that owns the generated shim directory.
    ///   - rootDirectory: The root under which the isolated shim directory is created. The
    ///     live app supplies a durable per-user bree state directory; tests may use a temporary root.
    ///   - enabledCommands: Bundled agent commands that should receive a shim.
    ///   - hermesProfileAliasDirectoryURL: The Hermes-owned wrapper directory to inspect for profile aliases.
    ///   - fileManager: The filesystem implementation used for discovery and installation.
    /// - Returns: The installed shim set, or `nil` when no bundled wrapper can be installed.
    public static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL?,
        surfaceId: UUID,
        rootDirectory: URL,
        enabledCommands: Set<TerminalSurfaceAgentCommand> = Set(TerminalSurfaceAgentCommand.allCases),
        hermesProfileAliasDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) -> TerminalSurfaceAgentCommandShimSet? {
        guard let wrapperDirectoryURL = wrapperDirectoryURL?.standardizedFileURL else { return nil }
        let aliases = hermesProfileAliasDirectoryURL.map { aliasDirectoryURL in
            HermesProfileAliasResolver(
                wrapperDirectoryURL: aliasDirectoryURL,
                fileManager: fileManager
            ).resolve(excluding: reservedAgentCommandShimNames)
        } ?? []
        return installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectoryURL,
            surfaceId: surfaceId,
            rootDirectory: rootDirectory,
            enabledCommands: enabledCommands,
            hermesProfileAliases: aliases,
            fileManager: fileManager
        )
    }

    /// Writes bundled agent shims using a process-owned Hermes alias catalog.
    ///
    /// The catalog serializes concurrent restore requests and scans the shared
    /// Hermes wrapper directory only once per directory generation.
    ///
    /// - Parameters:
    ///   - wrapperDirectoryURL: The app bundle directory containing bree's launch wrappers.
    ///   - surfaceId: The terminal surface that owns the generated shim directory.
    ///   - rootDirectory: The root under which the isolated shim directory is created. The
    ///     live app supplies a durable per-user bree state directory; tests may use a temporary root.
    ///   - enabledCommands: Bundled agent commands that should receive a shim.
    ///   - hermesProfileAliasCatalog: The process-owned Hermes alias discovery cache.
    ///   - fileManager: The filesystem implementation used for shim installation.
    /// - Returns: The installed shim set, or `nil` when no bundled wrapper can be installed.
    public static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL?,
        surfaceId: UUID,
        rootDirectory: URL,
        enabledCommands: Set<TerminalSurfaceAgentCommand> = Set(TerminalSurfaceAgentCommand.allCases),
        hermesProfileAliasCatalog: HermesProfileAliasCatalog,
        fileManager: FileManager = .default
    ) async -> TerminalSurfaceAgentCommandShimSet? {
        guard let wrapperDirectoryURL = wrapperDirectoryURL?.standardizedFileURL else { return nil }
        let aliases = await hermesProfileAliasCatalog.aliases(
            excluding: reservedAgentCommandShimNames
        )
        return installAgentCommandShimsIfPossible(
            wrapperDirectoryURL: wrapperDirectoryURL,
            surfaceId: surfaceId,
            rootDirectory: rootDirectory,
            enabledCommands: enabledCommands,
            hermesProfileAliases: aliases,
            fileManager: fileManager
        )
    }

    private static var reservedAgentCommandShimNames: Set<String> {
        Set(TerminalSurfaceAgentCommandShimDefinition.bundled.map(\.commandName))
    }

    private static func installAgentCommandShimsIfPossible(
        wrapperDirectoryURL: URL,
        surfaceId: UUID,
        rootDirectory: URL,
        enabledCommands: Set<TerminalSurfaceAgentCommand>,
        hermesProfileAliases: [HermesProfileAliasResolver.Alias],
        fileManager: FileManager
    ) -> TerminalSurfaceAgentCommandShimSet? {
        var availableDefinitions: [(
            definition: TerminalSurfaceAgentCommandShimDefinition,
            wrapperURL: URL
        )] = []
        for definition in TerminalSurfaceAgentCommandShimDefinition.bundled {
            guard enabledCommands.contains(definition.command) else { continue }
            let wrapperURL = wrapperDirectoryURL
                .appendingPathComponent(definition.wrapperName, isDirectory: false)
                .standardizedFileURL
            guard fileManager.isExecutableFile(atPath: wrapperURL.path) else { continue }
            availableDefinitions.append((definition, wrapperURL))
        }
        guard !availableDefinitions.isEmpty else { return nil }

        let shimParentDirectory = rootDirectory
            .appendingPathComponent("bree-cli-shims", isDirectory: true)
            .standardizedFileURL
        let shimDirectory = shimParentDirectory
            .appendingPathComponent(surfaceId.uuidString, isDirectory: true)
            .standardizedFileURL
        let stagingDirectory = shimParentDirectory
            .appendingPathComponent(".\(surfaceId.uuidString).staging.\(UUID().uuidString)", isDirectory: true)
            .standardizedFileURL
        defer {
            try? fileManager.removeItem(at: stagingDirectory)
        }
        // A shared temporary directory lets another user create these
        // directories first or plant a symlink, so each one must be a real
        // directory this user owns before anything is written into it.
        let privateDirectoryCheck = PrivateDirectoryCheck()
        do {
            try fileManager.createDirectory(at: shimParentDirectory, withIntermediateDirectories: true)
            guard privateDirectoryCheck.makePrivate(atPath: shimParentDirectory.path) else { return nil }
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            guard privateDirectoryCheck.makePrivate(atPath: stagingDirectory.path) else { return nil }
        } catch {
            return nil
        }

        var shims: [TerminalSurfaceAgentCommandShim] = []
        if let hermesDefinition = availableDefinitions.first(where: {
            $0.definition.commandName == "hermes"
        }) {
            for alias in hermesProfileAliases {
                guard let shim = installAgentCommandShim(
                    definition: hermesDefinition.definition,
                    commandName: alias.commandName,
                    hermesProfileAliasURL: URL(
                        fileURLWithPath: alias.wrapperPath,
                        isDirectory: false
                    ),
                    wrapperURL: hermesDefinition.wrapperURL,
                    stagingDirectory: stagingDirectory,
                    publishedDirectory: shimDirectory,
                    fileManager: fileManager
                ) else { continue }
                shims.append(shim)
            }
        }
        for (definition, wrapperURL) in availableDefinitions {
            guard let shim = installAgentCommandShim(
                definition: definition,
                wrapperURL: wrapperURL,
                stagingDirectory: stagingDirectory,
                publishedDirectory: shimDirectory,
                fileManager: fileManager
            ) else { continue }
            shims.append(shim)
        }
        guard !shims.isEmpty else { return nil }
        do {
            if fileManager.fileExists(atPath: shimDirectory.path) {
                guard privateDirectoryCheck.makePrivate(atPath: shimDirectory.path) else { return nil }
                _ = try fileManager.replaceItemAt(
                    shimDirectory,
                    withItemAt: stagingDirectory,
                    backupItemName: nil,
                    options: []
                )
            } else {
                try fileManager.moveItem(at: stagingDirectory, to: shimDirectory)
            }
        } catch {
            return nil
        }
        guard privateDirectoryCheck.makePrivate(atPath: shimDirectory.path) else { return nil }
        return TerminalSurfaceAgentCommandShimSet(
            directoryPath: shimDirectory.path,
            shims: shims
        )
    }

    private static func installAgentCommandShim(
        definition: TerminalSurfaceAgentCommandShimDefinition,
        commandName: String? = nil,
        hermesProfileAliasURL: URL? = nil,
        wrapperURL: URL,
        stagingDirectory: URL,
        publishedDirectory: URL,
        fileManager: FileManager
    ) -> TerminalSurfaceAgentCommandShim? {
        let commandName = commandName ?? definition.commandName
        let stagingShimURL = stagingDirectory.appendingPathComponent(commandName, isDirectory: false)
        let publishedShimURL = publishedDirectory.appendingPathComponent(commandName, isDirectory: false)
        let wrapperInvocation: String
        if let hermesProfileAliasURL {
            // Hermes owns and can retarget this two-line wrapper while the
            // terminal remains open. Revalidate its bounded canonical form on
            // every invocation instead of freezing a profile into the shim.
            wrapperInvocation = """
            bree_alias_path=\(shellSingleQuoted(hermesProfileAliasURL.path))
            bree_alias_contents=""
            if [[ -f "$bree_alias_path" && -x "$bree_alias_path" ]]; then
                IFS= read -r -d '' -n 2049 bree_alias_contents < "$bree_alias_path" || true
                if (( ${#bree_alias_contents} <= 2048 )); then
                    bree_alias_contents="${bree_alias_contents//$'\\r\\n'/$'\\n'}"
                    if [[ "$bree_alias_contents" == *$'\\n' ]]; then
                        bree_alias_contents="${bree_alias_contents%$'\\n'}"
                    fi
                    if [[ "$bree_alias_contents" == *$'\\n'* ]]; then
                        bree_alias_header="${bree_alias_contents%%$'\\n'*}"
                        bree_alias_line="${bree_alias_contents#*$'\\n'}"
                        bree_alias_argument_suffix=' "$@"'
                        if [[ "$bree_alias_header" == '#!/bin/sh' &&
                              "$bree_alias_line" != *$'\\n'* &&
                              "$bree_alias_line" == exec\\ *"$bree_alias_argument_suffix" ]]; then
                            bree_alias_command="${bree_alias_line#exec }"
                            bree_alias_command="${bree_alias_command%"$bree_alias_argument_suffix"}"
                            if [[ "$bree_alias_command" == *" -p "* ]]; then
                                bree_alias_profile="${bree_alias_command##* -p }"
                                bree_alias_executable="${bree_alias_command% -p *}"
                                bree_alias_resolved_executable="$bree_alias_executable"
                                if [[ "${bree_alias_executable:0:1}" == "'" &&
                                      "${bree_alias_executable: -1}" == "'" ]]; then
                                    bree_alias_resolved_executable="${bree_alias_executable:1:${#bree_alias_executable}-2}"
                                elif [[ "$bree_alias_executable" == *[[:space:]]* ]]; then
                                    bree_alias_resolved_executable=""
                                fi
                                if [[ "$bree_alias_profile" =~ ^[a-z0-9][a-z0-9_-]{0,63}$ &&
                                      "${bree_alias_resolved_executable##*/}" == "hermes" ]]; then
                                    exec "$bree_wrapper" -p "$bree_alias_profile" "$@"
                                fi
                            fi
                        fi
                    fi
                fi
            fi
            """
        } else {
            wrapperInvocation = "exec \"$bree_wrapper\" \"$@\""
        }
        let script = """
        #!/bin/bash
        bree_wrapper=\(shellSingleQuoted(wrapperURL.path))
        bree_shim_root=\(shellSingleQuoted(publishedDirectory.path))
        if [[ ! -x "$bree_wrapper" && -n "${BREE_BUNDLED_CLI_PATH:-}" ]]; then
            bree_candidate="$(dirname "$BREE_BUNDLED_CLI_PATH")/\(definition.wrapperName)"
            if [[ -x "$bree_candidate" ]]; then
                bree_wrapper="$bree_candidate"
            fi
        fi
        if [[ ! -x "$bree_wrapper" ]]; then
            bree_cli="$(command -v bree 2>/dev/null || true)"
            if [[ -n "$bree_cli" ]]; then
                bree_candidate="$(dirname "$bree_cli")/\(definition.wrapperName)"
                if [[ -x "$bree_candidate" ]]; then
                    bree_wrapper="$bree_candidate"
                fi
            fi
        fi
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM=\(shellSingleQuoted(publishedShimURL.path))
        export \(definition.environmentVariablePrefix)_WRAPPER_SHIM_ROOT="$bree_shim_root"
        if [[ -x "$bree_wrapper" ]]; then
            \(wrapperInvocation)
        fi
        bree_path_without_shim=""
        bree_old_ifs="$IFS"
        bree_globbing_was_disabled=0
        case "$-" in
            *f*) bree_globbing_was_disabled=1 ;;
            *) set -f ;;
        esac
        IFS=:
        for bree_entry in ${PATH:-}; do
            if [[ "$bree_entry" == "$bree_shim_root" || "$bree_entry" == */bree-cli-shims/* || "$bree_entry" == */bree-cli-shims ]]; then
                continue
            fi
            if [[ -z "$bree_path_without_shim" ]]; then
                bree_path_without_shim="$bree_entry"
            else
                bree_path_without_shim="$bree_path_without_shim:$bree_entry"
            fi
        done
        IFS="$bree_old_ifs"
        if [[ "$bree_globbing_was_disabled" == 0 ]]; then
            set +f
        fi
        export PATH="$bree_path_without_shim"
        exec \(shellSingleQuoted(commandName)) "$@"
        """

        do {
            try script.write(to: stagingShimURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingShimURL.path)
            return TerminalSurfaceAgentCommandShim(
                commandName: commandName,
                wrapperName: definition.wrapperName,
                environmentVariablePrefix: definition.environmentVariablePrefix,
                directoryPath: publishedDirectory.path,
                executablePath: publishedShimURL.path
            )
        } catch {
            return nil
        }
    }
}
