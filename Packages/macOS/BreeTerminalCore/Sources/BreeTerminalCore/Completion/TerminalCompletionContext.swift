/// The shell command line before the caret, split into the words of the
/// current simple command and the word being completed.
///
/// Splitting is quote- and escape-aware but deliberately not a shell parser:
/// `|`, `;` and `&` outside quotes start a new command, everything else
/// (subshells, here-docs, expansions) is treated as plain text.
public struct TerminalCompletionContext: Equatable, Sendable {
    /// Completed words of the current command, unquoted. `words[0]` is the
    /// command name when present.
    public var words: [String]
    /// The word being completed, unquoted and unescaped, up to the caret.
    public var word: String
    /// The word exactly as typed (quotes and backslashes included). Accepting
    /// a candidate replaces this many characters before the caret.
    public var rawWord: String
    /// The quote still open at the caret, if any.
    public var openQuote: Character?
    /// Everything before the caret.
    public var linePrefix: String

    /// The command name, or `nil` while the first word is still being typed.
    public var command: String? { words.first }
    /// Whether the caret is in the command-name position.
    public var isCommandPosition: Bool { words.isEmpty }

    public init(
        words: [String],
        word: String,
        rawWord: String,
        openQuote: Character?,
        linePrefix: String
    ) {
        self.words = words
        self.word = word
        self.rawWord = rawWord
        self.openQuote = openQuote
        self.linePrefix = linePrefix
    }

    /// Splits `buffer` at `caret`.
    ///
    /// - Parameters:
    ///   - buffer: The input text. It may be shorter than `caret` when the
    ///     terminal trimmed trailing spaces; the gap is read as spaces.
    ///   - caret: Caret position in characters from the buffer start.
    public static func parse(buffer: String, caret: Int) -> TerminalCompletionContext {
        var chars = Array(buffer)
        let caret = max(0, caret)
        if chars.count > caret {
            chars.removeSubrange(caret...)
        } else if chars.count < caret {
            chars.append(contentsOf: Array(repeating: " ", count: caret - chars.count))
        }

        var words: [String] = []
        var value = ""
        var raw = ""
        var inWord = false
        var quote: Character?
        var escaped = false

        func finishWord() {
            if inWord { words.append(value) }
            value = ""
            raw = ""
            inWord = false
        }

        for ch in chars {
            if escaped {
                value.append(ch)
                raw.append(ch)
                escaped = false
                continue
            }
            if let q = quote {
                raw.append(ch)
                if ch == q {
                    quote = nil
                } else if ch == "\\", q == "\"" {
                    escaped = true
                } else {
                    value.append(ch)
                }
                continue
            }
            switch ch {
            case "\\":
                inWord = true
                raw.append(ch)
                escaped = true
            case "'", "\"":
                inWord = true
                raw.append(ch)
                quote = ch
            case " ", "\t":
                finishWord()
            case "|", ";", "&":
                finishWord()
                words.removeAll()
            default:
                inWord = true
                value.append(ch)
                raw.append(ch)
            }
        }
        return TerminalCompletionContext(
            words: words,
            word: value,
            rawWord: raw,
            openQuote: quote,
            linePrefix: String(chars)
        )
    }
}

/// Shell quoting for text inserted by an accepted completion.
public enum TerminalCompletionEscaping {
    /// Escapes `text` for insertion at a position where `openQuote` is open
    /// (or no quote when `nil`).
    ///
    /// Unquoted text gets a backslash before every character outside
    /// `[letters digits _@%+=:,./~-]`; single quotes use the `'\''` idiom;
    /// double quotes escape `"`, `$`, backtick and backslash.
    public static func escape(_ text: String, openQuote: Character?) -> String {
        var out = ""
        switch openQuote {
        case "'":
            for ch in text {
                out += ch == "'" ? "'\\''" : String(ch)
            }
        case "\"":
            for ch in text {
                if "\"$`\\".contains(ch) { out.append("\\") }
                out.append(ch)
            }
        default:
            for ch in text {
                if ch.isLetter || ch.isNumber || "_@%+=:,./~-".contains(ch) {
                    out.append(ch)
                } else {
                    out.append("\\")
                    out.append(ch)
                }
            }
        }
        return out
    }
}

/// Which `git` subcommands complete to refs instead of (or besides) paths.
public enum TerminalCompletionGit {
    public enum RefCompletion: Equatable, Sendable {
        case none
        /// Only refs make sense (merge, rebase, switch, push, pull, branch -d).
        case refs
        /// Refs and files (`git checkout` takes either).
        case refsAndPaths
    }

    /// Decides from the completed words (`git`, subcommand, ...) and the word
    /// being typed whether branch names should be offered.
    public static func refCompletion(words: [String], word: String) -> RefCompletion {
        guard words.first == "git", !word.hasPrefix("-") else { return .none }
        // `git -C dir checkout`: skip global options that take a value.
        var index = 1
        while index < words.count, words[index].hasPrefix("-") {
            index += ["-C", "-c", "--git-dir", "--work-tree"].contains(words[index]) ? 2 : 1
        }
        guard index < words.count else { return .none }
        let sub = words[index]
        let rest = words[(index + 1)...]
        if rest.contains("--") { return .none }
        switch sub {
        case "checkout": return .refsAndPaths
        case "switch", "merge", "rebase", "push", "pull": return .refs
        case "branch":
            let deleting: Set<String> = ["-d", "-D", "-m", "-M", "--delete", "-c", "-C", "--move", "--copy"]
            return rest.contains(where: deleting.contains) ? .refs : .none
        default: return .none
        }
    }
}
