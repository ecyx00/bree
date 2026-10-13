extension BreeCodexConfigEditor {
    static let breeCodexHookTrustBegin =
        "# bree-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 begin"
    static let breeCodexHookTrustEnd =
        "# bree-codex-hook-trust-f5cc24da-7a09-4b20-a756-89e7786f6738 end"

    enum HookTrustBlockRemovalResult {
        case notFound
        case removed
        case malformed
    }

    func removingHookTrust(
        in existingContent: String,
        entries: [HookTrustEntry],
        removingEscapedKeyPrefixes: Set<String>,
        removingTrustedHashes: Set<String>
    ) -> String {
        let lineEnding = BreeConfigLines().lineEnding(of: existingContent)
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(removingTrustedHashes)
        let removalResult = removeBreeCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: removingEscapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        )
        if removalResult == .malformed {
            stripMalformedBreeCodexHookTrustMarker(from: &lines)
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)
        return tomlContent(from: lines, lineEnding: lineEnding)
    }

    func installingHookTrust(
        in existingContent: String,
        entries: [HookTrustEntry],
        removingEscapedKeyPrefixes: Set<String>,
        removingTrustedHashes: Set<String>
    ) -> HookInstallResult {
        let lineEnding = BreeConfigLines().lineEnding(of: existingContent)
        var lines = tomlLines(from: existingContent)
        let escapedKeys = Set(entries.map { tomlBasicStringContent($0.key) })
        let trustedHashes = Set(entries.map(\.trustedHash)).union(removingTrustedHashes)
        let removalResult = removeBreeCodexHookTrustBlock(
            from: &lines,
            removingEscapedKeys: escapedKeys,
            removingEscapedKeyPrefixes: removingEscapedKeyPrefixes,
            removingTrustedHashes: trustedHashes
        )
        if removalResult == .malformed {
            stripMalformedBreeCodexHookTrustMarker(from: &lines)
        }
        guard !entries.isEmpty else {
            return HookInstallResult(
                content: tomlContent(from: lines, lineEnding: lineEnding),
                installedTrust: false
            )
        }
        removeCodexHookTrustTables(withEscapedKeys: escapedKeys, from: &lines)

        if !lines.isEmpty, lines.last?.isEmpty == false {
            lines.append("")
        }
        lines.append(Self.breeCodexHookTrustBegin)
        for entry in entries {
            lines.append("[hooks.state.\"\(tomlBasicStringContent(entry.key))\"]")
            lines.append("trusted_hash = \"\(tomlBasicStringContent(entry.trustedHash))\"")
        }
        lines.append(Self.breeCodexHookTrustEnd)
        return HookInstallResult(
            content: tomlContent(from: lines, lineEnding: lineEnding),
            installedTrust: true
        )
    }

    @discardableResult
    func removeBreeCodexHookTrustBlock(
        from lines: inout [String],
        removingEscapedKeys escapedKeys: Set<String> = [],
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String> = [],
        removingTrustedHashes trustedHashes: Set<String> = []
    ) -> HookTrustBlockRemovalResult {
        var replacements: [(range: ClosedRange<Int>, lines: [String])] = []
        var index = 0
        while index < lines.count {
            guard lines[index] == Self.breeCodexHookTrustBegin else {
                index += 1
                continue
            }

            guard let endIndex = lines[index...].firstIndex(of: Self.breeCodexHookTrustEnd) else {
                return .malformed
            }
            let preservedLines = codexHookTrustBlockUnownedLines(
                from: lines[(index + 1)..<endIndex],
                removingEscapedKeys: escapedKeys,
                removingEscapedKeyPrefixes: escapedKeyPrefixes,
                removingTrustedHashes: trustedHashes
            )
            replacements.append((index...endIndex, preservedLines))
            index = endIndex + 1
        }

        for replacement in replacements.reversed() {
            lines.replaceSubrange(replacement.range, with: replacement.lines)
        }
        return replacements.isEmpty ? .notFound : .removed
    }

    func codexHookTrustBlockUnownedLines(
        from lines: ArraySlice<String>,
        removingEscapedKeys escapedKeys: Set<String>,
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String>,
        removingTrustedHashes trustedHashes: Set<String>
    ) -> [String] {
        var preserved: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            if let escapedKey = codexHookTrustTableEscapedKey(from: lines[index]) {
                let tableStart = index
                index += 1
                while index < lines.endIndex, !tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                    index += 1
                }
                if !codexHookTrustEscapedKeyIsRemoved(
                    escapedKey,
                    trustedHash: codexHookTrustTrustedHash(from: lines[tableStart..<index]),
                    removingEscapedKeys: escapedKeys,
                    removingEscapedKeyPrefixes: escapedKeyPrefixes,
                    removingTrustedHashes: trustedHashes
                ) {
                    preserved.append(contentsOf: lines[tableStart..<index])
                }
                continue
            }

            guard tomlLineIsAnyTableHeader(lines[index]) else {
                // Marker drift can capture user config lines; only bree-owned
                // hook trust tables are safe to discard.
                preserved.append(lines[index])
                index += 1
                continue
            }
            let tableStart = index
            index += 1
            while index < lines.endIndex, !tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                index += 1
            }
            preserved.append(contentsOf: lines[tableStart..<index])
        }
        return preserved
    }

    func codexHookTrustEscapedKeyIsRemoved(
        _ escapedKey: String,
        trustedHash: String?,
        removingEscapedKeys escapedKeys: Set<String>,
        removingEscapedKeyPrefixes escapedKeyPrefixes: Set<String>,
        removingTrustedHashes trustedHashes: Set<String>
    ) -> Bool {
        if escapedKeys.contains(escapedKey) {
            return true
        }
        guard let trustedHash, trustedHashes.contains(trustedHash) else {
            return false
        }
        return escapedKeyPrefixes.contains { escapedKey.hasPrefix($0) }
    }

    func codexHookTrustTrustedHash(from lines: ArraySlice<String>) -> String? {
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let equalsIndex = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equalsIndex]).trimmingCharacters(in: .whitespaces)
            guard key == "trusted_hash" else { continue }
            let valueStart = trimmed.index(after: equalsIndex)
            let value = String(trimmed[valueStart...]).trimmingCharacters(in: .whitespaces)
            guard value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 else { continue }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    func stripMalformedBreeCodexHookTrustMarker(from lines: inout [String]) {
        lines.removeAll { $0 == Self.breeCodexHookTrustBegin }
    }

    func removeCodexHookTrustTables(withEscapedKeys keys: Set<String>, from lines: inout [String]) {
        guard !keys.isEmpty else { return }
        var index = 0
        while index < lines.count {
            guard let escapedKey = codexHookTrustTableEscapedKey(from: lines[index]),
                  keys.contains(escapedKey) else {
                index += 1
                continue
            }
            let endIndex = codexHookTrustTableEndIndex(in: lines, after: index)
            lines.removeSubrange(index..<endIndex)
        }
    }

    func codexHookTrustTableEndIndex(in lines: [String], after tableStart: Int) -> Int {
        var index = tableStart + 1
        while index < lines.count {
            if tomlLineIsCodexHookTrustBlockTableBoundary(lines[index]) {
                return index
            }
            index += 1
        }
        return lines.count
    }
}
