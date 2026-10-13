import Foundation

/// One option or argument reported by the user's shell (or a `--help` page).
public struct TerminalShellOption: Equatable, Sendable {
    /// Text that replaces the current word. Options that need a value end
    /// with `=`.
    public var text: String
    public var detail: String?

    public init(text: String, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }
}

/// Pure parsers for the out-of-band completion sources, plus the `--help`
/// denylist and the cheap `.zshrc` fpath scan.
public enum TerminalCompletionShellParsers {
    /// Output of `fish complete -C` and of the zsh capture helper: one
    /// `candidate<TAB>description` per line, description optional. Also reads bash `compgen` output (one
    /// candidate per line).
    public static func parseTabSeparated(_ text: String) -> [TerminalShellOption] {
        var seen = Set<String>()
        var out: [TerminalShellOption] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            let candidate = parts[0].trimmingCharacters(in: .whitespaces)
            guard !candidate.isEmpty, seen.insert(candidate).inserted else { continue }
            let detail = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            out.append(TerminalShellOption(text: candidate, detail: detail.isEmpty ? nil : detail))
        }
        return out
    }

    /// Parses `-x, --long[=ARG]  description` lines of a `--help` page.
    /// Only indented lines count; the description starts after the first run
    /// of two spaces or a tab. `--long=ARG` yields `--long=`, `--long[=ARG]`
    /// yields `--long`.
    public static func parseHelp(_ text: String) -> [TerminalShellOption] {
        var seen = Set<String>()
        var out: [TerminalShellOption] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            guard let first = rawLine.first, first == " " || first == "\t", rawLine.count < 400 else { continue }
            let line = rawLine.drop(while: { $0 == " " || $0 == "\t" })
            guard line.hasPrefix("-") else { continue }
            var specs = Substring(line)
            var detail = ""
            if let gap = line.range(of: "  ") ?? line.range(of: "\t") {
                specs = line[..<gap.lowerBound]
                detail = line[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            }
            for piece in specs.split(whereSeparator: { $0 == "," || $0 == "|" }) {
                guard let token = piece.split(separator: " ").first else { continue }
                var name = Substring(token)
                var value = false
                if let cut = token.firstIndex(where: { $0 == "=" || $0 == "[" || $0 == "<" }) {
                    name = token[..<cut]
                    value = token[cut] == "="
                }
                guard isOptionName(name), seen.insert(String(name)).inserted else { continue }
                out.append(TerminalShellOption(text: String(name) + (value ? "=" : ""), detail: detail.isEmpty ? nil : detail))
            }
        }
        return out
    }

    private static func isOptionName(_ name: Substring) -> Bool {
        let dashes = name.prefix(while: { $0 == "-" }).count
        let body = name.dropFirst(dashes)
        guard (1...2).contains(dashes), let head = body.first, head.isLetter || head.isNumber else { return false }
        return body.allSatisfy { $0.isLetter || $0.isNumber || "_.-".contains($0) }
    }

    /// Commands `--help` is never run for: destructive, privileged, remote or
    /// interactive (pagers, editors, shells, `git` which opens `man`).
    private static let helpDenylist: Set<String> = [
        "rm", "rmdir", "dd", "mv", "cp", "sudo", "doas", "su", "ssh", "scp", "sftp", "mosh", "telnet", "ftp",
        "nc", "ncat", "socat", "mkfs", "fdisk", "diskutil", "shutdown", "reboot", "halt", "kill", "killall",
        "pkill", "launchctl", "vi", "vim", "nvim", "nano", "emacs", "less", "more", "man", "top", "htop",
        "watch", "tmux", "screen", "login", "passwd", "sh", "bash", "zsh", "fish", "git", "xargs", "env",
        "open", "osascript", "defaults", "tee", "yes",
    ]

    public static func isHelpDenied(_ command: String) -> Bool {
        command.contains("/") || helpDenylist.contains(command)
    }

    /// Directories a `.zshrc` adds to fpath, read as text (never sourced):
    /// literal `~/…`, `$HOME/…` and absolute paths on lines that assign
    /// `fpath` (`fpath=` or `fpath+=`). Comments are skipped; nothing else is evaluated.
    public static func extraFpath(zshrc: String, home: String) -> [String] {
        var out: [String] = []
        for rawLine in zshrc.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.contains("fpath=") || line.contains("fpath+="), !line.hasPrefix("#") else { continue }
            let body = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            for word in body.split(whereSeparator: { " \t()=\"':;".contains($0) }) {
                var path = String(word)
                if path.hasPrefix("~/") {
                    path = home + path.dropFirst(1)
                } else if path.hasPrefix("${HOME}/") {
                    path = home + path.dropFirst("${HOME}".count)
                } else if path.hasPrefix("$HOME/") {
                    path = home + path.dropFirst("$HOME".count)
                }
                guard path.hasPrefix("/"), !path.contains("$"), !out.contains(path) else { continue }
                out.append(path)
            }
        }
        return out
    }
}
