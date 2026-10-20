# bree shell integration for zsh
# Injected automatically — do not source manually

# Socket sends exec a unix-socket-capable client in a detached child. The
# historical zsocket fast path (zmodload zsh/net/unix) never activated because
# that module does not exist (zsocket lives in zsh/net/socket). Enabling it
# would also lose response-based ordering between connections and introduce an
# unbounded blocked child. A future fast path still needs one connection per
# batch plus bounded response reads.

typeset -g _BREE_HAS_ZSH_JOBSTATES=0
if zmodload zsh/parameter 2>/dev/null && (( ${+jobstates} )); then
    _BREE_HAS_ZSH_JOBSTATES=1
fi

# Prefer zsh/zselect for the poll-loop sleeps in the git-HEAD
# watchers (no fork, vs ~1 fork+exec of /bin/sleep per second per pane).
# Falls back to /bin/sleep if the module is unavailable.
typeset -g _BREE_HAS_ZSELECT=0
if zmodload zsh/zselect 2>/dev/null; then
    _BREE_HAS_ZSELECT=1
fi

# Fork-free sleep.  Argument is in centiseconds (zselect's -t unit), so a
# whole-second wait is `_bree_sleep_cs 100`.  zselect with only -t and no fds
# returns status 1 on timeout, so call it then return 0 explicitly rather than
# falling through to the /bin/sleep fallback (which would double the wait).
_bree_sleep_cs() {
    if (( _BREE_HAS_ZSELECT )); then
        # Timeout is zselect's normal status 1. Consume it before returning so
        # callers with ERR_RETURN/ERR_EXIT enabled do not abort the watcher.
        zselect -t "$1" || :
        return 0
    fi
    sleep "$(( $1 / 100.0 ))"
}

_bree_zsh_job_table_saturated() {
    (( _BREE_HAS_ZSH_JOBSTATES )) || return 1

    local limit="${BREE_ZSH_JOB_TABLE_SOFT_LIMIT:-900}"
    case "$limit" in
        ''|*[!0-9]*) limit=900 ;;
    esac
    (( limit > 0 )) || limit=900

    local job_count=${#jobstates}
    (( job_count >= limit ))
}

_bree_restore_status() {
    builtin return "$1"
}

# BSD nc at /usr/bin/nc is preferred: it always supports -U, it waits for the
# server to process the line and close (which preserves send order across a
# batched child), and -w bounds its lifetime. PATH `nc` cannot be trusted first:
# GNU netcat (e.g. Homebrew in /usr/local/bin) lacks -U and fails silently,
# which dropped every hook message (report_tty, ports_kick, report_shell_state)
# on machines where it shadows the system nc. The capability envelope keeps
# the detached client authorized even after launchd or tmux reparents it.
_bree_write_socket_payload() {
    local payload="$1"
    case "${BREE_SOCKET_CAPABILITY:-}" in
        ""|*[[:space:]]*)
            print -r -- "$payload"
            ;;
        *)
            print -r -- "_bree_capability_v1 $BREE_SOCKET_CAPABILITY $payload"
            ;;
    esac
}

_bree_send() {
    local payload="$1"
    if [[ -x /usr/bin/nc ]]; then
        # Apple's nc defines -N as `num_probes` (it is not OpenBSD's no-arg
        # shutdown-after-EOF flag), so the -N form fails option parsing; use
        # the bounded -w form directly. nc waits for the server to process the
        # line and close, preserving order in a batched child.
        _bree_write_socket_payload "$payload" | /usr/bin/nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1 || true
        return 0
    fi
    if command -v ncat >/dev/null 2>&1; then
        _bree_write_socket_payload "$payload" | ncat -w 1 -U "$BREE_SOCKET_PATH" --send-only
    elif command -v socat >/dev/null 2>&1; then
        _bree_write_socket_payload "$payload" | socat -T 1 - "UNIX-CONNECT:$BREE_SOCKET_PATH" >/dev/null 2>&1
    elif command -v nc >/dev/null 2>&1; then
        if _bree_write_socket_payload "$payload" | nc -N -U "$BREE_SOCKET_PATH" >/dev/null 2>&1; then
            :
        else
            _bree_write_socket_payload "$payload" | nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1 || true
        fi
    fi
}

# Fire-and-forget send, always detached from the interactive shell: the
# client's connect and response wait must never run in the foreground, or a
# wedged bree listener (hung app, full backlog, post-wake socket) blocks every
# precmd/preexec hook and freezes the user's prompt. Each child self-bounds
# via its client timeout (-w 1 / -T 1), so a wedged listener cannot
# accumulate children beyond roughly one second's worth of sends.
# Accepts multiple payloads: they are sent sequentially inside ONE child, so
# callers with an ordering dependency between two messages (report_tty before
# ports_kick) batch them instead of racing two independent children.
# Returns nonzero when the payload was dropped (job-table saturation) so
# callers with edge-triggered latches can leave them unset and retry.
_bree_send_bg() {
    _bree_zsh_job_table_saturated && return 1
    {
        local _bree_msg
        for _bree_msg in "$@"; do
            _bree_send "$_bree_msg"
        done
    } >/dev/null 2>&1 &!
    return 0
}

_bree_socket_is_unix() {
    [[ -n "$BREE_SOCKET_PATH" && -S "$BREE_SOCKET_PATH" ]]
}

_bree_relay_cli_path() {
    if [[ -n "${BREE_BUNDLED_CLI_PATH:-}" && -x "${BREE_BUNDLED_CLI_PATH}" ]]; then
        print -r -- "${BREE_BUNDLED_CLI_PATH}"
        return 0
    fi
    command -v bree 2>/dev/null
}

_bree_socket_uses_remote_relay() {
    [[ -n "$BREE_SOCKET_PATH" ]] || return 1
    [[ "$BREE_SOCKET_PATH" == /* ]] && return 1
    [[ "$BREE_SOCKET_PATH" == *:* ]] || return 1
    [[ -n "$(_bree_relay_cli_path)" ]]
}

_bree_has_port_scan_transport() {
    _bree_socket_is_unix && return 0
    _bree_socket_uses_remote_relay
}

_bree_json_escape() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    value="${value//$'\n'/\\n}"
    value="${value//$'\r'/\\r}"
    value="${value//$'\t'/\\t}"
    print -r -- "$value"
}

_bree_relay_rpc_bg() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    _bree_zsh_job_table_saturated && return 1
    _bree_socket_uses_remote_relay || return 1
    relay_cli="$(_bree_relay_cli_path)" || return 1
    { "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 || true } >/dev/null 2>&1 &!
}

_bree_relay_rpc() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    local response=""
    _bree_socket_uses_remote_relay || return 1
    # Relay `bree rpc` exits nonzero on server error. The real remote CLI prints
    # only the JSON result payload on success, while some test stubs return the
    # full `{"ok":...}` envelope. Retry only on explicit `ok:false`.
    relay_cli="$(_bree_relay_cli_path)" || return 1
    response="$("$relay_cli" rpc "$method" "$params" 2>/dev/null)" || return 1
    response="${response//$'\n'/}"
    response="${response//$'\r'/}"
    [[ "$response" == *'"ok":false'* || "$response" == *'"ok": false'* ]] && return 1
    return 0
}

_bree_relay_workspace_id() {
    if [[ -n "$BREE_WORKSPACE_ID" ]]; then
        print -r -- "$BREE_WORKSPACE_ID"
        return 0
    fi
    [[ -n "$BREE_TAB_ID" ]] || return 1
    print -r -- "$BREE_TAB_ID"
}

_bree_report_tty_via_relay() {
    _bree_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1
    [[ -n "$_BREE_TTY_NAME" ]] || return 1
    [[ -n "$BREE_TERMINAL_LIFECYCLE_ID" && -n "$BREE_SSH_ATTEMPT_ID" ]] || return 1

    local tty_name_json params
    tty_name_json="$(_bree_json_escape "$_BREE_TTY_NAME")"
    params="{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\",\"terminal_lifecycle_id\":\"$BREE_TERMINAL_LIFECYCLE_ID\",\"attempt_id\":\"$BREE_SSH_ATTEMPT_ID\""
    if [[ -n "$BREE_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    params+="}"
    _bree_relay_rpc "surface.report_tty" "$params"
}

_bree_report_pwd_via_relay() {
    local pwd="$1"
    _bree_socket_uses_remote_relay || return 1
    [[ -n "$pwd" ]] || return 1
    local workspace_id=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1

    local pwd_json params
    pwd_json="$(_bree_json_escape "$pwd")"
    params="{\"workspace_id\":\"$workspace_id\",\"path\":\"$pwd_json\""
    if [[ -n "$BREE_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    params+="}"
    _bree_relay_rpc_bg "surface.report_pwd" "$params"
}

_bree_report_git_branch_via_relay() {
    local branch="$1"
    _bree_socket_uses_remote_relay || return 1
    [[ -n "$branch" ]] || return 1
    local workspace_id="" branch_json="" params=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1
    branch_json="$(_bree_json_escape "$branch")"
    params="{\"workspace_id\":\"$workspace_id\",\"branch\":\"$branch_json\""
    if [[ -n "${BREE_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    params+="}"
    _bree_relay_rpc "surface.report_git_branch" "$params"
}

_bree_clear_git_branch_via_relay() {
    _bree_socket_uses_remote_relay || return 1
    local workspace_id="" params=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1
    params="{\"workspace_id\":\"$workspace_id\""
    if [[ -n "${BREE_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    params+="}"
    _bree_relay_rpc "surface.clear_git_branch" "$params"
}

_bree_report_shell_activity_state_via_relay() {
    local state="$1"
    _bree_socket_uses_remote_relay || return 1
    [[ -n "$state" ]] || return 1
    local workspace_id="" params=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1
    params="{\"workspace_id\":\"$workspace_id\",\"state\":\"$state\""
    if [[ -n "${BREE_PANEL_ID:-}" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    if [[ -n "${BREE_TERMINAL_LIFECYCLE_ID:-}" ]]; then
        params+=",\"terminal_lifecycle_id\":\"$BREE_TERMINAL_LIFECYCLE_ID\""
    fi
    params+="}"
    _bree_relay_rpc_bg "surface.report_shell_state" "$params"
}

_bree_ports_kick_via_relay() {
    local reason="${1:-command}"
    _bree_socket_uses_remote_relay || return 1
    local workspace_id=""
    workspace_id="$(_bree_relay_workspace_id)" || return 1
    local params="{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
    if [[ -n "$BREE_PANEL_ID" ]]; then
        params+=",\"surface_id\":\"$BREE_PANEL_ID\""
    fi
    params+="}"
    _bree_relay_rpc_bg "surface.ports_kick" "$params"
}

_bree_restore_scrollback_once() {
    local path="${BREE_RESTORE_SCROLLBACK_FILE:-}"
    [[ -n "$path" ]] || return 0
    unset BREE_RESTORE_SCROLLBACK_FILE
    local token="${path:t}"

    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/start\007' "$HOST" "$token"

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi

    # Valid kitty-shell-cwd URIs reach Ghostty's PWD action in PTY order. The
    # following real cwd report keeps the private boundary out of title state.
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/end\007' "$HOST" "$token"
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$HOST" "$PWD"
}
_bree_restore_scrollback_once

# First-launch welcome banner. bree passes the path of a one-shot token file in
# BREE_SHOW_WELCOME_FILE instead of typing `bree welcome` into the first
# workspace's shell, so the banner prints during startup and never lands in
# shell history. Only the shell whose `rm` of the token succeeds prints it, and
# never inside tmux, so children that inherited the variable cannot repeat it.
_bree_show_welcome_once() {
    local token="${BREE_SHOW_WELCOME_FILE:-${_BREE_BOOTSTRAP_WELCOME_FILE:-}}"
    unset BREE_SHOW_WELCOME_FILE _BREE_BOOTSTRAP_WELCOME_FILE
    [[ -n "$token" ]] || return 0
    /bin/rm -- "$token" >/dev/null 2>&1 || return 0
    [[ -z "${TMUX:-}" ]] || return 0
    local cli="${BREE_SHELL_INTEGRATION_DIR%/}"
    cli="${cli%/shell-integration}/bin/bree"
    [[ -x "$cli" ]] || cli="$(_bree_relay_cli_path)"
    [[ -n "$cli" ]] || return 0
    "$cli" welcome 2>/dev/null || true
}
_bree_show_welcome_once

_bree_now() {
    print -r -- "${EPOCHSECONDS:-$SECONDS}"
}

typeset -g _BREE_CLAUDE_WRAPPER=""
typeset -g _BREE_GROK_WRAPPER=""
# Sets REPLY to PATH-style $2 with $1 moved to the front (and $3 dropped),
# without the subshell a command substitution would fork.
_bree_path_prepend_unique_directory_into_reply() {
    local directory="$1"
    local current_path="${2-}"
    local skipped_directory="${3-}"
    local result="$directory"
    local rest="$current_path"
    local entry=""
    local has_more=false

    [[ -n "$directory" ]] || {
        REPLY="$current_path"
        return 0
    }
    [[ -n "$current_path" ]] || {
        REPLY="$directory"
        return 0
    }

    while true; do
        if [[ "$rest" == *:* ]]; then
            entry="${rest%%:*}"
            rest="${rest#*:}"
            has_more=true
        else
            entry="$rest"
            rest=""
            has_more=false
        fi

        if [[ "$entry" != "$directory" && ( -z "$skipped_directory" || "$entry" != "$skipped_directory" ) ]]; then
            result="$result:$entry"
        fi
        [[ "$has_more" == true ]] || break
    done

    REPLY="$result"
}

_bree_path_prepend_unique_directory() {
    local REPLY
    _bree_path_prepend_unique_directory_into_reply "$@"
    printf '%s' "$REPLY"
}
# Succeeds when every directory, checked in order, is an absolute path to a
# real directory (not a symlink) owned by this user that no one else can write
# to, with a safe ancestry. Sticky shared ancestors (such as /tmp) are safe;
# a non-sticky writable ancestor can rename a checked child after this check.
_bree_private_dirs() {
    builtin emulate -L zsh
    local create="$1"
    shift
    local dir
    local -a private_dir
    (( $# )) || return 1
    for dir in "$@"; do
        [[ "$dir" == /* ]] || return 1
        if [[ "$create" == 1 && ! -e "$dir" && ! -L "$dir" ]]; then
            /bin/mkdir -m 700 -- "$dir" >/dev/null 2>&1 || return 1
        fi
        # Glob qualifiers use lstat: / rejects symlinks, U requires our euid
        # and f:go-w: requires no group or other write bit.
        private_dir=( "$dir"(N/Uf:go-w:) )
        (( ${#private_dir} )) || return 1
        _bree_private_path_chain "$dir" || return 1
    done
}

_bree_private_path_chain() {
    builtin emulate -L zsh
    local start="$1"
    local current="$start"
    local canonical=""
    while true; do
        _bree_private_path_node "$current" || return 1
        [[ "$current" == "/" ]] && break
        current="${current%/*}"
        [[ -n "$current" ]] || current="/"
    done
    canonical="$(_bree_resolve_path "$start")" || return 1
    [[ "$canonical" == "$start" ]] || _bree_private_path_chain_resolved "$canonical"
}

_bree_private_path_chain_resolved() {
    builtin emulate -L zsh
    local current="$1"
    while true; do
        _bree_private_path_node "$current" || return 1
        [[ "$current" == "/" ]] && return 0
        current="${current%/*}"
        [[ -n "$current" ]] || current="/"
    done
}

_bree_private_path_node() {
    builtin emulate -L zsh
    local current="$1"
    local owner=""
    if [[ -d "$current" && ! -L "$current" ]]; then
        owner="$(/usr/bin/find -P "$current" -prune \( -uid "$EUID" -o -uid 0 \) -print 2>/dev/null)"
        [[ "$owner" == "$current" ]] || return 1
        if [[ "$(/usr/bin/find -P "$current" -prune -type d ! -perm -020 ! -perm -002 -print 2>/dev/null)" == "$current" ]]; then
            return 0
        fi
        [[ "$(/usr/bin/find -P "$current" -prune -type d -perm -1000 -print 2>/dev/null)" == "$current" ]] || return 1
        return 0
    fi
    if [[ -L "$current" ]]; then
        owner="$(/usr/bin/find -P "$current" -prune \( -uid "$EUID" -o -uid 0 \) -print 2>/dev/null)"
        [[ "$owner" == "$current" ]]
        return $?
    fi
    return 1
}

_bree_resolve_path() {
    if [[ -x /usr/bin/realpath ]]; then
        /usr/bin/realpath -- "$1"
    elif [[ -x /bin/realpath ]]; then
        /bin/realpath -- "$1"
    elif [[ -x /usr/bin/readlink ]]; then
        /usr/bin/readlink -f -- "$1"
    else
        return 1
    fi
}
typeset -g _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED=""
_bree_install_cli_command_shim() {
    local command_name="$1"
    local wrapper_path="$2"
    local surface_component="${BREE_SURFACE_ID:-$$}"
    local shim_root="${BREE_CLAUDE_WRAPPER_SHIM_ROOT:-}"
    shim_root="${shim_root%/}"
    local shim_parent="${shim_root%/*}"
    local tmp_root="${TMPDIR:-/tmp}"
    local legacy_shim_root="${tmp_root%/}/bree-cli-shims/$surface_component"
    local shim_dot=.bree
    case "${BREE_BUNDLE_ID:-}" in
        com.bree.app) shim_dot=.bree ;;
        com.bree.app.debug.bree) shim_dot=.bree-dev ;;
    esac
    local shim_state="${HOME:-}/$shim_dot"
    local rejected_root=""
    local REPLY
    # An inherited root is reused only while it is still private. Otherwise
    # the shell makes its own, and skips the shim if it can't.
    if [[ -z "$shim_root" || "${shim_root##*/}" != "$surface_component" || "${shim_parent##*/}" != "bree-cli-shims" || "$shim_root" == "$legacy_shim_root" ]] \
        || ! _bree_private_dirs 0 "$shim_parent" "$shim_root"; then
        # Keep a shim root this shell did not accept off PATH.
        [[ "${shim_parent##*/}" == "bree-cli-shims" ]] && rejected_root="$shim_root"
        shim_parent="$shim_state/bree-cli-shims"
        shim_root="$shim_parent/$surface_component"
        if [[ "${HOME:-}" != /* ]] || ! _bree_private_dirs 1 "$shim_state" "$shim_parent" "$shim_root"; then
            if [[ "$command_name" == "claude" ]]; then
                unset BREE_CLAUDE_WRAPPER_SHIM BREE_CLAUDE_WRAPPER_SHIM_ROOT
                _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED=""
            fi
            if [[ -n "$rejected_root" ]]; then
                _bree_path_prepend_unique_directory_into_reply "$rejected_root" "${PATH-}"
                REPLY="${REPLY#"$rejected_root"}"
                PATH="${REPLY#:}"
                hash -r >/dev/null 2>&1 || rehash >/dev/null 2>&1 || true
            fi
            return 0
        fi
    fi
    local shim_path="$shim_root/$command_name"
    local escaped_wrapper="$wrapper_path"

    escaped_wrapper="${escaped_wrapper//\\/\\\\}"
    escaped_wrapper="${escaped_wrapper//\"/\\\"}"
    escaped_wrapper="${escaped_wrapper//\$/\\\$}"
    escaped_wrapper="${escaped_wrapper//\`/\\\`}"

    /bin/mkdir -p "$shim_root" >/dev/null 2>&1 || return 0
    {
        printf '%s\n' '#!/usr/bin/env bash'
        if [[ "$command_name" == "claude" ]]; then
            printf 'bree_wrapper="%s"\n' "$escaped_wrapper"
            printf '%s\n' 'if [[ ! -x "$bree_wrapper" && -n "${BREE_BUNDLED_CLI_PATH:-}" ]]; then'
            printf '%s\n' '    bree_candidate="$(dirname "$BREE_BUNDLED_CLI_PATH")/bree-claude-wrapper"'
            printf '%s\n' '    if [[ -x "$bree_candidate" ]]; then'
            printf '%s\n' '        bree_wrapper="$bree_candidate"'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf '%s\n' 'if [[ ! -x "$bree_wrapper" ]]; then'
            printf '%s\n' '    bree_cli="$(command -v bree 2>/dev/null || true)"'
            printf '%s\n' '    if [[ -n "$bree_cli" ]]; then'
            printf '%s\n' '        bree_candidate="$(dirname "$bree_cli")/bree-claude-wrapper"'
            printf '%s\n' '        if [[ -x "$bree_candidate" ]]; then'
            printf '%s\n' '            bree_wrapper="$bree_candidate"'
            printf '%s\n' '        fi'
            printf '%s\n' '    fi'
            printf '%s\n' 'fi'
            printf 'export BREE_CLAUDE_WRAPPER_SHIM=%q\n' "$shim_path"
            printf 'export BREE_CLAUDE_WRAPPER_SHIM_ROOT=%q\n' "$shim_root"
            printf '%s\n' 'if [[ -x "$bree_wrapper" ]]; then'
            printf '%s\n' '    exec "$bree_wrapper" "$@"'
            printf '%s\n' 'fi'
            printf '%s\n' 'bree_path_without_shim=""'
            printf '%s\n' 'bree_old_ifs="$IFS"'
            printf '%s\n' 'IFS=:'
            printf '%s\n' 'for bree_entry in ${PATH:-}; do'
            printf '%s\n' '    if [[ "$bree_entry" == "$BREE_CLAUDE_WRAPPER_SHIM_ROOT" || "$bree_entry" == */bree-cli-shims/* || "$bree_entry" == */bree-cli-shims ]]; then'
            printf '%s\n' '        continue'
            printf '%s\n' '    fi'
            printf '%s\n' '    if [[ -z "$bree_path_without_shim" ]]; then'
            printf '%s\n' '        bree_path_without_shim="$bree_entry"'
            printf '%s\n' '    else'
            printf '%s\n' '        bree_path_without_shim="$bree_path_without_shim:$bree_entry"'
            printf '%s\n' '    fi'
            printf '%s\n' 'done'
            printf '%s\n' 'IFS="$bree_old_ifs"'
            printf '%s\n' 'export PATH="$bree_path_without_shim"'
            printf '%s\n' 'exec claude "$@"'
        else
            printf 'exec "%s" "$@"\n' "$escaped_wrapper"
        fi
    # Use zsh's explicit clobber redirection (>|) so bree always refreshes its
    # own generated shim, even when the user's interactive zsh has `noclobber`
    # set. A plain `>` is refused under noclobber and prints `file exists` on
    # startup (the writer runs again from the _bree_fix_path precmd hook after
    # the shim already exists). See issue #6714.
    } >|"$shim_path" 2>/dev/null || return 0
    /bin/chmod 0700 "$shim_path" >/dev/null 2>&1 || return 0

    if [[ "$command_name" == "claude" ]]; then
        export BREE_CLAUDE_WRAPPER_SHIM="$shim_path"
        export BREE_CLAUDE_WRAPPER_SHIM_ROOT="$shim_root"
        _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED="$shim_path"
    fi

    _bree_path_prepend_unique_directory_into_reply "$shim_root" "${PATH-}" "$rejected_root"
    PATH="$REPLY"
    hash -r >/dev/null 2>&1 || rehash >/dev/null 2>&1 || true
}
_bree_claude_wrapper_command() {
    # Only run a shim this shell wrote into a directory it checked.
    if [[ -n "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED" && "${BREE_CLAUDE_WRAPPER_SHIM:-}" == "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED" && -x "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED" ]]; then
        "$BREE_CLAUDE_WRAPPER_SHIM" "$@"
    elif [[ -x "${_BREE_CLAUDE_WRAPPER:-}" ]]; then
        "$_BREE_CLAUDE_WRAPPER" "$@"
    else
        command claude "$@"
    fi
}
_bree_install_cli_wrapper() {
    local command_name="$1"
    local wrapper_variable="$2"
    local wrapper_file="${3:-$command_name}"
    local integration_dir="${BREE_SHELL_INTEGRATION_DIR:-}"
    if [[ "$command_name" == "claude" && "${BREE_CLAUDE_INTEGRATION_DISABLED:-0}" == "1" ]]; then
        return 0
    fi
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/$wrapper_file"
    [[ -x "$wrapper_path" ]] || return 0

    # Keep the bundled wrapper ahead of later PATH mutations. Install it
    # via eval so an existing alias cannot break parsing.
    typeset -g "$wrapper_variable=$wrapper_path"
    if [[ "$command_name" == "claude" ]]; then
        _bree_install_cli_command_shim "$command_name" "$wrapper_path"
    fi
    builtin unalias "$command_name" >/dev/null 2>&1 || true
    if [[ "$command_name" == "claude" ]]; then
        eval "$command_name() { _bree_claude_wrapper_command \"\$@\"; }"
    else
        eval "$command_name() { \"\${$wrapper_variable}\" \"\$@\"; }"
    fi
}
_bree_install_cli_wrapper claude _BREE_CLAUDE_WRAPPER bree-claude-wrapper
_bree_install_cli_wrapper grok _BREE_GROK_WRAPPER

_bree_normalize_claude_config_dir() {
    [[ -n "${CLAUDE_CONFIG_DIR:-}" && -n "${HOME:-}" ]] || return 0

    local value="$CLAUDE_CONFIG_DIR"
    if [[ "$value" == "~/"* ]]; then
        value="$HOME/${value#~/}"
    fi

    local legacy_root="$HOME/.subrouter/codex/claude"
    local account_root="$HOME/.codex-accounts/claude"
    local suffix candidate

    if [[ "$value" == "$legacy_root" ]]; then
        candidate="$account_root"
    elif [[ "$value" == "$legacy_root/"* ]]; then
        suffix="${value#$legacy_root/}"
        candidate="$account_root/$suffix"
    else
        return 0
    fi

    [[ -d "$candidate" ]] || return 0
    export CLAUDE_CONFIG_DIR="$candidate"
}
_bree_normalize_claude_config_dir

# Throttle heavy work to avoid prompt latency.
typeset -g _BREE_PWD_LAST_PWD=""
typeset -g _BREE_GIT_LAST_PWD=""
typeset -g _BREE_GIT_LAST_RUN=0
typeset -g _BREE_GIT_JOB_PID=""
typeset -g _BREE_GIT_JOB_STARTED_AT=0
typeset -g _BREE_GIT_FORCE=0
typeset -g _BREE_GIT_HEAD_LAST_PWD=""
typeset -g _BREE_GIT_HEAD_PATH=""
typeset -g _BREE_GIT_HEAD_SIGNATURE=""
typeset -g _BREE_GIT_HEAD_WATCH_PID=""
# Created on first use by _bree_set_git_active_pwd, and only while git watching
# is on: the git reporters are its only readers.
typeset -g _BREE_GIT_ACTIVE_PWD_FILE="${_BREE_GIT_ACTIVE_PWD_FILE:-}"
typeset -g _BREE_ASYNC_JOB_TIMEOUT=20

typeset -g _BREE_PORTS_LAST_RUN=0
typeset -g _BREE_CMD_START=0
typeset -g _BREE_SHELL_ACTIVITY_LAST=""
typeset -g _BREE_TTY_NAME=""
typeset -g _BREE_TTY_REPORTED=0
typeset -g _BREE_TMUX_PUSH_SIGNATURE=""
typeset -g _BREE_TMUX_PULL_SIGNATURE=""
typeset -g _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=${_BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT:-0}
# Keep BREE_SOCKET_CAPABILITY inherited; tmux's global environment is readable
# by clients that were not started inside bree.
typeset -ga _BREE_TMUX_SYNC_KEYS=(
    BREE_BUNDLED_CLI_PATH
    BREE_BUNDLE_ID
    BREED_UNIX_PATH
    BREE_REPO_ROOT
    BREE_DEBUG_LOG
    BREE_LOAD_GHOSTTY_ZSH_INTEGRATION
    BREE_PORT
    BREE_PORT_END
    BREE_PORT_RANGE
    BREE_REMOTE_DAEMON_ALLOW_LOCAL_BUILD
    BREE_SHELL_INTEGRATION
    BREE_SHELL_INTEGRATION_DIR
    BREE_SOCKET_ENABLE
    BREE_SOCKET_MODE
    BREE_SOCKET_PATH
    BREE_SSH_ATTEMPT_ID
    BREE_TAB_ID
    BREE_TAG
    BREE_TERMINAL_LIFECYCLE_ID
    BREE_WORKSPACE_ID
)
typeset -ga _BREE_TMUX_SURFACE_SCOPED_KEYS=(
    BREE_HISTORY_FILE
    BREE_PANEL_ID
    BREE_SURFACE_ID
)

_bree_tmux_sync_key_is_managed() {
    local candidate="$1"
    local key
    for key in "${_BREE_TMUX_SYNC_KEYS[@]}"; do
        [[ "$key" == "$candidate" ]] && return 0
    done
    return 1
}

# Sets REPLY rather than printing, so prompt hooks do not fork a subshell.
_bree_tmux_shell_env_signature_into_reply() {
    local key value
    local -a parts
    for key in "${_BREE_TMUX_SYNC_KEYS[@]}"; do
        value="${(P)key}"
        [[ -n "$value" ]] || continue
        parts+=("${key}=${value}")
    done
    REPLY="${(j:\x1f:)parts}"
}

_bree_tmux_shell_env_signature() {
    local REPLY
    _bree_tmux_shell_env_signature_into_reply
    print -r -- "$REPLY"
}

# A published environment only matters to a running default tmux server; a
# server started later inherits it from the shell that starts it. Checking the
# socket keeps every prompt and command from spawning a tmux client that can
# only fail when no server is running. tmux ignores a TMUX_TMPDIR that does not
# resolve and falls back to /tmp, so the socket path follows the same rule.
_bree_tmux_default_server_socket_into_reply() {
    local socket_root="/tmp"
    [[ -n "${TMUX_TMPDIR:-}" && -e "$TMUX_TMPDIR" ]] && socket_root="$TMUX_TMPDIR"
    REPLY="${socket_root%/}/tmux-${UID}/default"
}

_bree_tmux_default_server_running() {
    local REPLY
    _bree_tmux_default_server_socket_into_reply
    [[ -S "$REPLY" ]]
}

# An exited tmux server can leave its socket behind. When tmux reports that
# nothing is listening there, a marker next to the socket records it as dead, so
# later prompts and shells skip the tmux spawn until a new server rebinds the
# socket (which makes the socket newer than the marker). Other failures, such as
# an interrupted client, leave no marker. The socket directory is private to the
# user, so the marker cannot be redirected through a planted symlink.
_bree_tmux_error_means_no_server() {
    [[ "$1" == *"no server running"* || "$1" == *"error connecting"* || "$1" == *"Connection refused"* ]]
}

_bree_tmux_publish_bree_environment() {
    [[ -z "$TMUX" ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local REPLY
    _bree_tmux_default_server_socket_into_reply
    local server_socket="$REPLY"
    [[ -S "$server_socket" ]] || return 0
    local stale_marker="${server_socket}.bree-unreachable"
    [[ -e "$stale_marker" && ! "$server_socket" -nt "$stale_marker" ]] && return 0

    _bree_tmux_shell_env_signature_into_reply
    local signature="$REPLY"
    [[ -n "$signature" ]] || return 0
    [[ "$signature" == "$_BREE_TMUX_PUSH_SIGNATURE" ]] && return 0

    local key value tmux_error
    for key in "${_BREE_TMUX_SYNC_KEYS[@]}"; do
        value="${(P)key}"
        [[ -n "$value" ]] || continue
        if ! tmux_error="$(tmux set-environment -g "$key" "$value" 2>&1 >/dev/null)"; then
            if _bree_tmux_error_means_no_server "$tmux_error"; then
                : 2>/dev/null >| "$stale_marker"
            fi
            return 0
        fi
    done

    for key in "${_BREE_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        tmux set-environment -gu "$key" >/dev/null 2>&1 || return 0
    done

    _BREE_TMUX_PUSH_SIGNATURE="$signature"
}

_bree_tmux_refresh_bree_environment() {
    [[ -n "$TMUX" ]] || return 0
    # A persistent local shell owns its surface env; never replace it from the tmux server.
    [[ "$BREE_LOCAL_TMUX_AUTO" != 1 ]] || return 0
    command -v tmux >/dev/null 2>&1 || return 0

    local key did_change=0
    for key in "${_BREE_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        if [[ -n "${(P)key}" ]]; then
            unset "$key"
            did_change=1
        fi
    done

    local output
    output="$(tmux show-environment 2>/dev/null)" || return 0

    local line filtered=""
    while IFS= read -r line; do
        [[ "$line" == BREE_* ]] || continue
        key="${line%%=*}"
        _bree_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_BREE_TMUX_PULL_SIGNATURE" ]] && (( ! did_change )) && return 0

    local value
    while IFS= read -r line; do
        [[ "$line" == BREE_* ]] || continue
        key="${line%%=*}"
        _bree_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${(P)key}" != "$value" ]]; then
            export "$key=$value"
            did_change=1
        fi
    done <<< "$filtered"

    _BREE_TMUX_PULL_SIGNATURE="$filtered"
    if (( did_change )); then
        _BREE_TTY_REPORTED=0
        _BREE_SHELL_ACTIVITY_LAST=""
        _BREE_PWD_LAST_PWD=""
        _BREE_GIT_LAST_PWD=""
        _BREE_GIT_HEAD_LAST_PWD=""
        _BREE_GIT_HEAD_PATH=""
        _BREE_GIT_HEAD_SIGNATURE=""
        _BREE_GIT_FORCE=1
        _bree_stop_git_head_watch
    fi
}

_bree_tmux_sync_bree_environment() {
    if [[ -n "$TMUX" ]]; then
        _bree_tmux_refresh_bree_environment
    else
        _bree_tmux_publish_bree_environment
    fi
}

_bree_prepend_job_table_guard_to_function() {
    local fn_name="$1"
    (( $+functions[$fn_name] )) || return 0
    local saved_var="__bree_${fn_name}_saved_status"
    [[ "${functions[$fn_name]}" == *"$saved_var"* ]] && return 0

    functions[$fn_name]="builtin local ${saved_var}=\$?
_bree_zsh_job_table_saturated && builtin return 0
_bree_restore_status \"\$${saved_var}\"
${functions[$fn_name]}"
}

# Usage: _bree_insert_job_table_guard_after_declaration FN TARGET GUARD [TARGET GUARD]...
# Inserts each GUARD after the first nested declaration of its TARGET inside FN,
# walking FN's body once for every pair.
_bree_insert_job_table_guard_after_declaration() {
    builtin emulate -L zsh -o extended_glob -o no_aliases

    local fn_name="$1"
    shift
    (( $+functions[$fn_name] )) || return 0

    local body="${functions[$fn_name]}"
    local -A pending
    while (( $# >= 2 )); do
        [[ "$body" == *"$2"* ]] || pending[$1]="$2"
        shift 2
    done
    (( ${#pending} )) || return 0

    local -a lines patched_lines declaration_names
    lines=("${(@f)body}")
    local line trimmed declaration candidate
    local inserted=0

    for line in "${lines[@]}"; do
        patched_lines+=("$line")
        (( ${#pending} )) || continue

        trimmed="${line##[[:space:]]#}"
        [[ "$trimmed" == *"{"* ]] || continue

        declaration="${trimmed%%\{}"
        declaration="${declaration//\(\)/ }"
        if [[ "$declaration" == function[[:space:]]* ]]; then
            declaration="${declaration#function}"
        fi
        declaration_names=("${(@z)declaration}")

        for candidate in "${declaration_names[@]}"; do
            if (( ${+pending[$candidate]} )); then
                patched_lines+=("${(@f)pending[$candidate]}")
                unset "pending[$candidate]"
                inserted=1
            fi
        done
    done

    (( inserted )) || return 0
    functions[$fn_name]="${(F)patched_lines}"
}

_bree_patch_ghostty_job_table_guard() {
    local guard_precmd=$'        builtin local __bree__ghostty_precmd_saved_status=$?\n        _bree_zsh_job_table_saturated && builtin return 0\n        _bree_restore_status "$__bree__ghostty_precmd_saved_status"'
    local guard_preexec=$'        builtin local __bree__ghostty_preexec_saved_status=$?\n        _bree_zsh_job_table_saturated && builtin return 0\n        _bree_restore_status "$__bree__ghostty_preexec_saved_status"'
    local guard_zle_init=$'          builtin local __bree__ghostty_zle_line_init_saved_status=$?\n          _bree_zsh_job_table_saturated && builtin return 0\n          _bree_restore_status "$__bree__ghostty_zle_line_init_saved_status"'
    local guard_zle_finish=$'          builtin local __bree__ghostty_zle_line_finish_saved_status=$?\n          _bree_zsh_job_table_saturated && builtin return 0\n          _bree_restore_status "$__bree__ghostty_zle_line_finish_saved_status"'
    local guard_zle_keymap=$'          builtin local __bree__ghostty_zle_keymap_select_saved_status=$?\n          _bree_zsh_job_table_saturated && builtin return 0\n          _bree_restore_status "$__bree__ghostty_zle_keymap_select_saved_status"'

    # Patch deferred definitions before Ghostty's first precmd installs and
    # invokes its live hook functions.
    if (( $+functions[_ghostty_deferred_init] )); then
        _bree_insert_job_table_guard_after_declaration _ghostty_deferred_init \
            _ghostty_precmd "$guard_precmd" \
            _ghostty_preexec "$guard_preexec" \
            _ghostty_zle_line_init "$guard_zle_init" \
            _ghostty_zle_line_finish "$guard_zle_finish" \
            _ghostty_zle_keymap_select "$guard_zle_keymap"
    fi

    _bree_prepend_job_table_guard_to_function _ghostty_precmd
    _bree_prepend_job_table_guard_to_function _ghostty_preexec
    _bree_prepend_job_table_guard_to_function _ghostty_zle_line_init
    _bree_prepend_job_table_guard_to_function _ghostty_zle_line_finish
    _bree_prepend_job_table_guard_to_function _ghostty_zle_keymap_select
}
_bree_patch_ghostty_job_table_guard

# Inside Bree's private tmux (BREE_LOCAL_TMUX_AUTO=1) tmux swallows OSC 133, so the
# exit-code badges vanish. Re-wrap every Ghostty 133 mark in a tmux DCS
# passthrough (needs `allow-passthrough on`, set on Bree's own server). The
# backslash run is captured so the same rewrite works in the doubled-escape
# text inside _ghostty_deferred_init.
_bree_patch_ghostty_tmux_passthrough() {
    [[ "$BREE_LOCAL_TMUX" == 1 || "$BREE_LOCAL_TMUX_AUTO" == 1 ]] || return 0
    setopt local_options extended_glob
    local fn body
    for fn in _ghostty_deferred_init _ghostty_precmd _ghostty_preexec _ghostty_zle_line_init; do
        (( $+functions[$fn] )) || continue
        body=${functions[$fn]}
        [[ "$body" == *"ePtmux;"* ]] && continue
        functions[$fn]=${body//(#b)(\\##)e\]133\;([^\\]#)(\\##)a/${match[1]}ePtmux;${match[1]}e${match[1]}e]133;${match[2]}${match[3]}a${match[1]}e${match[1]}${match[1]}}
    done
}
_bree_patch_ghostty_tmux_passthrough

# Resolve the HEAD file path without invoking git (fast; works for worktrees).
# Sets REPLY (empty when not in a repository) so prompt hooks need no subshell.
_bree_git_resolve_head_path_into_reply() {
    REPLY=""
    local dir="${1:-$PWD}"
    while true; do
        if [[ -d "$dir/.git" ]]; then
            REPLY="$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            line="$(<"$dir/.git")"
            if [[ "$line" == gitdir:* ]]; then
                gitdir="${line#gitdir:}"
                gitdir="${gitdir## }"
                gitdir="${gitdir%% }"
                [[ -n "$gitdir" ]] || return 1
                [[ "$gitdir" != /* ]] && gitdir="$dir/$gitdir"
                REPLY="$gitdir/HEAD"
                return 0
            fi
        fi
        [[ "$dir" == "/" || -z "$dir" ]] && break
        dir="${dir:h}"
    done
    return 1
}

_bree_git_resolve_head_path() {
    local REPLY
    _bree_git_resolve_head_path_into_reply "$@" || return 1
    print -r -- "$REPLY"
}

_bree_git_resolve_git_dir() {
    local repo_path="${1:-$PWD}"
    local head_path
    head_path="$(_bree_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" ]] || return 1
    print -r -- "${head_path:h}"
}

_bree_git_head_signature() {
    local head_path="$1"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    local line=""
    if IFS= read -r line < "$head_path"; then
        print -r -- "$line"
        return 0
    fi
    return 1
}

_bree_git_branch_for_path() {
    local repo_path="$1"
    local head_path="" head_line="" prefix="ref: refs/heads/"
    head_path="$(_bree_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    head_line="$(<"$head_path")"
    [[ "$head_line" == "$prefix"* ]] || return 1
    print -r -- "${head_line#$prefix}"
}

_bree_set_git_active_pwd() {
    local active_pwd="$1"
    [[ -n "$active_pwd" ]] || return 0
    if [[ -z "${_BREE_GIT_ACTIVE_PWD_FILE:-}" ]]; then
        # Create it only from the prompt in the shell itself: chpwd also fires in
        # subshells (`$(cd x && pwd)` in startup files), whose copy would leak.
        [[ "${2:-}" == "create" ]] || return 0
        (( ${ZSH_SUBSHELL:-0} == 0 )) || return 0
        [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]] && return 0
        _BREE_GIT_ACTIVE_PWD_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/bree-git-active-pwd.XXXXXX" 2>/dev/null)"
        [[ -n "$_BREE_GIT_ACTIVE_PWD_FILE" ]] || return 0
    fi
    print -r -- "$active_pwd" >| "$_BREE_GIT_ACTIVE_PWD_FILE" 2>/dev/null || true
}

_bree_git_report_path_is_active() {
    local repo_path="$1"
    [[ -n "$repo_path" ]] || return 1
    [[ -n "${_BREE_GIT_ACTIVE_PWD_FILE:-}" ]] || return 0
    [[ -r "$_BREE_GIT_ACTIVE_PWD_FILE" ]] || return 0

    local active_pwd=""
    IFS= read -r active_pwd < "$_BREE_GIT_ACTIVE_PWD_FILE" || active_pwd=""
    # No recorded cwd yet, or the report targets the current cwd exactly: allow.
    [[ -z "$active_pwd" || "$repo_path" == "$active_pwd" ]] && return 0

    # Otherwise the report is valid only when the current cwd is in the SAME
    # repository as repo_path. This keeps live branch updates flowing after an
    # in-repo `cd pkg` (the HEAD watch still reports the preexec watch_pwd) while
    # still dropping a report once the shell has left the repo entirely (the
    # stale-branch case). Resolve both HEAD paths without invoking git and compare.
    local repo_head active_head
    repo_head="$(_bree_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    active_head="$(_bree_git_resolve_head_path "$active_pwd" 2>/dev/null || true)"
    [[ -n "$repo_head" && "$repo_head" == "$active_head" ]]
}

# Sets REPLY (empty when there is nothing to report) without forking.
_bree_report_tty_payload_into_reply() {
    REPLY=""
    [[ -n "$BREE_TAB_ID" ]] || return 0
    [[ -n "$_BREE_TTY_NAME" ]] || return 0

    local payload="report_tty $_BREE_TTY_NAME --tab=$BREE_TAB_ID"
    if [[ -z "$TMUX" || "$BREE_LOCAL_TMUX_AUTO" == 1 ]]; then
        [[ -n "$BREE_PANEL_ID" ]] || return 0
        payload+=" --panel=$BREE_PANEL_ID"
    fi

    REPLY="$payload"
}

_bree_report_tty_payload() {
    local REPLY
    _bree_report_tty_payload_into_reply
    [[ -n "$REPLY" ]] || return 0
    print -r -- "$REPLY"
}

_bree_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _BREE_TTY_REPORTED )) && return 0
    _bree_has_port_scan_transport || return 0

    if _bree_socket_is_unix; then
        local REPLY
        _bree_report_tty_payload_into_reply
        local payload="$REPLY"
        [[ -n "$payload" ]] || return 0
        # Batch the first ports kick behind the registration in the same
        # child: the scanner drops kicks for unregistered TTYs, and two
        # detached children can connect out of order. Latch only after the
        # send was actually enqueued so a cap-dropped registration retries.
        if [[ -n "$BREE_TAB_ID" && -n "$BREE_PANEL_ID" ]]; then
            _bree_send_bg "$payload" "ports_kick --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID --reason=command" || return 0
        else
            _bree_send_bg "$payload" || return 0
        fi
        _BREE_TTY_REPORTED=1
    else
        [[ -n "$_BREE_TTY_NAME" ]] || return 0
        # Keep the first relay TTY report synchronous so the server can resolve
        # the target surface before command-start kicks begin their scan burst.
        _bree_report_tty_via_relay || return 0
        _BREE_TTY_REPORTED=1
    fi
}

_bree_report_shell_activity_state() {
    local state="$1"
    [[ -n "$state" ]] || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0
    if _bree_socket_is_unix; then
        [[ -n "$BREE_PANEL_ID" ]] || return 0
    fi
    [[ "$_BREE_SHELL_ACTIVITY_LAST" == "$state" ]] && return 0
    _BREE_SHELL_ACTIVITY_LAST="$state"
    if _bree_socket_is_unix; then
        local payload="report_shell_state $state --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
        if [[ -n "${BREE_TERMINAL_LIFECYCLE_ID:-}" ]]; then
            payload+=" --terminal-lifecycle-id=$BREE_TERMINAL_LIFECYCLE_ID"
        fi
        _bree_send_bg "$payload" \
            || _BREE_SHELL_ACTIVITY_LAST=""
    else
        _bree_report_shell_activity_state_via_relay "$state" || _BREE_SHELL_ACTIVITY_LAST=""
    fi
}

_bree_reset_terminal_keyboard_protocols() {
    [[ -t 1 || -n "${BREE_TEST_FORCE_KEYBOARD_RESET:-}${BREE_TEST_FORCE_KITTY_RESET:-}" ]] || return 0
    # A crashed TUI may leave keyboard protocol state pushed. At a fresh shell
    # prompt, return terminal input encoding to plain readline bytes.
    printf '\033[>m\033[<8u'
}

_bree_ports_kick() {
    local reason="${1:-command}"
    # Lightweight: just tell the app to run a batched scan for this panel.
    # The app coalesces kicks across all panels and runs a single ps+lsof.
    _bree_has_port_scan_transport || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0
    if _bree_socket_is_unix; then
        [[ -n "$BREE_PANEL_ID" ]] || return 0
    fi
    _BREE_PORTS_LAST_RUN="${EPOCHSECONDS:-$SECONDS}"
    if _bree_socket_is_unix; then
        _bree_send_bg "ports_kick --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID --reason=$reason"
    else
        _bree_ports_kick_via_relay "$reason"
    fi
}

_bree_report_git_branch_for_path() {
    local repo_path="$1"
    [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -n "$repo_path" ]] || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0
    if _bree_socket_is_unix; then
        [[ -n "$BREE_PANEL_ID" ]] || return 0
    fi
    _bree_git_report_path_is_active "$repo_path" || return 0

    local branch dirty_opt="--status=unknown"
    branch="$(_bree_git_branch_for_path "$repo_path" 2>/dev/null || true)"
    _bree_git_report_path_is_active "$repo_path" || return 0
    if [[ -n "$branch" ]]; then
        if _bree_socket_is_unix; then
            _bree_send "report_git_branch $branch $dirty_opt --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
        else
            _bree_report_git_branch_via_relay "$branch" || true
        fi
    else
        if _bree_socket_is_unix; then
            _bree_send "clear_git_branch --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
        else
            _bree_clear_git_branch_via_relay || true
        fi
    fi
}

# Stable parent identity for disowned watchers (issue #10926): a bare
# `kill -0 $pid` guard is defeated by PID reuse. macOS recycles PIDs within
# days on a busy machine, so once the recorded shell PID is reassigned to any
# live process the guard returns true forever and the watcher never exits
# (793 orphans / 2.1 GB after 20 days). Pair the PID with Darwin's kernel
# start time (epoch seconds) from Darwin so a recycled PID no longer counts as
# the parent. Both providers return the same representation.
_bree_watcher_parent_start_time() {
    local pid="${1:-}" raw month day clock year token
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    case "$pid" in *[1-9]*) ;; *) return 1 ;; esac
    local kernel="$(/usr/sbin/sysctl -n "kern.proc.pid.$pid" 2>/dev/null | /usr/bin/od -An -tu4 2>/dev/null)"
    local -a fields=(${=kernel})
    local i sec usec
    for (( i = 1; i < ${#fields}; i++ )); do
        sec="${fields[i]}"; usec="${fields[i+1]}"
        if [[ "$sec" == <-> && "$usec" == <-> ]] && (( sec >= 1000000000 && sec <= 3000000000 && usec < 1000000 )); then
            token="$sec"
            _bree_watcher_parent_identity_valid "$pid" "$token" || return 1
            print -r -- "$token"
            return 0
        fi
    done
    # Darwin's ps exposes process start time through `lstart`, which is a
    # locale-formatted string. Force the stable C locale and UTC timezone,
    # then use date(1) to convert it to the same epoch-second token.
    raw="$(TZ=UTC LC_ALL=C /bin/ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
    case "$raw" in *$'\n'*) return 1 ;; esac
    local -a words
    words=("${(@z)raw}")
    (( ${#words} == 5 )) || return 1
    case "${words[1]}" in Mon|Tue|Wed|Thu|Fri|Sat|Sun) ;; *) return 1 ;; esac
    case "${words[2]}" in
        Jan) month=01 ;; Feb) month=02 ;; Mar) month=03 ;;
        Apr) month=04 ;; May) month=05 ;; Jun) month=06 ;;
        Jul) month=07 ;; Aug) month=08 ;; Sep) month=09 ;;
        Oct) month=10 ;; Nov) month=11 ;; Dec) month=12 ;;
        *) return 1 ;;
    esac
    case "${words[3]}" in
        [1-9]) day="0${words[3]}" ;;
        0[1-9]|[12][0-9]|3[01]) day="${words[3]}" ;;
        *) return 1 ;;
    esac
    case "${words[4]}" in
        [01][0-9]:[0-5][0-9]:[0-5][0-9]|2[0-3]:[0-5][0-9]:[0-5][0-9]) clock="${words[4]}" ;;
        *) return 1 ;;
    esac
    case "${words[5]}" in
        [0-9][0-9][0-9][0-9]) year="${words[5]}" ;;
        *) return 1 ;;
    esac
    token="$(TZ=UTC LC_ALL=C /bin/date -j -u -f '%a %b %d %T %Y' "$raw" '+%s' 2>/dev/null)" || return 1
    [[ "$token" == <-> ]] || return 1
    _bree_watcher_parent_identity_valid "$pid" "$token" || return 1
    print -r -- "$token"
}

_bree_watcher_parent_identity_valid() {
    local pid="${1:-}" identity="${2:-}"
    case "$pid" in
        ''|*[!0-9]*) return 1 ;;
    esac
    case "$pid" in
        *[1-9]*) ;;
        *) return 1 ;;
    esac
    case "$identity" in
        ''|*[!0-9]*) return 1 ;;
    esac
    (( ${#identity} >= 10 && ${#identity} <= 11 ))
}

_bree_watcher_parent_state_valid() {
    local pid="${1:-}" state
    state="$(LC_ALL=C /bin/ps -o state= -p "$pid" 2>/dev/null)" || return 1
    state="${state#"${state%%[![:space:]]*}"}"
    state="${state%%[[:space:]]*}"
    case "$state" in
        ''|Z*) return 1 ;;
        *) return 0 ;;
    esac
}

_bree_watcher_parent_alive() {
    # $1 = parent PID, $2 = numeric start time recorded at watcher spawn. A
    # mismatch means the PID was recycled; a failed /bin/ps counts as
    # parent-dead. Missing or malformed identity is also parent-dead, so a
    # watcher never falls back to PID-only liveness.
    local pid="${1:-}" expected="${2:-}" actual
    _bree_watcher_parent_identity_valid "$pid" "$expected" || return 1
    kill -0 "$pid" >/dev/null 2>&1 || return 1
    _bree_watcher_parent_state_valid "$pid" || return 1
    actual="$(_bree_watcher_parent_start_time "$pid")" || return 1
    [[ "$actual" == "$expected" ]]
}

_bree_capture_shell_start_time() {
    # Cache this shell's own start time once per shell lifetime: $$ never
    # changes, so the value cannot go stale, and watcher starts (one runs from
    # preexec) must not pay a /bin/ps fork per command. Only a valid value tied
    # to this shell PID is cached, so a transient ps failure heals on the next
    # watcher start.
    if [[ "${_BREE_SHELL_START_PID:-}" == "$$" ]] \
        && _bree_watcher_parent_identity_valid "$$" "${_BREE_SHELL_START_TIME:-}"; then
        return 0
    fi
    typeset -g _BREE_SHELL_START_PID _BREE_SHELL_START_TIME
    _BREE_SHELL_START_TIME=""
    _BREE_SHELL_START_PID=""
    _BREE_SHELL_START_TIME="$(_bree_watcher_parent_start_time "$$" 2>/dev/null)" || return 1
    _bree_watcher_parent_identity_valid "$$" "$_BREE_SHELL_START_TIME" || {
        _BREE_SHELL_START_TIME=""
        return 1
    }
    _BREE_SHELL_START_PID="$$"
}

_bree_watcher_guard_tick() {
    # Tiered per-iteration guard for watcher loops: the builtin kill -0 runs
    # every call (plain parent death is caught within one iteration), and the
    # /bin/ps identity comparison runs only every Nth call (default 30, via
    # _BREE_WATCHER_IDENTITY_INTERVAL) so steady-state watchers do not fork
    # once per second. PID-reuse detection latency is bounded by N iterations.
    # Runs inside the forked watcher, so the countdown global is private to
    # that watcher.
    local pid="${1:-}" expected="${2:-}"
    _bree_watcher_parent_identity_valid "$pid" "$expected" || return 1
    kill -0 "$pid" >/dev/null 2>&1 || return 1
    local countdown="${_BREE_WATCHER_GUARD_COUNTDOWN:-0}"
    case "$countdown" in
        ''|*[!0-9]*) countdown=0 ;;
    esac
    if (( countdown > 0 )); then
        _BREE_WATCHER_GUARD_COUNTDOWN=$(( countdown - 1 ))
        return 0
    fi
    local interval="${_BREE_WATCHER_IDENTITY_INTERVAL:-30}"
    case "$interval" in
        ''|*[!0-9]*) interval=30 ;;
    esac
    (( interval > 0 )) || interval=30
    _BREE_WATCHER_GUARD_COUNTDOWN=$(( interval - 1 ))
    _bree_watcher_parent_alive "$pid" "$expected"
}

_bree_stop_git_head_watch() {
    [[ -n "$_BREE_GIT_HEAD_WATCH_PID" ]] || return 0
    kill "$_BREE_GIT_HEAD_WATCH_PID" >/dev/null 2>&1 || true
    _BREE_GIT_HEAD_WATCH_PID=""
}

_bree_start_git_head_watch() {
    [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]] && return 0
    [[ -S "$BREE_SOCKET_PATH" ]] || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0
    [[ -n "$BREE_PANEL_ID" ]] || return 0
    _bree_zsh_job_table_saturated && return 0

    local watch_pwd="$PWD"
    local watch_head_path
    watch_head_path="$(_bree_git_resolve_head_path "$watch_pwd" 2>/dev/null || true)"
    [[ -n "$watch_head_path" ]] || return 0

    local watch_head_signature
    watch_head_signature="$(_bree_git_head_signature "$watch_head_path" 2>/dev/null || true)"

    _BREE_GIT_HEAD_LAST_PWD="$watch_pwd"
    _BREE_GIT_HEAD_PATH="$watch_head_path"
    _BREE_GIT_HEAD_SIGNATURE="$watch_head_signature"

    _bree_stop_git_head_watch
    local watch_shell_pid="$$"
    _bree_capture_shell_start_time || return 0
    local watch_shell_start="$_BREE_SHELL_START_TIME"
    {
        local last_signature="$watch_head_signature"
        _BREE_WATCHER_GUARD_COUNTDOWN=0
        while true; do
            _bree_watcher_guard_tick "$watch_shell_pid" "$watch_shell_start" || break
            _bree_sleep_cs 100

            local signature
            signature="$(_bree_git_head_signature "$watch_head_path" 2>/dev/null || true)"
            if [[ -n "$signature" && "$signature" != "$last_signature" ]]; then
                last_signature="$signature"
                _bree_report_git_branch_for_path "$watch_pwd"
            fi
        done
    } >/dev/null 2>&1 &!
    _BREE_GIT_HEAD_WATCH_PID=$!
}

_bree_command_starts_nested_shell() {
    local cmd="$1"
    local -a words
    words=("${(z)cmd}")

    local index=1
    local word base
    while (( index <= ${#words} )); do
        word="${words[index]}"

        case "$word" in
            *=*)
                index=$(( index + 1 ))
                continue ;;
            exec|command|builtin|noglob|time)
                index=$(( index + 1 ))
                continue ;;
            env)
                index=$(( index + 1 ))
                while (( index <= ${#words} )); do
                    word="${words[index]}"
                    case "$word" in
                        -*|*=*)
                            index=$(( index + 1 ))
                            continue ;;
                    esac
                    break
                done
                continue ;;
        esac

        base="${word:t}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_bree_preexec() {
    local cmd="${1## }"
    _bree_stop_git_head_watch
    _bree_zsh_job_table_saturated && return 0

    _bree_normalize_claude_config_dir
    if (( ! _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT )); then
        _bree_restore_terminal_identity_after_startup
    fi
    _bree_tmux_sync_bree_environment

    if [[ -z "$_BREE_TTY_NAME" ]]; then
        # zsh already knows its terminal in $TTY; only spawn tty(1) without it.
        local t="${TTY:-}"
        [[ -n "$t" ]] || t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _BREE_TTY_NAME="$t"
    fi

    _BREE_CMD_START="${EPOCHSECONDS:-$SECONDS}"
    _bree_report_shell_activity_state running

    # Heuristic: commands that may change git branch/dirty state without changing $PWD.
    case "$cmd" in
        git\ *|git|gh\ *|lazygit|lazygit\ *|tig|tig\ *|gitui|gitui\ *|stg\ *|jj\ *)
            _BREE_GIT_FORCE=1 ;;
    esac

    # Register TTY + kick batched port scan for foreground commands (servers).
    _bree_report_tty_once
    _bree_ports_kick command
    if _bree_command_starts_nested_shell "$cmd"; then
        return 0
    fi
    _bree_start_git_head_watch
}

# Per-terminal history, layered on the shell's own. HISTFILE is left alone,
# so a new terminal recalls global history and every command still reaches
# the global file exactly as in any other terminal. Alongside it, each
# command is appended to this surface's file; when a restored terminal finds
# entries there, they are read on top of global history so Up recalls what
# was typed in this terminal first. With SAVEHIST unset or zero zsh persists
# nothing, and neither does this.
_bree_terminal_history_precmd() {
    [[ -n "${BREE_HISTORY_FILE:-}" && -n "${HISTFILE:-}" && "$HISTFILE" != /dev/null ]] || return 0
    (( ${SAVEHIST:-0} > 0 )) || return 0
    local entry
    if [[ -z "${_BREE_HISTORY_INITIALIZED:-}" ]]; then
        typeset -g _BREE_HISTORY_INITIALIZED=1
        if [[ -s "$BREE_HISTORY_FILE" ]]; then
            local -a lines
            lines=("${(@f)$(<"$BREE_HISTORY_FILE")}")
            if (( ${#lines} > SAVEHIST )); then
                print -rl -- "${(@)lines[-SAVEHIST,-1]}" >| "$BREE_HISTORY_FILE"
            fi
            builtin fc -R "$BREE_HISTORY_FILE"
        fi
        # Anything already in the list came from a file, not from this
        # terminal's prompt; start recording after it.
        entry="$(builtin fc -l -1 2>/dev/null)"
        [[ "$entry" =~ '^ *([0-9]+)' ]] && typeset -g _BREE_HISTORY_LAST="$match[1]"
        return 0
    fi
    entry="$(builtin fc -l -1 2>/dev/null)"
    [[ "$entry" =~ '^ *([0-9]+)\*? +(.*)$' ]] || return 0
    [[ "$match[1]" != "${_BREE_HISTORY_LAST:-}" ]] || return 0
    typeset -g _BREE_HISTORY_LAST="$match[1]"
    # hist_ignore_space leaves the last such line in the list until the next
    # command; it was never meant to be kept, so it is not recorded either.
    local line="$(builtin fc -ln -1 2>/dev/null)"
    [[ -o hist_ignore_space && "$line" == ' '* ]] && return 0
    print -r -- "$line" >> "$BREE_HISTORY_FILE"
}

_bree_precmd() {
    local last_status=$?
    _bree_terminal_history_precmd
    # Ghostty integration can initialize after this file, so retry its job-table
    # guards when each prompt begins.
    _bree_patch_ghostty_job_table_guard
    _bree_stop_git_head_watch
    _bree_zsh_job_table_saturated && return 0

    _bree_normalize_claude_config_dir
    if (( _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT )); then
        _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=0
    fi
    _bree_tmux_sync_bree_environment

    local bree_has_unix_socket=0
    _bree_socket_is_unix && bree_has_unix_socket=1
    (( bree_has_unix_socket )) || _bree_has_port_scan_transport || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0
    if [[ -n "$BREE_PANEL_ID" ]]; then
        _bree_reset_terminal_keyboard_protocols
    fi
    if [[ -n "$BREE_PANEL_ID" ]] || (( ! bree_has_unix_socket )); then
        _bree_report_shell_activity_state prompt
    fi

    if [[ -z "$_BREE_TTY_NAME" ]]; then
        # zsh already knows its terminal in $TTY; only spawn tty(1) without it.
        local t="${TTY:-}"
        [[ -n "$t" ]] || t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _BREE_TTY_NAME="$t"
    fi

    _bree_report_tty_once

    local now="${EPOCHSECONDS:-$SECONDS}"
    local cmd_start="$_BREE_CMD_START"
    _BREE_CMD_START=0
    local pwd="$PWD"
    local cmd_dur=0
    if [[ -n "$cmd_start" && "$cmd_start" != 0 ]]; then
        cmd_dur=$(( now - cmd_start ))
    fi

    if (( ! bree_has_unix_socket )); then
        if [[ "$pwd" != "$_BREE_PWD_LAST_PWD" ]]; then
            _bree_report_pwd_via_relay "$pwd" && _BREE_PWD_LAST_PWD="$pwd"
        fi
    else
        [[ -n "$BREE_PANEL_ID" ]] || return 0
    fi

    _bree_set_git_active_pwd "$pwd" create

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_BREE_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
            _BREE_GIT_JOB_PID=""
            _BREE_GIT_JOB_STARTED_AT=0
        elif (( _BREE_GIT_JOB_STARTED_AT > 0 )) && (( now - _BREE_GIT_JOB_STARTED_AT >= _BREE_ASYNC_JOB_TIMEOUT )); then
            _BREE_GIT_JOB_PID=""
            _BREE_GIT_JOB_STARTED_AT=0
            _BREE_GIT_FORCE=1
        fi
    fi

    # CWD: keep the app in sync with the actual shell directory.
    # This is also the simplest way to test sidebar directory behavior end-to-end.
    if (( bree_has_unix_socket )) && [[ "$pwd" != "$_BREE_PWD_LAST_PWD" ]]; then
        _BREE_PWD_LAST_PWD="$pwd"
        local qpwd="${pwd//\"/\\\"}"
        _bree_send_bg "report_pwd \"${qpwd}\" --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
    fi

    # Git branch/dirty: update immediately on directory change, otherwise every ~3s.
    # While a foreground command is running, _bree_start_git_head_watch probes HEAD
    # once per second so agent-initiated git checkouts still surface quickly.
    local should_git=0
    local git_head_changed=0

    # Git branch can change without a `git ...`-prefixed command (aliases like `gco`,
    # tools like `gh pr checkout`, etc.). Detect HEAD changes and force a refresh.
    if [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]]; then
        _bree_stop_git_head_watch
        if [[ -n "$_BREE_GIT_JOB_PID" ]] && kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
            kill "$_BREE_GIT_JOB_PID" >/dev/null 2>&1 || true
        fi
        _BREE_GIT_JOB_PID=""
        _BREE_GIT_JOB_STARTED_AT=0
        _BREE_GIT_FORCE=0
        _BREE_GIT_HEAD_LAST_PWD=""
        _BREE_GIT_HEAD_PATH=""
        _BREE_GIT_HEAD_SIGNATURE=""
        _BREE_GIT_LAST_PWD=""
    else
        if [[ "$pwd" != "$_BREE_GIT_HEAD_LAST_PWD" ]]; then
            _BREE_GIT_HEAD_LAST_PWD="$pwd"
            local REPLY
            _bree_git_resolve_head_path_into_reply "$pwd" 2>/dev/null || true
            _BREE_GIT_HEAD_PATH="$REPLY"
            _BREE_GIT_HEAD_SIGNATURE=""
        fi
        if [[ -n "$_BREE_GIT_HEAD_PATH" ]]; then
            # Read HEAD in place; a command substitution here forked every prompt.
            local head_signature=""
            if [[ -r "$_BREE_GIT_HEAD_PATH" ]]; then
                IFS= read -r head_signature < "$_BREE_GIT_HEAD_PATH" 2>/dev/null || head_signature=""
            fi
            if [[ -n "$head_signature" ]]; then
                if [[ -z "$_BREE_GIT_HEAD_SIGNATURE" ]]; then
                    # The first observed HEAD value establishes the baseline for this
                    # shell session. Don't treat it as a branch change or we'll clear
                    # restore-seeded state before the first background probe runs.
                    _BREE_GIT_HEAD_SIGNATURE="$head_signature"
                elif [[ "$head_signature" != "$_BREE_GIT_HEAD_SIGNATURE" ]]; then
                    _BREE_GIT_HEAD_SIGNATURE="$head_signature"
                    git_head_changed=1
                    # Treat HEAD file change like a git command — force-replace any
                    # running probe so the sidebar picks up the new branch immediately.
                    _BREE_GIT_FORCE=1
                    should_git=1
                fi
            fi
        fi
    fi

    if [[ "$pwd" != "$_BREE_GIT_LAST_PWD" ]]; then
        should_git=1
    elif (( _BREE_GIT_FORCE )); then
        should_git=1
    elif (( now - _BREE_GIT_LAST_RUN >= 3 )); then
        should_git=1
    fi

    if [[ "${BREE_NO_GIT_WATCH:-}" != "1" ]] && (( should_git )); then
        local can_launch_git=1
        if [[ -n "$_BREE_GIT_JOB_PID" ]] && kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
            # If a stale probe is still running but the cwd changed (or we just ran
            # a git command), restart immediately so branch state isn't delayed
            # until the next user command/prompt.
            # Note: this repeats the cwd check above on purpose. The first check
            # decides whether we should refresh at all; this one decides whether
            # an in-flight older probe can be reused vs. replaced.
            if [[ "$pwd" != "$_BREE_GIT_LAST_PWD" ]] || (( _BREE_GIT_FORCE )); then
                kill "$_BREE_GIT_JOB_PID" >/dev/null 2>&1 || true
                _BREE_GIT_JOB_PID=""
                _BREE_GIT_JOB_STARTED_AT=0
            else
                can_launch_git=0
            fi
        fi

        if (( can_launch_git )); then
            _BREE_GIT_FORCE=0
            _BREE_GIT_LAST_PWD="$pwd"
            _BREE_GIT_LAST_RUN=$now
            {
                _bree_report_git_branch_for_path "$pwd"
            } >/dev/null 2>&1 &!
            _BREE_GIT_JOB_PID=$!
            _BREE_GIT_JOB_STARTED_AT=$now
        fi
    fi
    # Ports: lightweight kick to the app's batched scanner.
    # - Periodic scan to avoid stale values.
    # - Forced scan when a long-running command returns to the prompt (common when stopping a server).
    if (( cmd_dur >= 2 || now - _BREE_PORTS_LAST_RUN >= 10 )); then
        _bree_ports_kick refresh
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI bree binary cannot shadow the CLI bree.
# Shell init (.zprofile/.zshrc) may prepend other dirs after launch.
# We fix this once on first prompt (after all init files have run), and
# reinstall bree-owned wrapper functions in case user startup replaced them.
_bree_fix_path() {
    local integration_dir="${BREE_SHELL_INTEGRATION_DIR:-}"
    integration_dir="${integration_dir%/}"
    if [[ "$integration_dir" == */Resources/shell-integration ]]; then
        local resources_dir="${integration_dir%/shell-integration}"
        local gui_dir="${resources_dir%/Resources}/MacOS"
        local bin_dir="$resources_dir/bin"
        if [[ -d "$bin_dir" ]]; then
            local REPLY
            _bree_path_prepend_unique_directory_into_reply "$bin_dir" "${PATH-}" "$gui_dir"
            PATH="$REPLY"
        fi
    fi
    _bree_install_cli_wrapper claude _BREE_CLAUDE_WRAPPER bree-claude-wrapper
    _bree_install_cli_wrapper grok _BREE_GROK_WRAPPER
    add-zsh-hook -d precmd _bree_fix_path
}

_bree_chpwd() {
    # Only refresh the active-cwd marker so async git reporters (the HEAD-watch
    # loop and deferred prompt probes) are scoped to the new cwd. Do NOT tear the
    # HEAD watch down here: chpwd fires mid-line for compound commands such as
    # `cd foo && pnpm dev`, and killing the watcher would drop live branch updates
    # during the long-running step. The marker guard already suppresses any stale
    # report for the path the shell just left, and precmd stops the watch at the
    # next prompt.
    _bree_set_git_active_pwd "$PWD"
}

_bree_restore_terminal_identity_after_startup() {
    if [[ -n "${BREE_ZSH_RESTORE_TERM:-}" ]]; then
        builtin export TERM="$BREE_ZSH_RESTORE_TERM"
        builtin unset BREE_ZSH_RESTORE_TERM
    fi
    _BREE_DELAY_TERM_RESTORE_UNTIL_FIRST_PROMPT=0
}

_bree_zshexit() {
    _bree_stop_git_head_watch
    [[ -n "${_BREE_GIT_ACTIVE_PWD_FILE:-}" ]] && /bin/rm -f -- "$_BREE_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 || true
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _bree_preexec
add-zsh-hook precmd _bree_precmd
add-zsh-hook precmd _bree_fix_path
add-zsh-hook chpwd _bree_chpwd
add-zsh-hook zshexit _bree_zshexit

# --- Warp-style clean grid ----------------------------------------------------
#
# Only when the docked shell editor owns input (the app exports
# BREE_SHELL_EDITOR=1 at spawn). The grid shows no prompt: PS1/RPROMPT/
# PROMPT_EOL_MARK are empty, the first prompt wipes the screen and scrollback
# ("Last login", startup noise) and parks the cursor on the last row so output
# grows from the bottom. When a line is accepted, the accept-line widget swaps
# in a one-shot prompt (blank separator line, dim cwd + branch header) and
# redraws, so the header lands above the typed command. Ghostty's OSC 133 marks
# still ride in PS1 because our hook runs just before _ghostty_precmd.
# The terminal cursor is hidden at precmd and shown at preexec; the app writes
# ESC[?25h / ESC[?25l to the pty on the raw-mode toggle (no shell round trip).

typeset -g _BREE_CLEAN_FIRST=1 _BREE_CLEAN_BLOCKS=0 _BREE_CLEAN_HDR_SET=0 _BREE_CLEAN_ATTOP=0
typeset -gi _BREE_CLEAN_ID=0
typeset -g _BREE_CLEAN_LAST_HDR=''

_bree_clean_accept_line() {
    if (( ! _BREE_CLEAN_HDR_SET )) && [[ -z "$PREBUFFER" && "$BUFFER" == *[^[:space:]]* ]]; then
        _BREE_CLEAN_HDR_SET=1
        local cwd="${(%):-%~}" branch="" head
        local REPLY
        if _bree_git_resolve_head_path_into_reply "$PWD" && [[ -r "$REPLY" ]]; then
            head="$(<"$REPLY")"
            [[ "$head" == "ref: refs/heads/"* ]] && branch="  ${head#ref: refs/heads/}"
        fi
        # Header only when cwd/branch differ from the previous block's.
        local hdr=""
        if [[ "${cwd}${branch}" != "$_BREE_CLEAN_LAST_HDR" ]]; then
            _BREE_CLEAN_LAST_HDR="${cwd}${branch}"
            hdr=$'%{\e[2m%}'"${cwd//\%/%%}${branch//\%/%%}"$'%{\e[0m%}\n'
        fi
        # Block marker row, one concealed run of box-drawing glyphs: sentinel ╶╴, kind
        # (─ divider, ╴ first block, no divider), then the block id in base 4 over ─╴╶╌
        # (0..3, most significant first). No letters or digits, so Find never matches it.
        # The app draws the full-width divider, failure rail and result badge from it.
        (( ++_BREE_CLEAN_ID ))
        local mark='─'; (( _BREE_CLEAN_BLOCKS )) || mark='╴'
        local -a _g=('─' '╴' '╶' '╌'); local enc='' n=$_BREE_CLEAN_ID
        while (( n > 0 )); do enc="${_g[$(( n % 4 + 1 ))]}${enc}"; n=$(( n / 4 )); done
        hdr=$'%{\e[2;8m'"╶╴${mark}${enc}"$'\e[0m%}\n'"$hdr"
        PS1="${hdr}${PS1}%B"
        zle reset-prompt
    fi
    zle _bree_clean_orig_accept_line
}

_bree_clean_clear_screen() {
    _BREE_CLEAN_BLOCKS=0 _BREE_CLEAN_LAST_HDR=''
    # Not `.clear-screen`: it redraws from the top, so zle would then move up
    # from the wrong row. The prompt is empty, so a plain reset-prompt is enough.
    builtin print -rn -- $'\e[H\e[2J\e[999;1H'
    zle reset-prompt
}

_bree_clean_precmd() {
    local last_status=$?
    # Sit right before Ghostty's hook so its marks wrap our empty PS1.
    local -a pf=(${precmd_functions:#_bree_clean_precmd})
    local i=${pf[(i)_ghostty_deferred_init]}
    (( i > ${#pf} )) && i=${pf[(i)_ghostty_precmd]}
    pf=("${(@)pf[1,i-1]}" _bree_clean_precmd "${(@)pf[i,-1]}")
    [[ "${(j: :)precmd_functions}" == "${(j: :)pf}" ]] || precmd_functions=("${pf[@]}")

    PS1='' PS2='' RPROMPT='' RPS1='' PROMPT_EOL_MARK=''
    _BREE_CLEAN_HDR_SET=0
    # The editor draws its own caret; hide the terminal's block at the idle
    # prompt (preexec shows it again so programs keep theirs).
    builtin print -rn -- $'\e[?25l'
    if (( _BREE_CLEAN_FIRST )); then
        _BREE_CLEAN_FIRST=0
        # Second pass for the real widgets: user config has loaded by now.
        if [[ -o zle ]]; then
            zle -A accept-line _bree_clean_orig_accept_line
            zle -N accept-line _bree_clean_accept_line
            zle -N clear-screen _bree_clean_clear_screen
        fi
        builtin print -rn -- $'\e[H\e[2J\e[3J'
        _BREE_CLEAN_ATTOP=1
    fi
    if (( _BREE_CLEAN_ATTOP )); then
        _BREE_CLEAN_ATTOP=0
        # CUP clamps to the last row, so a stale LINES or a resize cannot misplace it.
        builtin print -rn -- $'\e[999;1H'
    fi
    return $last_status
}

_bree_clean_preexec() {
    builtin print -rn -- $'\e[0m\e[?25h'
    (( _BREE_CLEAN_BLOCKS++ ))
    local -a words=(${(z)3})
    if [[ "${words[1]}" == (clear|reset) ]]; then
        _BREE_CLEAN_BLOCKS=0 _BREE_CLEAN_LAST_HDR=''
        _BREE_CLEAN_ATTOP=1
    fi
}

if [[ "${BREE_SHELL_EDITOR:-}" == 1 && -o interactive && -z "${SSH_CONNECTION:-}" ]]; then
    add-zsh-hook preexec _bree_clean_preexec
    # Prepended (not add-zsh-hook) so the very first prompt also runs ahead of
    # Ghostty's deferred init; the hook then keeps itself just before it.
    builtin typeset -ag precmd_functions
    precmd_functions=(_bree_clean_precmd "${precmd_functions[@]}")
fi

# --- Completion popup buffer pull and inline suggestions ---------------------
#
# The app's Tab popup asks the shell for its exact line by writing the private
# sequence ESC [ 999<digit> ~ (no terminal emits it; the digit is a request
# token the reply echoes). The widgets below answer over the same socket the
# shell-state reports use, and only after announcing report_completion_ready,
# so a shell without them never receives the sequence. They do not touch
# BUFFER and do not redraw. The buffer and $PWD travel base64 encoded and are
# never interpolated into shell code.
#
# Bound at the first prompt: key maps and plugins load after this file.

_bree_completion_report() {
    local token="$1" buf="$BUFFER" cur="$CURSOR" cwd="$PWD"
    [[ -n "$BREE_TAB_ID" && -n "$BREE_PANEL_ID" ]] || return 0
    _bree_socket_is_unix || return 0
    _bree_zsh_job_table_saturated && return 0
    {
        local b p
        b="$(builtin printf '%s' "$buf" | command base64 | command tr -d '\n\r')"
        p="$(builtin printf '%s' "$cwd" | command base64 | command tr -d '\n\r')"
        _bree_send "report_completion_buffer $token $cur ${p:--} ${b:--} --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
    } >/dev/null 2>&1 &!
    return 0
}

# Inline history suggestion (fish style), shown dim after the cursor; Right
# Arrow or End at the end of the line accepts it. The history lookup and the
# POSTDISPLAY/region_highlight handling follow zsh-autosuggestions
# (https://github.com/zsh-users/zsh-autosuggestions, MIT, Eric Freese et al.).

typeset -g _BREE_SUGGEST_HL=""

# Sets REPLY to the most recent history line that starts with $1 and is
# longer. No subshell: this runs on every redraw.
_bree_suggest_pick() {
    emulate -L zsh
    setopt extendedglob
    local buf="$1"
    REPLY=""
    [[ -n "$buf" ]] || return 1
    local prefix="${buf//(#m)[\\*?[\]<>()|^~#]/\\$MATCH}"
    local match="${history[(r)${prefix}*]}"
    [[ -n "$match" && "$match" != "$buf" && "$match" != *$'\n'* ]] || return 1
    REPLY="$match"
}

_bree_suggest_clear() {
    if [[ -n "$_BREE_SUGGEST_HL" ]]; then
        region_highlight=("${(@)region_highlight:#${_BREE_SUGGEST_HL}}")
        _BREE_SUGGEST_HL=""
    fi
    POSTDISPLAY=""
}

_bree_suggest_redraw() {
    _bree_suggest_clear
    (( CURSOR == ${#BUFFER} )) || return 0
    local REPLY
    _bree_suggest_pick "$BUFFER" || return 0
    POSTDISPLAY="${REPLY:${#BUFFER}}"
    _BREE_SUGGEST_HL="P$(( ${#PREDISPLAY} + ${#BUFFER} )) $(( ${#PREDISPLAY} + ${#BUFFER} + ${#POSTDISPLAY} )) fg=8"
    region_highlight+=("$_BREE_SUGGEST_HL")
}

# Accepts the suggestion when the caret is at the end of the buffer, else runs
# the builtin widget named in $1.
_bree_suggest_accept_or() {
    if (( ${#POSTDISPLAY} && CURSOR == ${#BUFFER} )); then
        BUFFER+="$POSTDISPLAY"
        _bree_suggest_clear
        CURSOR=${#BUFFER}
    else
        zle ".$1"
    fi
}
_bree_suggest_forward_char() { _bree_suggest_accept_or forward-char; }
_bree_suggest_end_of_line() { _bree_suggest_accept_or end-of-line; }

_bree_suggest_setup() {
    [[ "${BREE_INLINE_SUGGESTIONS:-1}" == "0" ]] && return 0
    # zsh-autosuggestions (or any plugin providing the same function) owns it.
    (( $+functions[_zsh_autosuggest_start] )) && return 0
    autoload -Uz is-at-least add-zle-hook-widget 2>/dev/null || return 0
    is-at-least 5.4 || return 0
    zmodload zsh/zleparameter 2>/dev/null || return 0
    add-zle-hook-widget line-pre-redraw _bree_suggest_redraw
    add-zle-hook-widget line-finish _bree_suggest_clear
    local w
    for w in forward-char end-of-line; do
        # Only wrap the stock widget; a user's own override stays untouched.
        [[ "${widgets[$w]:-builtin}" == builtin ]] || continue
        zle -N "$w" "_bree_suggest_${w//-/_}"
    done
    local km seq
    for km in emacs viins; do
        for seq in $'\e[C' $'\eOC'; do
            [[ "$(bindkey -M "$km" "$seq" 2>/dev/null)" == *undefined-key* ]] \
                && bindkey -M "$km" "$seq" forward-char
        done
    done
}

# Shell editor submit: the app clears the line with ESC [ 9980 ~ before it
# pastes the editor's text, so typed-ahead characters cannot mix in.
_bree_kill_buffer() {
    BUFFER=""
    CURSOR=0
    [[ "$KEYMAP" == vicmd ]] && zle -K viins
    return 0
}

_bree_completion_setup() {
    add-zsh-hook -d precmd _bree_completion_setup
    [[ -o zle ]] || return 0
    (( ${+functions} )) || return 0
    local d km
    for d in 0 1 2 3 4 5 6 7 8 9; do
        functions[_bree_completion_request_$d]="_bree_completion_report $d"
        zle -N "_bree_completion_request_$d"
        for km in emacs viins vicmd; do
            bindkey -M "$km" $'\e[999'"$d"$'~' "_bree_completion_request_$d"
        done
    done
    zle -N _bree_kill_buffer
    for km in emacs viins vicmd; do
        bindkey -M "$km" $'\e[9980~' _bree_kill_buffer
    done
    _bree_suggest_setup
    add-zsh-hook precmd _bree_completion_announce
    _bree_completion_announce
}

# The app forgets a panel's readiness whenever a command starts (a different
# shell may be about to take the prompt), so every prompt re-announces it.
_bree_completion_announce() {
    _bree_socket_is_unix && [[ -n "$BREE_TAB_ID" && -n "$BREE_PANEL_ID" ]] || return 0
    _bree_send_bg "report_completion_ready --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID" || true
}
add-zsh-hook precmd _bree_completion_setup
