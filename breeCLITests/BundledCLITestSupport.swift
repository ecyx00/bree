import Foundation
import XCTest

/// Resolves the `bree` binary these tests spawn.
///
/// `breeTests` resolves it relative to the app host that loads it. `breeCLITests`
/// has no app host, so it resolves it from `BREE_CLI_PATH` or relative to the
/// built products directory the bundle itself was copied into.
enum BundledCLITestSupport {
    static func ciRuntimeSourceRootEnvironment() -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        guard let runtimeRoot = [
            environment["BREE_CI_RUNTIME_SOURCE_ROOT"],
            environment["TEST_RUNNER_BREE_CI_RUNTIME_SOURCE_ROOT"],
        ].compactMap({ $0 }).first(where: { !$0.isEmpty }) else {
            return [:]
        }
        return [
            "BREE_CI_RUNTIME_SOURCE_ROOT": runtimeRoot,
            "TEST_RUNNER_BREE_CI_RUNTIME_SOURCE_ROOT": runtimeRoot,
        ]
    }

    static func repositoryRoot(file: StaticString = #filePath) -> URL {
        let environment = ProcessInfo.processInfo.environment
        var roots: [URL] = []
        for key in ["BREE_CI_RUNTIME_SOURCE_ROOT", "TEST_RUNNER_BREE_CI_RUNTIME_SOURCE_ROOT"] {
            if let runtimeRoot = environment[key], !runtimeRoot.isEmpty {
                roots.append(URL(fileURLWithPath: runtimeRoot, isDirectory: true)
                    .appendingPathComponent("src", isDirectory: true))
            }
        }
        let fileRoot = URL(fileURLWithPath: String(describing: file))
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        roots.append(fileRoot)
        roots.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        return roots.first(where: {
            FileManager.default.isExecutableFile(
                atPath: $0.appendingPathComponent("Resources/bin/bree-claude-wrapper").path
            )
        }) ?? fileRoot
    }

    /// The daemon handshake must match the CLI under test, not the xctest host.
    static func appVersion(cliPath: String) throws -> String {
        let result = CLIHookProcessRunner.run(
            executablePath: cliPath,
            arguments: ["--version"],
            environment: [:],
            timeout: 10
        )
        let fields = result.stdout.split(whereSeparator: { $0.isWhitespace })
        guard !result.timedOut, result.status == 0,
              fields.count >= 2, fields[0] == "bree",
              fields[1].first?.isNumber == true else {
            throw NSError(domain: "bree.tests", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Cannot read CLI version: \(result.stdout) \(result.stderr)",
            ])
        }
        return String(fields[1])
    }

    /// Path to the bundled `bree` CLI under test.
    ///
    /// Resolution order:
    ///   1. `BREE_CLI_PATH` — CI and local runs point this at the binary they
    ///      built, which is what makes this bundle independent of an app host.
    ///   2. `<products>/bree` — the `bree-cli` target's own product, which sits
    ///      beside this .xctest bundle in `Build/Products/<config>`.
    ///   3. Any `*.app/Contents/Resources/bin/bree` below the products
    ///      directory — the copy the app bundle ships.
    static func bundledCLIPath(
        for bundleClass: AnyClass = CLITestBundleAnchor.self,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        try bundledCLIURL(for: bundleClass, file: file, line: line).path
    }

    static func bundledCLIURL(
        for bundleClass: AnyClass = CLITestBundleAnchor.self,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["BREE_CLI_PATH"], !override.isEmpty {
            let overrideURL = URL(fileURLWithPath: override)
            if fileManager.isExecutableFile(atPath: overrideURL.path) {
                return overrideURL
            }
            let message = "BREE_CLI_PATH is set but not executable: \(override)"
            XCTFail(message, file: file, line: line)
            throw NSError(domain: "bree.tests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: message,
            ])
        }

        let productsURL = Bundle(for: bundleClass).bundleURL.deletingLastPathComponent()

        let siblingCLI = productsURL.appendingPathComponent("bree", isDirectory: false)
        if fileManager.isExecutableFile(atPath: siblingCLI.path) {
            return siblingCLI
        }

        let enumerator = fileManager.enumerator(
            at: productsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        while let item = enumerator?.nextObject() as? URL {
            guard item.lastPathComponent == "bree",
                  item.path.contains(".app/Contents/Resources/bin/bree"),
                  fileManager.isExecutableFile(atPath: item.path) else { continue }
            return item
        }

        let message = """
        bree CLI not found. Set BREE_CLI_PATH, or build the bree-cli product \
        into \(productsURL.path).
        """
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "bree.tests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }
}
