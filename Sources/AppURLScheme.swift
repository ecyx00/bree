import Foundation

/// The custom URL scheme this build registers for `bree://` SSH and workspace
/// links (`BREE_AUTH_CALLBACK_SCHEME` in the build settings).
///
/// Resolution order: the `BREE_AUTH_CALLBACK_SCHEME` process-environment
/// override, then (DEBUG) `bree-dev` or `bree-dev-<tag>`, then the release
/// channel by bundle identifier.
enum AppURLScheme {
    /// The scheme for the running process.
    static var current: String {
        scheme(
            environment: ProcessInfo.processInfo.environment,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            isDebugBuild: isDebugBuild
        )
    }

    private static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    static func scheme(
        environment: [String: String],
        bundleIdentifier: String?,
        isDebugBuild: Bool
    ) -> String {
        if let overridden = environment["BREE_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            // Untagged Debug builds register bree-dev:// so they can coexist
            // with the installed stable app. Tagged Debug builds use
            // bree-dev-<tag>://.
            if let tag = environment["BREE_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedTag(tag) {
                return "bree-dev-\(schemeTag)"
            }
            return "bree-dev"
        }
        if bundleIdentifier == "com.bree.app" { return "bree" }
        if bundleIdentifier == "com.bree.app.nightly" { return "bree-nightly" }
        if bundleIdentifier == "com.bree.app.rc" { return "bree-rc" }
        return "bree"
    }

    private static func sanitizedTag(_ rawTag: String) -> String? {
        var result = ""
        var previousWasHyphen = false
        for scalar in rawTag.lowercased().unicodeScalars {
            let isAllowed = (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if !previousWasHyphen {
                result.append("-")
                previousWasHyphen = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? nil : result
    }
}
