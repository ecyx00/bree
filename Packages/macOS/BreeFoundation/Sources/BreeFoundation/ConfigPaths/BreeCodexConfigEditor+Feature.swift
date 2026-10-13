extension BreeCodexConfigEditor {
    static let breeCodexHooksFeatureBegin =
        "# bree-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df begin"
    static let breeCodexHooksFeatureEnd =
        "# bree-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df end"
    static let breeCodexHooksFeaturePreviousLinePrefix =
        "# bree-codex-hooks-feature-78f1e4ba-66df-4d35-93c1-67fdf1cbb7df previous line: "
    static let legacyBreeCodexHooksFeatureBegin = "# bree hooks codex feature begin"
    static let legacyBreeCodexHooksFeatureEnd = "# bree hooks codex feature end"
    static let legacyBreeCodexHooksFeaturePreviousLinePrefix =
        "# bree hooks codex feature previous line: "

    func installingHooksFeature(in existingContent: String) -> String {
        let lineEnding = BreeConfigLines().lineEnding(of: existingContent)
        var lines = tomlLines(from: existingContent)
        removeBreeCodexHooksFeatureBlock(from: &lines)
        lines.removeAll { tomlLineDefinesKey("codex_hooks", line: $0) }
        lines.removeAll { tomlLineDefinesDottedFeaturesKey("codex_hooks", line: $0) }

        let insertedLines = [
            Self.breeCodexHooksFeatureBegin,
            "hooks = true",
            Self.breeCodexHooksFeatureEnd,
        ]
        let insertedDottedLines = [
            Self.breeCodexHooksFeatureBegin,
            "features.hooks = true",
            Self.breeCodexHooksFeatureEnd,
        ]

        if let featuresStart = lines.firstIndex(where: { tomlLineIsTable("features", line: $0) }) {
            let featuresEnd = tomlTableEndIndex(in: lines, after: featuresStart)
            if featuresStart + 1 < featuresEnd,
               let hooksIndex = (featuresStart + 1..<featuresEnd)
                .first(where: { tomlLineDefinesKey("hooks", line: lines[$0]) })
            {
                if !tomlLineDefinesTrueKey("hooks", line: lines[hooksIndex]) {
                    let previousLine = lines[hooksIndex]
                    lines.replaceSubrange(
                        hooksIndex...hooksIndex,
                        with: codexHooksFeatureLines(settingLine: "hooks = true", previousLine: previousLine)
                    )
                }
            } else {
                lines.insert(contentsOf: insertedLines, at: featuresStart + 1)
            }
        } else if let dottedHooksIndex = lines.firstIndex(where: { tomlLineDefinesDottedFeaturesKey("hooks", line: $0) }) {
            if !tomlLineDefinesDottedFeaturesTrueKey("hooks", line: lines[dottedHooksIndex]) {
                let previousLine = lines[dottedHooksIndex]
                lines.replaceSubrange(
                    dottedHooksIndex...dottedHooksIndex,
                    with: codexHooksFeatureLines(settingLine: "features.hooks = true", previousLine: previousLine)
                )
            }
        } else if let firstDottedFeaturesIndex = lines.firstIndex(where: { tomlLineDefinesAnyDottedFeaturesKey($0) }) {
            lines.insert(contentsOf: insertedDottedLines, at: firstDottedFeaturesIndex)
        } else {
            if !lines.isEmpty, lines.last?.isEmpty == false {
                lines.append("")
            }
            lines.append("[features]")
            lines.append(contentsOf: insertedLines)
        }

        return tomlContent(from: lines, lineEnding: lineEnding)
    }

    func codexHooksFeatureLines(settingLine: String, previousLine: String? = nil) -> [String] {
        var lines = [Self.breeCodexHooksFeatureBegin]
        if let previousLine {
            lines.append(Self.breeCodexHooksFeaturePreviousLinePrefix + previousLine)
        }
        lines.append(settingLine)
        lines.append(Self.breeCodexHooksFeatureEnd)
        return lines
    }

    func removeBreeCodexHooksFeatureBlock(from lines: inout [String]) {
        var index = 0
        while index < lines.count {
            guard tomlLineIsCodexHooksFeatureBegin(lines[index]) else {
                index += 1
                continue
            }

            if let endIndex = lines[index...].firstIndex(where: {
                tomlLineIsCodexHooksFeatureEnd($0)
            }) {
                let previousLines = lines[index...endIndex].compactMap { line -> String? in
                    tomlCodexHooksFeaturePreviousLine(from: line)
                }
                lines.replaceSubrange(index...endIndex, with: previousLines)
            } else {
                var blockEnd = index + 1
                var previousLines: [String] = []
                if blockEnd < lines.count,
                   let previousLine = tomlCodexHooksFeaturePreviousLine(from: lines[blockEnd])
                {
                    previousLines.append(previousLine)
                    blockEnd += 1
                }
                if blockEnd < lines.count, tomlLineIsCodexHooksFeatureSetting(lines[blockEnd]) {
                    blockEnd += 1
                }
                lines.replaceSubrange(index..<blockEnd, with: previousLines)
            }
        }
    }
}
