import BREEAgentLaunch
import Darwin
import Foundation
import os

nonisolated private let cliForwardingLogger = Logger(subsystem: "com.bree.app", category: "CLIForwarding")

enum CLIForwardingLaunchRouter {
    private static let guardKey = "BREE_CLI_FORWARDED"

    /// Classifies a launch of the GUI binary via the pure policy in
    /// BREEAgentLaunch; this router keeps only the exec/exit glue.
    static func forwardingDecision(
        arguments argv: [String],
        forwardingGuardIsSet: Bool
    ) -> CLIForwardingDecision {
        CLIForwardingDecision(arguments: argv, forwardingGuardIsSet: forwardingGuardIsSet)
    }

    /// If `argv` looks like a CLI invocation, exec the bundled CLI at
    /// `Contents/Resources/bin/bree` and never return. macOS-launch arguments
    /// (`-psn_...`, other `-` flags) and `bree://` URLs are left to the GUI.
    /// A CLI invocation that cannot be forwarded (the forwarding guard is
    /// already set) exits with an error instead of falling through to the GUI.
    static func forwardToBundledCLIIfNeeded(
        arguments argv: [String] = CommandLine.arguments,
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) {
        switch forwardingDecision(arguments: argv, forwardingGuardIsSet: getenv(guardKey) != nil) {
        case .launchGUI:
            return
        case .failForwardingLoop:
            writeStderr(localizedForwardingLoopError())
            Darwin.exit(127)
        case .forwardToBundledCLI:
            break
        }

        guard let cliURL = bundledCLIURL(bundle: bundle, fileManager: fileManager) else {
            #if DEBUG
            let resourcePath = bundle.resourceURL?.appendingPathComponent("bin/bree").path ?? "<missing>"
            let executablePath = processExecutableURL()?.path ?? "<missing>"
            cliForwardingLogger.debug("bundled CLI not found for forwarding; bundleID=\(bundle.bundleIdentifier ?? "<missing>", privacy: .public) resourcePath=\(resourcePath, privacy: .public) executablePath=\(executablePath, privacy: .public)")
            #endif
            writeStderr(localizedMissingBundledCLIError())
            Darwin.exit(127)
        }

        guard var cArgs = makeCStringArguments(cliPath: cliURL.path, arguments: argv) else {
            writeStderr(localizedArgumentAllocationError())
            Darwin.exit(ENOMEM)
        }

        setenv(guardKey, "1", 1)

        let execErrno = cliURL.path.withCString { execPath in
            cArgs.withUnsafeMutableBufferPointer { buffer in
                Darwin.execv(execPath, buffer.baseAddress)
                return errno
            }
        }

        freeCStringArguments(cArgs)
        unsetenv(guardKey)

        let errorText = String(cString: strerror(execErrno))
        cliForwardingLogger.warning("failed to exec bundled CLI")
        #if DEBUG
        cliForwardingLogger.debug("failed to exec bundled CLI at \(cliURL.path, privacy: .public): \(errorText, privacy: .public)")
        #endif
        writeStderr(localizedExecFailureError())
        Darwin.exit(127)
    }

    /// Delegates the pure argv classification to BREEAgentLaunch.
    static func shouldForwardToBundledCLI(arguments argv: [String]) -> Bool {
        CLIForwardingDecision.shouldForwardToBundledCLI(arguments: argv)
    }

    static func bundledCLIURL(
        bundle: Bundle = .main,
        fileManager: FileManager = .default,
        executableURL: URL? = processExecutableURL()
    ) -> URL? {
        let bundleCandidate = bundle.resourceURL?.appendingPathComponent("bin/bree")
        if let bundleCandidate, fileManager.isExecutableFile(atPath: bundleCandidate.path) {
            return bundleCandidate
        }

        guard let executableURL else { return nil }
        let resourcesURL = executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let executableCandidate = resourcesURL.appendingPathComponent("bin/bree")
        if fileManager.isExecutableFile(atPath: executableCandidate.path) {
            return executableCandidate
        }

        return nil
    }

    private static func makeCStringArguments(cliPath: String, arguments argv: [String]) -> [UnsafeMutablePointer<CChar>?]? {
        var cArgs: [UnsafeMutablePointer<CChar>?] = []

        guard let cliPathArgument = strdup(cliPath) else { return nil }
        cArgs.append(cliPathArgument)

        for arg in argv.dropFirst() {
            guard let duplicated = strdup(arg) else {
                freeCStringArguments(cArgs)
                return nil
            }
            cArgs.append(duplicated)
        }
        cArgs.append(nil)
        return cArgs
    }

    private static func freeCStringArguments(_ cArgs: [UnsafeMutablePointer<CChar>?]) {
        for ptr in cArgs where ptr != nil { free(ptr) }
    }

    private static func writeStderr(_ message: String) {
        fputs("\(message)\n", stderr)
        fflush(stderr)
    }

    private static func localizedMissingBundledCLIError() -> String {
        String(
            localized: "cli.forwarding.error.missingBundledCLI",
            defaultValue: "Bree could not run this command from the app bundle. Reinstall Bree or run the command from a standard Bree CLI installation."
        )
    }

    private static func localizedArgumentAllocationError() -> String {
        String(
            localized: "cli.forwarding.error.allocateArguments",
            defaultValue: "Bree could not start this command. Try again, or reinstall Bree if the problem continues."
        )
    }

    private static func localizedExecFailureError() -> String {
        String(
            localized: "cli.forwarding.error.execFailed",
            defaultValue: "Bree could not start the command-line tool from the app bundle. Reinstall Bree or run the command from a standard Bree CLI installation."
        )
    }

    /// User-facing message for a detected forwarding loop: the bundled CLI
    /// resolved back to the GUI binary, so the command cannot be handed off.
    private static func localizedForwardingLoopError() -> String {
        String(
            localized: "cli.forwarding.error.forwardingLoop",
            defaultValue: "Bree could not hand this command to its bundled command-line tool because forwarding resolved back to the app itself. Reinstall Bree or run the command from a standard Bree CLI installation."
        )
    }

    private static func processExecutableURL() -> URL? {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        guard size > 0 else { return nil }

        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath()
    }
}
