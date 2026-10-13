import Darwin
import Foundation

enum WorkspaceInitialCommandLoginShell {
    /// Resolves the user's login shell and wraps an externally supplied workspace command.
    ///
    /// Ghostty otherwise launches string commands through Bash with `--noprofile --norc`,
    /// so the user's profile cannot contribute tools such as Homebrew-installed agents.
    /// Ghostty prepends `exec -l`, so the returned command starts with the quoted shell path.
    static func wrap(_ command: String) -> String {
        let databaseShell: String?
        if let record = getpwuid(getuid()),
           let shell = record.pointee.pw_shell {
            let copiedShell = String(cString: shell)
            databaseShell = copiedShell.isEmpty ? nil : copiedShell
        } else {
            databaseShell = nil
        }

        let userShell = databaseShell
            ?? ProcessInfo.processInfo.environment["SHELL"]
            ?? "/bin/zsh"
        return wrap(command, userShell: userShell)
    }

    /// Wraps a command in a supported login shell while preserving the command verbatim.
    ///
    /// Login profiles can prepend other tool directories (Homebrew's `shellenv` puts
    /// `/opt/homebrew/bin` first) ahead of the per-surface shim directory that bree
    /// seeds into the spawned PATH, which would route `claude`/`codex` around bree's
    /// wrapper hooks. The payload therefore re-prepends the shim directory after
    /// profiles run; a duplicate PATH entry is harmless and matches what interactive
    /// shell integration already produces. The directory can sit in a shared
    /// temporary directory, so both the root and its ancestors are checked before
    /// any PATH change. The shared agent root also supports Claude-disabled panes.
    static func wrap(_ command: String, userShell: String?) -> String {
        var shellPath: String
        if let userShell, userShell.hasPrefix("/") {
            shellPath = userShell
        } else {
            shellPath = "/bin/zsh"
        }
        let payload: String
        let check = shellSingleQuoted(shimRootCheck)

        switch (shellPath as NSString).lastPathComponent {
        case "fish":
            payload = """
            set -l _bree_previous_shim ""
            for _bree_candidate_shim in "$BREE_CLAUDE_WRAPPER_SHIM_ROOT" "$BREE_AGENT_COMMAND_SHIM_ROOT"
                if test -n "$_bree_candidate_shim"; and test "$_bree_candidate_shim" != "$_bree_previous_shim"; and /bin/sh -c \(check) bree "$_bree_candidate_shim"
                    set -gx PATH "$_bree_candidate_shim" $PATH
                    set _bree_previous_shim "$_bree_candidate_shim"
                end
            end
            set -e _bree_previous_shim _bree_candidate_shim
            \(command)
            """
        case "zsh", "bash", "sh", "ksh", "dash":
            payload = """
            \(posixShimRootPrepend)
            \(command)
            """
        default:
            shellPath = "/bin/zsh"
            payload = """
            \(posixShimRootPrepend)
            \(command)
            """
        }

        return "\(shellSingleQuoted(shellPath)) -lc \(shellSingleQuoted(payload))"
    }

    private static var posixShimRootPrepend: String {
        """
        _bree_previous_shim=''
        for _bree_candidate_shim in "${BREE_CLAUDE_WRAPPER_SHIM_ROOT:-}" "${BREE_AGENT_COMMAND_SHIM_ROOT:-}"; do
            if [ -n "$_bree_candidate_shim" ] && [ "$_bree_candidate_shim" != "$_bree_previous_shim" ] && /bin/sh -c \(shellSingleQuoted(shimRootCheck)) bree "$_bree_candidate_shim"; then
                PATH="$_bree_candidate_shim${PATH:+:$PATH}"; export PATH
                _bree_previous_shim=$_bree_candidate_shim
            fi
        done
        unset _bree_previous_shim _bree_candidate_shim
        """
    }

    /// The same fixed POSIX predicate runs from every supported login shell;
    /// the candidate is argv data and never interpolated into executable code.
    private static let shimRootCheck = #"""
    _bree_root=$1
    case "$_bree_root" in /*) ;; *) exit 1 ;; esac
    while [ "$_bree_root" != / ] && [ "${_bree_root%/}" != "$_bree_root" ]; do _bree_root=${_bree_root%/}; done
    [ -d "$_bree_root" ] && [ ! -L "$_bree_root" ] || exit 1
    _bree_uid=$(/usr/bin/id -u) || exit 1
    _bree_meta() {
        _bree_info=$(/usr/bin/stat -f '%HT:%u:%Mp%Lp' -- "$1" 2>/dev/null) || _bree_info=$(/usr/bin/stat -c '%F:%u:%a' -- "$1" 2>/dev/null) || return 1
        _bree_kind=${_bree_info%%:*}
        _bree_info=${_bree_info#*:}
        _bree_owner=${_bree_info%%:*}
        _bree_mode=${_bree_info#*:}
        case "$_bree_mode" in ''|*[!0-7]*) return 1 ;; esac
        _bree_mode=$((0$_bree_mode))
    }
    _bree_chain_safe() {
        _bree_current=$1
        while :; do
            _bree_meta "$_bree_current" || return 1
            [ "$_bree_owner" = "$_bree_uid" ] || [ "$_bree_owner" = 0 ] || return 1
            case "$_bree_kind" in
                Directory|directory) [ $((_bree_mode & 0022)) -eq 0 ] || [ $((_bree_mode & 01000)) -ne 0 ] || return 1 ;;
                'Symbolic Link'|'symbolic link') ;;
                *) return 1 ;;
            esac
            [ "$_bree_current" = / ] && return 0
            _bree_current=${_bree_current%/*}
            [ -n "$_bree_current" ] || _bree_current=/
        done
    }
    _bree_meta "$_bree_root" || exit 1
    [ "$_bree_owner" = "$_bree_uid" ] && [ $((_bree_mode & 0022)) -eq 0 ] || exit 1
    _bree_chain_safe "$_bree_root" || exit 1
    _bree_resolved=$(CDPATH='' command cd -P "$_bree_root" >/dev/null && /bin/pwd -P) || exit 1
    _bree_chain_safe "$_bree_resolved"
    """#

    private static func shellSingleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
