import Foundation

/// The custom URL scheme this build registers for `cmux://` SSH and workspace
/// links (`CMUX_AUTH_CALLBACK_SCHEME` in the build settings).
///
/// Resolution order: the `CMUX_AUTH_CALLBACK_SCHEME` process-environment
/// override, then (DEBUG) `cmux-dev` or `cmux-dev-<tag>`, then the release
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
        if let overridden = environment["CMUX_AUTH_CALLBACK_SCHEME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !overridden.isEmpty {
            return overridden
        }
        if isDebugBuild {
            // Untagged Debug builds register cmux-dev:// so they can coexist
            // with the installed stable app. Tagged Debug builds use
            // cmux-dev-<tag>://.
            if let tag = environment["CMUX_TAG"]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !tag.isEmpty,
               let schemeTag = sanitizedTag(tag) {
                return "cmux-dev-\(schemeTag)"
            }
            return "cmux-dev"
        }
        if bundleIdentifier == "com.bree.app" { return "bree" }
        if bundleIdentifier == "com.cmuxterm.app.nightly" { return "cmux-nightly" }
        if bundleIdentifier == "com.cmuxterm.app.rc" { return "cmux-rc" }
        return "cmux"
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
