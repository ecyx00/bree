import Testing
@testable import BreeTerminalCore

@Suite("Terminal completion")
struct TerminalCompletionTests {
    private func parse(_ buffer: String, caret: Int? = nil) -> TerminalCompletionContext {
        TerminalCompletionContext.parse(buffer: buffer, caret: caret ?? buffer.count)
    }

    @Test("Splits words and the current word")
    func plainSplit() {
        let context = parse("git checkout ma")
        #expect(context.words == ["git", "checkout"])
        #expect(context.word == "ma")
        #expect(context.rawWord == "ma")
        #expect(context.command == "git")
        #expect(!context.isCommandPosition)
    }

    @Test("Command position and trailing space")
    func commandPosition() {
        #expect(parse("gi").isCommandPosition)
        let trailing = parse("ls ")
        #expect(trailing.words == ["ls"])
        #expect(trailing.word == "")
    }

    @Test("Caret inside a word ignores the rest of the line")
    func caretMidWord() {
        let context = parse("cd Documents/foo bar", caret: 6)
        #expect(context.words == ["cd"])
        #expect(context.word == "Doc")
    }

    @Test("Escaped space, double and single quotes unescape for directory resolution")
    func quotedDirectoryWords() {
        let escaped = parse("cd Desktop/Muhasebe\\ v2/")
        #expect(escaped.words == ["cd"])
        #expect(escaped.word == "Desktop/Muhasebe v2/")
        #expect(escaped.rawWord == "Desktop/Muhasebe\\ v2/")

        let double = parse("cd \"My Dir/\"")
        #expect(double.word == "My Dir/")
        #expect(double.openQuote == nil)

        let single = parse("cd 'a b'/")
        #expect(single.word == "a b/")
        #expect(single.rawWord == "'a b'/")

        let open = parse("cd \"My Di")
        #expect(open.word == "My Di")
        #expect(open.openQuote == "\"")
    }

    @Test("Insertion escapes spaces again")
    func insertionEscapesSpaces() {
        #expect(TerminalCompletionEscaping.escape("Desktop/Muhasebe v2/", openQuote: nil) == "Desktop/Muhasebe\\ v2/")
    }

    @Test("Caret beyond a trimmed buffer reads as spaces")
    func trimmedBuffer() {
        let context = TerminalCompletionContext.parse(buffer: "git checkout", caret: 13)
        #expect(context.words == ["git", "checkout"])
        #expect(context.word == "")
    }

    @Test("Quotes keep spaces in one word and report the open quote")
    func quotes() {
        let closed = parse("cd 'my dir' sub")
        #expect(closed.words == ["cd", "my dir"])
        #expect(closed.word == "sub")

        let open = parse("cd \"my di")
        #expect(open.word == "my di")
        #expect(open.rawWord == "\"my di")
        #expect(open.openQuote == "\"")

        let single = parse("cat 'a b")
        #expect(single.openQuote == "'")
    }

    @Test("Backslash escapes a space")
    func escapes() {
        let context = parse("cd my\\ di")
        #expect(context.words == ["cd"])
        #expect(context.word == "my di")
        #expect(context.rawWord == "my\\ di")
        #expect(context.openQuote == nil)
    }

    @Test("Pipes and separators start a new command")
    func separators() {
        let context = parse("ls | grep fo")
        #expect(context.words == ["grep"])
        #expect(context.word == "fo")
        #expect(parse("make && gi").isCommandPosition)
        #expect(parse("echo 'a|b' x").words == ["echo", "a|b"])
    }

    @Test("Escaping unquoted text")
    func escapeUnquoted() {
        #expect(TerminalCompletionEscaping.escape("my dir (1)/", openQuote: nil) == "my\\ dir\\ \\(1\\)/")
        #expect(TerminalCompletionEscaping.escape("~/src/a-b_c.txt", openQuote: nil) == "~/src/a-b_c.txt")
        #expect(TerminalCompletionEscaping.escape("a$b", openQuote: nil) == "a\\$b")
        #expect(TerminalCompletionEscaping.escape("#x", openQuote: nil) == "\\#x")
    }

    @Test("Escaping inside quotes")
    func escapeQuoted() {
        #expect(TerminalCompletionEscaping.escape("it's", openQuote: "'") == "it'\\''s")
        #expect(TerminalCompletionEscaping.escape("a\"b$c`d\\e f", openQuote: "\"") == "a\\\"b\\$c\\`d\\\\e f")
    }

    @Test("Git ref completion triggers")
    func gitTrigger() {
        func kind(_ line: String) -> TerminalCompletionGit.RefCompletion {
            let context = parse(line)
            return TerminalCompletionGit.refCompletion(words: context.words, word: context.word)
        }
        #expect(kind("git checkout ") == .refsAndPaths)
        #expect(kind("git switch ma") == .refs)
        #expect(kind("git merge fe") == .refs)
        #expect(kind("git rebase ") == .refs)
        #expect(kind("git push origin ma") == .refs)
        #expect(kind("git pull ") == .refs)
        #expect(kind("git branch -d fe") == .refs)
        #expect(kind("git branch fe") == .none)
        #expect(kind("git -C repo checkout ") == .refsAndPaths)
        #expect(kind("git checkout -- fi") == .none)
        #expect(kind("git checkout --f") == .none)
        #expect(kind("git status ") == .none)
        #expect(kind("ls ") == .none)
    }

    @Test("zsh history, extended and plain")
    func zshHistory() {
        let text = """
        : 1700000000:0;git status
        : 1700000001:0;echo one \\
        two
        : 1700000002:0;ls -la
        plain command
        """
        #expect(TerminalCompletionHistoryParsers.parseZsh(text) == ["git status", "ls -la", "plain command"])
    }

    @Test("bash history skips timestamps")
    func bashHistory() {
        let text = "#1700000000\ngit status\n#1700000001\nls\n\n"
        #expect(TerminalCompletionHistoryParsers.parseBash(text) == ["git status", "ls"])
    }

    @Test("fish history")
    func fishHistory() {
        let text = """
        - cmd: git status
          when: 1700000000
        - cmd: echo a\\nb
          when: 1700000001
        - cmd: grep a\\\\b
          when: 1700000002
          paths:
            - x
        """
        #expect(TerminalCompletionHistoryParsers.parseFish(text) == ["git status", "grep a\\b"])
    }

    @Test("recent is newest first, deduped and limited")
    func recent() {
        let oldestFirst = ["a", "b", "a", "c"]
        #expect(TerminalCompletionHistoryParsers.recent(oldestFirst, limit: 10) == ["c", "a", "b"])
        #expect(TerminalCompletionHistoryParsers.recent(oldestFirst, limit: 2) == ["c", "a"])
    }
}

@Suite("Terminal completion shell parsers")
struct TerminalCompletionShellParserTests {
    private func parse(_ buffer: String, caret: Int? = nil) -> TerminalCompletionContext {
        TerminalCompletionContext.parse(buffer: buffer, caret: caret ?? buffer.count)
    }

    typealias Parsers = TerminalCompletionShellParsers

    @Test("--help lines: short and long forms, values, descriptions")
    func helpLines() {
        let help = """
        Usage: tool [options]

          -h, --help               Show this help
          -n, --lines=NUM          Print NUM lines
              --color[=WHEN]       Colorize output
          -o FILE                  Write to FILE
          --[no-]verbose           Toggle noise
        -x  not indented, ignored
          --dry-run
        Some prose line - with a dash
        """
        let options = Parsers.parseHelp(help)
        #expect(options.map(\.text) == ["-h", "--help", "-n", "--lines=", "--color", "-o", "--dry-run"])
        #expect(options.first { $0.text == "--help" }?.detail == "Show this help")
        #expect(options.first { $0.text == "--lines=" }?.detail == "Print NUM lines")
        #expect(options.first { $0.text == "--dry-run" }?.detail == nil)
    }

    @Test("fish output: candidate and optional description")
    func fishOutput() {
        let options = Parsers.parseTabSeparated("--amend\tAmend the last commit\n--all\n--amend\tduplicate\n\n")
        #expect(options == [
            TerminalShellOption(text: "--amend", detail: "Amend the last commit"),
            TerminalShellOption(text: "--all", detail: nil),
        ])
    }

    @Test("zsh capture output: same tab format, CRLF tolerated")
    func zshCapture() {
        let options = Parsers.parseTabSeparated("checkout\tswitch branches\r\ncherry-pick\t\r\n")
        #expect(options == [
            TerminalShellOption(text: "checkout", detail: "switch branches"),
            TerminalShellOption(text: "cherry-pick", detail: nil),
        ])
    }

    @Test("--help denylist")
    func denylist() {
        for name in ["rm", "dd", "sudo", "ssh", "git", "vim", "./local", "/bin/rm"] {
            #expect(Parsers.isHelpDenied(name), "\(name)")
        }
        #expect(!Parsers.isHelpDenied("curl"))
        #expect(!Parsers.isHelpDenied("ls"))
    }

    @Test("zshrc fpath scan reads literal paths only")
    func zshrcFpath() {
        let zshrc = """
        # fpath=(/ignored)
        fpath=(~/.zfunc $HOME/comp "/opt/extra" $fpath)  # trailing
        fpath+=${ZDOTDIR}/x
        export OTHER=/not/fpath
        """
        #expect(Parsers.extraFpath(zshrc: zshrc, home: "/h") == ["/h/.zfunc", "/h/comp", "/opt/extra"])
    }

    @Test("A directory accepted as dir/ (no space) keeps the whole path as the word")
    func directoryAcceptWord() {
        let escaped = TerminalCompletionEscaping.escape("Desktop/My Dir/", openQuote: nil)
        #expect(escaped == "Desktop/My\\ Dir/")
        let context = parse("cd " + escaped)
        #expect(context.words == ["cd"])
        #expect(context.word == "Desktop/My Dir/")
        #expect(context.rawWord == escaped)
    }

    @Test("Empty word after a space is an argument, not the command position")
    func emptyWordAfterCommand() {
        for buffer in ["cd ", "cd  ", "pushd ", "ls -l "] {
            let context = parse(buffer)
            #expect(!context.isCommandPosition, "\(buffer)")
            #expect(context.word == "", "\(buffer)")
        }
        #expect(parse("cd").isCommandPosition)
        #expect(parse("ls | cd ").command == "cd")
    }
}
