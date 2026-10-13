import BreeFoundation
import Darwin
import Foundation

extension BREECLI {
    static var glaedaUsage: String {
        BreeGlaedaExecutionLocalization().string(
            "glaeda.cli.usage",
            defaultValue: """
            Usage: bree glaeda <request|observe> [options]

            Exchange one semantic execution request with the execution service.

            Subcommands:
              request
                --request-ref <ref>        Bree caller correlation reference
                --work-ref <ref>           Bree work correlation reference
                --repository <owner/repo>  Canonical Git repository identity
                --commit <40-hex>          Exact Git commit
                --tree <40-hex>            Exact Git tree
                [--reuse <prefer_valid_reuse|no_preference>]

                Emits canonical execution-request JSON to stdout.
                Bree workspace, machine, shell command, and environment stay outside this request.

              observe
                --request <path>           Exact request document previously emitted
                --receipt <path|->         Bounded execution receipt, or - for stdin

                Validates request/result correlation and emits a bounded Bree observation.
                Terminal states require a workload-receipt digest.

            Examples:
              bree glaeda request --request-ref bree:exec:42 --work-ref bree:work:42 \
                --repository owner/repo --commit <commit> --tree <tree>
              bree glaeda observe --request request.json --receipt result.json
            """
        )
    }

    func runGlaedaCommand(commandArgs: [String]) throws {
        let localization = BreeGlaedaExecutionLocalization()
        guard let subcommand = commandArgs.first?.lowercased() else {
            throw CLIError(message: Self.glaedaUsage)
        }
        let rest = Array(commandArgs.dropFirst())
        do {
            switch subcommand {
            case "request":
                let request = try glaedaRequest(arguments: rest, localization: localization)
                let data = try BreeGlaedaExecutionContract().encodeRequest(request)
                cliWriteStdout(data)
            case "observe":
                let observation = try glaedaObservation(
                    arguments: rest,
                    localization: localization
                )
                let data = try BreeGlaedaExecutionContract().encodeObservation(observation)
                cliWriteStdout(data)
            case "help", "--help", "-h":
                guard rest.isEmpty else {
                    throw CLIError(
                        message: localization.string(
                            "glaeda.cli.error.helpArguments",
                            defaultValue: "This help command accepts no additional arguments."
                        )
                    )
                }
                cliWriteStdout(Self.glaedaUsage + "\n")
            default:
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.unknownSubcommand",
                        defaultValue: "Unknown execution subcommand: %@",
                        subcommand
                    ) + "\n\n" + Self.glaedaUsage
                )
            }
        } catch let error as BreeGlaedaExecutionContractError {
            throw CLIError(message: localization.contractError(error))
        }
    }

    private func glaedaRequest(
        arguments: [String],
        localization: BreeGlaedaExecutionLocalization
    ) throws -> BreeGlaedaExecutionRequest {
        let options = try glaedaParseOptions(
            arguments,
            allowed: [
                "--request-ref",
                "--work-ref",
                "--repository",
                "--commit",
                "--tree",
                "--reuse",
            ],
            localization: localization
        )
        return BreeGlaedaExecutionRequest(
            externalRequestRef: try glaedaRequiredOption(
                "--request-ref",
                options: options,
                localization: localization
            ),
            workRef: try glaedaRequiredOption(
                "--work-ref",
                options: options,
                localization: localization
            ),
            repository: try glaedaRequiredOption(
                "--repository",
                options: options,
                localization: localization
            ),
            commit: try glaedaRequiredOption(
                "--commit",
                options: options,
                localization: localization
            ),
            tree: try glaedaRequiredOption(
                "--tree",
                options: options,
                localization: localization
            ),
            reuseHint: options["--reuse"] ?? "prefer_valid_reuse"
        )
    }

    private func glaedaObservation(
        arguments: [String],
        localization: BreeGlaedaExecutionLocalization
    ) throws -> BreeGlaedaExecutionObservation {
        let options = try glaedaParseOptions(
            arguments,
            allowed: ["--request", "--receipt"],
            localization: localization
        )
        let requestPath = try glaedaRequiredOption(
            "--request",
            options: options,
            localization: localization
        )
        let receiptPath = try glaedaRequiredOption(
            "--receipt",
            options: options,
            localization: localization
        )
        let requestData = try glaedaReadDocument(
            path: requestPath,
            localization: localization
        )
        let receiptData = try glaedaReadDocument(
            path: receiptPath,
            localization: localization
        )
        return try BreeGlaedaExecutionContract().observe(
            requestData: requestData,
            receiptData: receiptData
        )
    }

    private func glaedaParseOptions(
        _ arguments: [String],
        allowed: Set<String>,
        localization: BreeGlaedaExecutionLocalization
    ) throws -> [String: String] {
        var result: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard allowed.contains(option) else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.unknownOption",
                        defaultValue: "Unknown option: %@",
                        option
                    )
                )
            }
            guard result[option] == nil else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.duplicateOption",
                        defaultValue: "%@ may only be supplied once.",
                        option
                    )
                )
            }
            index += 1
            guard index < arguments.count, !arguments[index].hasPrefix("--") else {
                throw CLIError(
                    message: localization.format(
                        "glaeda.cli.error.optionValueRequired",
                        defaultValue: "%@ requires a value.",
                        option
                    )
                )
            }
            result[option] = arguments[index]
            index += 1
        }
        return result
    }

    private func glaedaRequiredOption(
        _ key: String,
        options: [String: String],
        localization: BreeGlaedaExecutionLocalization
    ) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw CLIError(
                message: localization.format(
                    "glaeda.cli.error.missingOption",
                    defaultValue: "Missing required option: %@",
                    key
                )
            )
        }
        return value
    }

    private func glaedaReadDocument(
        path: String,
        localization: BreeGlaedaExecutionLocalization
    ) throws -> Data {
        if path == "-" {
            let data = FileHandle.standardInput.readData(
                ofLength: BreeGlaedaExecutionContract.maxDocumentBytes + 1
            )
            guard data.count <= BreeGlaedaExecutionContract.maxDocumentBytes else {
                throw CLIError(
                    message: localization.string(
                        "glaeda.cli.error.documentTooLarge",
                        defaultValue: "The input document exceeds the size limit."
                    )
                )
            }
            return data
        }

        let descriptor = path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        guard descriptor >= 0 else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentUnavailable",
                    defaultValue: "The input document is unavailable."
                )
            )
        }
        defer { Darwin.close(descriptor) }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.regularFileRequired",
                    defaultValue: "The input document must be a regular file."
                )
            )
        }

        let limit = BreeGlaedaExecutionContract.maxDocumentBytes + 1
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(1024, limit))
        while data.count < limit {
            let count = min(buffer.count, limit - data.count)
            let readCount = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, count)
            }
            if readCount > 0 {
                data.append(buffer, count: readCount)
                continue
            }
            if readCount == 0 {
                break
            }
            if errno == EINTR {
                continue
            }
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentUnavailable",
                    defaultValue: "The input document is unavailable."
                )
            )
        }

        guard data.count <= BreeGlaedaExecutionContract.maxDocumentBytes else {
            throw CLIError(
                message: localization.string(
                    "glaeda.cli.error.documentTooLarge",
                    defaultValue: "The input document exceeds the size limit."
                )
            )
        }
        return data
    }
}
