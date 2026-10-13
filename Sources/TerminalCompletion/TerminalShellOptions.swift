import BreeTerminalCore
import Darwin
import Foundation

/// Option and argument completion from the user's real shell, produced out
/// of band: a headless zsh/bash/fish run, or `<cmd> --help` as the fallback.
/// Never runs the typed command (only `--help` on a PATH-resolved,
/// non-denylisted executable). All work is synchronous; callers run it off
/// the main thread.
enum TerminalShellOptions {
    /// Non-history results below this count make the shell worth asking for
    /// non-dash words (subcommands, flags values), except in path-only cases.
    static let fewResultsThreshold = 3
    static let timeout: TimeInterval = 1.5
    static let helpTimeout: TimeInterval = 1.0
    static let limit = 50

    /// Whether the shell should be asked for `context` given what the other
    /// providers already found.
    static func shouldRun(context: TerminalCompletionContext, otherResults: Int) -> Bool {
        guard !context.isCommandPosition, !context.word.contains("="), !context.word.contains("/") else { return false }
        if context.word.hasPrefix("-") { return true }
        let pathOnly = ["cd", "pushd", "popd", "rmdir"].contains(context.command ?? "")
        return !pathOnly && otherResults < fewResultsThreshold
    }

    static func candidates(
        for context: TerminalCompletionContext,
        cwd: String,
        isCancelled: @escaping () -> Bool
    ) -> [TerminalCompletionCandidate] {
        guard let command = context.command else { return [] }
        let shell = userShell().flatMap { Kind(path: $0) }
        let subpath = context.words.dropFirst().filter { !$0.hasPrefix("-") }.prefix(3).joined(separator: " ")
        let key = Cache.Key(shell: shell?.rawValue ?? "none", command: command, subpath: subpath)
        let word = context.word

        let options: [TerminalShellOption]
        if let cached = Cache.shared.lookup(key, word: word) {
            options = cached
        } else {
            var found = shell.map { capture($0, context: context, cwd: cwd, isCancelled: isCancelled) } ?? []
            if found.isEmpty, !isCancelled() { found = helpOptions(command: command, cwd: cwd, isCancelled: isCancelled) }
            if isCancelled() { return [] }
            Cache.shared.store(key, word: word, options: found)
            options = found
        }
        return options
            .filter { $0.text.hasPrefix(word) && $0.text != word }
            .prefix(limit)
            .map {
                TerminalCompletionCandidate(
                    kind: $0.text.hasPrefix("-") ? .option : .command,
                    title: $0.text,
                    insertion: $0.text,
                    detail: $0.detail
                )
            }
    }

    // MARK: Shell detection

    enum Kind: String {
        case zsh, bash, fish
        init?(path: String) { self.init(rawValue: (path as NSString).lastPathComponent) }
    }

    /// `$SHELL` of the app environment (launchd passes the login shell),
    /// else the passwd entry. ponytail: the surface's own environment is not
    /// plumbed through; add when a per-surface shell override matters.
    static func userShell() -> String? {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty { return shell }
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell { return String(cString: shell) }
        return nil
    }

    // MARK: Capture per shell

    private static func capture(
        _ shell: Kind,
        context: TerminalCompletionContext,
        cwd: String,
        isCancelled: @escaping () -> Bool
    ) -> [TerminalShellOption] {
        // Control characters would execute or edit the line in the zsh pty.
        let linePrefix = String(context.linePrefix.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F })
        switch shell {
        case .zsh:
            return zshCapture(buffer: linePrefix, cwd: cwd, isCancelled: isCancelled)
        case .bash:
            guard let bash = userShell().flatMap({ FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }) else { return [] }
            // The current word is last, empty when the line ends in a space.
            let words = context.words + [context.word]
            let output = TerminalShellProcess.run(
                executable: bash,
                arguments: ["--noprofile", "--norc", "-c", bashScript, "bree-bash", linePrefix] + words,
                environment: environment(),
                cwd: cwd,
                timeout: timeout,
                isCancelled: isCancelled
            )
            return output.map(TerminalCompletionShellParsers.parseTabSeparated) ?? []
        case .fish:
            guard let fish = userShell().flatMap({ FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }) else { return [] }
            let output = TerminalShellProcess.run(
                executable: fish,
                arguments: ["--no-config", "-c", "complete -C $argv[1]", linePrefix],
                environment: environment(),
                cwd: cwd,
                timeout: timeout,
                isCancelled: isCancelled
            )
            return output.map(TerminalCompletionShellParsers.parseTabSeparated) ?? []
        }
    }

    private static func zshCapture(buffer: String, cwd: String, isCancelled: @escaping () -> Bool) -> [TerminalShellOption] {
        let fileManager = FileManager.default
        let home = NSHomeDirectory()
        guard let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return [] }
        let directory = support.appendingPathComponent("bree/completion", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Versioned name: a new script version never meets an old file.
        let script = directory.appendingPathComponent("capture-v1.zsh")
        if (try? String(contentsOf: script, encoding: .utf8)) != zshHelperScript {
            do { try zshHelperScript.write(to: script, atomically: true, encoding: .utf8) } catch { return [] }
        }

        var fpath = ["/opt/homebrew/share/zsh/site-functions", "/usr/local/share/zsh/site-functions"]
        fpath += (ProcessInfo.processInfo.environment["FPATH"] ?? "").split(separator: ":").map(String.init)
        fpath += ["\(home)/.zfunc", "\(home)/.zsh/completions"]
        if let zshrc = try? String(contentsOfFile: home + "/.zshrc", encoding: .utf8) {
            fpath += TerminalCompletionShellParsers.extraFpath(zshrc: zshrc, home: home)
        }
        var seen = Set<String>()
        fpath = fpath.filter { fileManager.fileExists(atPath: $0) && seen.insert($0).inserted }
        // compinit -C trusts the dump, so a changed fpath needs its own dump.
        let dump = directory.appendingPathComponent("zcompdump-\(stableHash(fpath.joined(separator: ":")))")
        let out = directory.appendingPathComponent("out-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: out) }

        var env = environment()
        env["BREE_SCRIPT"] = script.path
        env["BREE_OUT"] = out.path
        env["BREE_DUMP"] = dump.path
        env["BREE_FPATH"] = fpath.joined(separator: ":")
        env["BREE_BUF"] = buffer
        guard TerminalShellProcess.run(
            executable: "/bin/zsh",
            arguments: ["-f", script.path],
            environment: env,
            cwd: cwd,
            timeout: timeout,
            isCancelled: isCancelled
        ) != nil else { return [] }
        return TerminalCompletionShellParsers.parseTabSeparated(
            (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        )
    }

    private static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return String(hash, radix: 16)
    }

    // MARK: --help fallback

    private static func helpOptions(
        command: String,
        cwd: String,
        isCancelled: @escaping () -> Bool
    ) -> [TerminalShellOption] {
        guard !TerminalCompletionShellParsers.isHelpDenied(command) else { return [] }
        let env = environment()
        guard let executable = (env["PATH"] ?? "").split(separator: ":")
            .map({ "\($0)/\(command)" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return [] }
        var helpEnv = env
        helpEnv["PAGER"] = "cat"
        helpEnv["NO_COLOR"] = "1"
        helpEnv["TERM"] = "dumb"
        guard let output = TerminalShellProcess.run(
            executable: executable,
            arguments: ["--help"],
            environment: helpEnv,
            cwd: cwd,
            timeout: helpTimeout,
            isCancelled: isCancelled
        ) else { return [] }
        return TerminalCompletionShellParsers.parseHelp(output)
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = TerminalCompletionCache.searchPath()
        return env
    }

    // MARK: Cache

    /// 5-minute LRU of shell results per (shell, command, subcommand path).
    /// A lookup for a longer word reuses the entry of any shorter prefix and
    /// filters it, so typing `--ver` after `--v` costs no process.
    final class Cache: @unchecked Sendable {
        struct Key: Hashable { let shell: String, command: String, subpath: String }
        private struct Entry { var key: Key; var word: String; var at: Date; var options: [TerminalShellOption] }

        static let shared = Cache()
        static let ttl: TimeInterval = 300
        static let capacity = 200

        private let lock = NSLock()
        private var entries: [Entry] = []  // least recently used first

        func lookup(_ key: Key, word: String) -> [TerminalShellOption]? {
            lock.lock()
            defer { lock.unlock() }
            let now = Date()
            entries.removeAll { now.timeIntervalSince($0.at) > Self.ttl }
            // Longest cached prefix of `word` wins; its results are a superset.
            guard let index = entries.indices
                .filter({ entries[$0].key == key && word.hasPrefix(entries[$0].word) })
                .max(by: { entries[$0].word.count < entries[$1].word.count }) else { return nil }
            let entry = entries.remove(at: index)
            entries.append(entry)
            return entry.options
        }

        func store(_ key: Key, word: String, options: [TerminalShellOption]) {
            lock.lock()
            defer { lock.unlock() }
            entries.removeAll { $0.key == key && $0.word == word }
            entries.append(Entry(key: key, word: word, at: Date(), options: options))
            if entries.count > Self.capacity { entries.removeFirst(entries.count - Self.capacity) }
        }
    }

    // MARK: Scripts

    private static let bashScript = #"""
    for f in /opt/homebrew/etc/profile.d/bash_completion.sh /usr/local/etc/profile.d/bash_completion.sh; do
      [ -r "$f" ] && . "$f" && break
    done >/dev/null 2>&1
    line=$1; shift
    COMP_WORDS=("$@"); COMP_CWORD=$(($# - 1)); COMP_LINE=$line; COMP_POINT=${#line}
    cmd=${COMP_WORDS[0]}; cur=${COMP_WORDS[COMP_CWORD]}; prev=
    [ "$COMP_CWORD" -gt 0 ] && prev=${COMP_WORDS[COMP_CWORD-1]}
    type _completion_loader >/dev/null 2>&1 && _completion_loader "$cmd" >/dev/null 2>&1
    spec=$(complete -p -- "$cmd" 2>/dev/null)
    case $spec in
      *" -F "*)
        fn=${spec#* -F }; fn=${fn%% *}
        COMPREPLY=()
        "$fn" "$cmd" "$cur" "$prev" >/dev/null 2>&1
        printf '%s\n' "${COMPREPLY[@]}" ;;
    esac
    """#

    private static let zshHelperScript = #"""
    # Headless compsys capture. The zpty technique (run an interactive zsh on a
    # pty, bind Tab to a completion widget, wrap compadd) comes from
    # zsh-capture-completion by Vincent Breitmoser (MIT),
    # https://github.com/Valodim/zsh-capture-completion
    # Inputs come as data through BREE_* environment variables; the buffer is
    # never interpolated into code. Results are appended to $BREE_OUT as
    # `match<TAB>description` lines.
    if [[ -n $BREE_INNER ]]; then
      fpath=(${(s.:.)BREE_FPATH} $fpath)
      autoload -Uz compinit
      compinit -C -d "$BREE_DUMP"
      zstyle ':completion:*' list-prompt ''
      zstyle ':completion:*' menu no
      zstyle ':completion:*' verbose yes
      zstyle ':completion:*' group-name ''
      PS1='' RPS1=''
      compadd() {
        emulate -L zsh
        setopt extendedglob
        local -a __bree_ms __bree_disp
        local -A __bree_desc
        local __bree_i __bree_k
        # Find -O/-A/-D (internal calls) and the -d display array, also in clusters like -ld.
        local __bree_n=1 __bree_a __bree_c __bree_internal=
        local __bree_dn=
        while (( __bree_n <= $# )); do
          __bree_a=${@[__bree_n]}
          [[ $__bree_a == (-|--) ]] && break
          if [[ $__bree_a == -[a-zA-Z0-9]* ]]; then
            for __bree_c in ${(s::)__bree_a#-}; do
              if [[ JVXxPSpsiIWFMOADdEorR == *$__bree_c* ]]; then
                case $__bree_c in
                  d) __bree_dn=${@[__bree_n+1]} ;;
                  O|A|D) __bree_internal=1 ;;
                esac
                (( __bree_n++ ))
                break
              fi
            done
          fi
          (( __bree_n++ ))
        done
        if [[ -n $__bree_internal ]]; then builtin compadd "$@"; return; fi
        builtin compadd -O __bree_ms "$@"
        [[ -n $__bree_dn ]] && __bree_disp=("${(@P)__bree_dn}")
        for __bree_i in "${__bree_disp[@]}"; do
          if [[ $__bree_i == *' -- '* ]]; then
            __bree_k=${${__bree_i%% -- *}%%[[:space:]]##}
            __bree_desc[$__bree_k]=${__bree_i#* -- }
          fi
        done
        for __bree_i in "${__bree_ms[@]}"; do
          print -r -- "$__bree_i"$'\t'"${__bree_desc[${__bree_i%=}]-}" >>"$BREE_OUT"
        done
        builtin compadd "$@"
      }
      _bree_done() { print BREE_DONE }
      _bree_widget() { comppostfuncs=(_bree_done); _main_complete }
      zle -C bree-capture complete-word _bree_widget
      bindkey '^I' bree-capture
      print BREE_READY
      return 0
    fi
    zmodload zsh/zpty || exit 1
    export BREE_INNER=1 TERM=xterm-256color
    : >"$BREE_OUT"
    zpty z zsh -f -i
    zpty -w z "source ${(q)BREE_SCRIPT}"
    zpty -r z __bree_b '*BREE_READY*' || exit 1
    zpty -w -n z "${BREE_BUF}"$'\t'
    zpty -r z __bree_b '*BREE_DONE*'
    zpty -d z
    cat "$BREE_OUT"
    """#
}

/// Spawns a process in its own process group and reads its stdout, killing
/// the whole group at the deadline or on cancellation.
enum TerminalShellProcess {
    /// - Returns: stdout, or `nil` on spawn failure, timeout, cancellation or
    ///   more than 1 MiB of output. The exit status is ignored (`--help`
    ///   pages often exit non-zero).
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        cwd: String,
        timeout: TimeInterval,
        isCancelled: () -> Bool
    ) -> String? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addclose(&actions, fds[0])
        posix_spawn_file_actions_addclose(&actions, fds[1])
        posix_spawn_file_actions_addchdir_np(&actions, cwd)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(fds[1])
        guard spawned == 0 else {
            close(fds[0])
            return nil
        }

        let deadline = Date().addingTimeInterval(timeout)
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 8192)
        var descriptor = pollfd(fd: fds[0], events: Int16(POLLIN), revents: 0)
        var finished = false
        loop: while !isCancelled(), Date() < deadline, data.count <= 1 << 20 {
            let ready = poll(&descriptor, 1, 50)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }
            let count = read(fds[0], &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk[0..<count])
            } else if count == 0 {
                finished = true
                break loop
            } else if errno != EINTR {
                break
            }
        }
        close(fds[0])
        if !finished { killpg(pid, SIGKILL) }
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        return finished ? String(decoding: data, as: UTF8.self) : nil
    }
}
