import Darwin
internal import Foundation
internal import BreeCore
internal import BreeFoundation

// Transport bring-up for the stdio exec daemon path. Faithful lift; argument composition lives on
// WorkspaceRemoteConfiguration in BreeCore.
extension RemoteDaemonRPCClient {
    func startViaSSHExec() throws {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        stateQueue.sync {
            self.stdinPipe = stdinPipe
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
        }

        process.executableURL = URL(fileURLWithPath: transportExecutableOverride ?? "/usr/bin/ssh")
        process.arguments = configuration.daemonTransportArguments(remotePath: remotePath)
        process.environment = configuration.sshProcessEnvironment
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
                self?.stateQueue.async { [weak self] in
                    self?.consumeStdoutData(Data())
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.stateQueue.async { [weak self] in
                    self?.consumeStderrData(data)
                }
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        process.terminationHandler = { [weak self] terminated in
            self?.stateQueue.async { [weak self] in
                self?.handleProcessTermination(terminated)
            }
        }

        do {
            try process.run()
        } catch {
            throw NSError(domain: "bree.remote.daemon.rpc", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to launch SSH daemon transport: \(error.localizedDescription)",
            ])
        }

        stateQueue.sync {
            self.process = process
            self.stdinHandle = stdinPipe.fileHandleForWriting
            self.stdoutHandle = stdoutPipe.fileHandleForReading
            self.stderrHandle = stderrPipe.fileHandleForReading
        }
    }

    static func startupFailureDetail(
        process: Process,
        stderrPipe: Pipe,
        gracePeriod: TimeInterval
    ) -> String? {
        if process.isRunning {
            let originalTerminationHandler = process.terminationHandler
            let exitSemaphore = DispatchSemaphore(value: 0)
            process.terminationHandler = { terminated in
                originalTerminationHandler?(terminated)
                exitSemaphore.signal()
            }
            if !process.isRunning {
                exitSemaphore.signal()
            }
            guard exitSemaphore.wait(timeout: .now() + max(0, gracePeriod)) == .success else {
                return nil
            }
        }
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFileOrEmpty()
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return bestErrorLine(stderr: stderr) ?? "status=\(process.terminationStatus)"
    }

    static func bestErrorLine(stderr: String) -> String? {
        let lines = stderr
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !isNoiseLine(line) {
            return line
        }
        return lines.last
    }

    static func isNoiseLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered.hasPrefix("warning: permanently added") { return true }
        if lowered.hasPrefix("debug") { return true }
        if lowered.hasPrefix("transferred:") { return true }
        if lowered.hasPrefix("openbsd_") { return true }
        if lowered.contains("pseudo-terminal will not be allocated") { return true }
        return false
    }
}
