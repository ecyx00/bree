/// Parsers for shell history files. Each returns commands oldest first.
public enum TerminalCompletionHistoryParsers {
    /// zsh, plain or `EXTENDED_HISTORY` (`: 1700000000:0;command`). A command
    /// continued over several lines with a trailing backslash is skipped.
    public static func parseZsh(_ text: String) -> [String] {
        var result: [String] = []
        var continuing = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let isContinuation = continuing
            continuing = line.hasSuffix("\\")
            if isContinuation { continue }
            var command = Substring(line)
            if command.hasPrefix(": "), let semicolon = command.firstIndex(of: ";"),
               command[command.index(command.startIndex, offsetBy: 2)..<semicolon]
                .allSatisfy({ $0.isNumber || $0 == ":" }) {
                command = command[command.index(after: semicolon)...]
            }
            if continuing { continue }
            let trimmed = command.trimmingSpaces()
            if !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    /// bash, including `HISTTIMEFORMAT` timestamp lines (`#1700000000`).
    public static func parseBash(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            if line.hasPrefix("#"), line.dropFirst().allSatisfy(\.isNumber) { return nil }
            let trimmed = line.trimmingSpaces()
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// fish (`- cmd: git status` followed by `  when: 1700000000`). Commands
    /// with an embedded newline are skipped.
    public static func parseFish(_ text: String) -> [String] {
        var result: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("- cmd: ") else { continue }
            let body = line.dropFirst("- cmd: ".count)
            var command = ""
            var chars = body.makeIterator()
            var skip = false
            while let ch = chars.next() {
                guard ch == "\\" else { command.append(ch); continue }
                switch chars.next() {
                case "\\": command.append("\\")
                case "n": skip = true
                case let other?: command.append("\\"); command.append(other)
                case nil: command.append("\\")
                }
            }
            let trimmed = command.trimmingSpaces()
            if !skip, !trimmed.isEmpty { result.append(trimmed) }
        }
        return result
    }

    /// Newest-first, deduplicated, at most `limit` entries.
    public static func recent(_ oldestFirst: [String], limit: Int) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for command in oldestFirst.reversed() {
            guard seen.insert(command).inserted else { continue }
            result.append(command)
            if result.count >= limit { break }
        }
        return result
    }
}

private extension StringProtocol {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while s.first == " " || s.first == "\t" || s.first == "\r" { s.removeFirst() }
        while s.last == " " || s.last == "\t" || s.last == "\r" { s.removeLast() }
        return String(s)
    }
}
