#!/usr/bin/env swift

import AppKit
import Darwin
import Dispatch
import Foundation

private struct Options {
    let appURL: URL

    init(arguments: ArraySlice<String>) throws {
        guard let path = arguments.first, !path.isEmpty else {
            throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "usage: launch-bundle-app.swift <app-path>"
            ])
        }
        if let option = arguments.dropFirst().first {
            throw NSError(domain: "LaunchBundleApp", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "unknown option '\(option)'"
            ])
        }
        self.appURL = URL(fileURLWithPath: path, isDirectory: true)
    }
}

// LaunchServices can retain environment values from a different tagged app.
// Remove every bree/ghostty runtime override before applying this bundle's
// LSEnvironment, so a launch for tag B cannot inherit tag A's socket.
private let runtimeEnvironmentPrefixes = ["BREE_", "GHOSTTY_"]

private func launchEnvironment(for appURL: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    for key in environment.keys where runtimeEnvironmentPrefixes.contains(where: key.hasPrefix) {
        environment.removeValue(forKey: key)
    }
    environment.removeValue(forKey: "BREED_UNIX_PATH")

    if let bundle = Bundle(url: appURL),
       let launchEnvironment = bundle.infoDictionary?["LSEnvironment"] as? [String: Any] {
        for (key, value) in launchEnvironment {
            guard let value = value as? String else { continue }
            environment[key] = value
        }
    }
    return environment
}

private func run() async throws {
    let options = try Options(arguments: CommandLine.arguments.dropFirst())
    guard FileManager.default.fileExists(atPath: options.appURL.path) else {
        throw NSError(domain: "LaunchBundleApp", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "application bundle does not exist: \(options.appURL.path)"
        ])
    }
    guard Bundle(url: options.appURL)?.executableURL != nil else {
        throw NSError(domain: "LaunchBundleApp", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "application bundle has no executable: \(options.appURL.path)"
        ])
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    configuration.environment = launchEnvironment(for: options.appURL)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        NSWorkspace.shared.openApplication(at: options.appURL, configuration: configuration) { _, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

Task {
    do {
        try await run()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
