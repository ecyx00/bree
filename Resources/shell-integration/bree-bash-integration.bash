# bree shell integration for bash

# Cache which send tool is available to avoid repeated PATH lookups.
_BREE_SEND_TOOL=""
_bree_detect_send_tool() {
    if command -v ncat >/dev/null 2>&1; then
        _BREE_SEND_TOOL=ncat
    elif command -v socat >/dev/null 2>&1; then
        _BREE_SEND_TOOL=socat
    elif command -v nc >/dev/null 2>&1; then
        _BREE_SEND_TOOL=nc
    fi
}
# Detection deferred to after _bree_fix_path (end of file).

# Present the signed capability inherited by every bree-created terminal. This
# keeps detached reporters authorized after launchd or tmux reparents them.
_bree_write_socket_payload() {
    local payload="$1"
    case "${BREE_SOCKET_CAPABILITY:-}" in
        ""|*[[:space:]]*)
            printf '%s\n' "$payload"
            ;;
        *)
            printf '_bree_capability_v1 %s %s\n' "$BREE_SOCKET_CAPABILITY" "$payload"
            ;;
    esac
}

_bree_send() {
    local payload="$1"
    if [[ -x /usr/bin/nc ]]; then
        # Apple's nc defines -N as a value-taking adaptive write timeout, not
        # OpenBSD's no-argument shutdown-after-EOF flag. Use the bounded form
        # directly and wait for bree's response so ordered batches stay ordered.
        _bree_write_socket_payload "$payload" | /usr/bin/nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1 || true
        return 0
    fi
    case "$_BREE_SEND_TOOL" in
        ncat)
            _bree_write_socket_payload "$payload" | ncat -w 1 -U "$BREE_SOCKET_PATH" --send-only
            ;;
        socat)
            _bree_write_socket_payload "$payload" | socat -T 1 - "UNIX-CONNECT:$BREE_SOCKET_PATH" >/dev/null 2>&1
            ;;
        nc)
            if _bree_write_socket_payload "$payload" | nc -N -U "$BREE_SOCKET_PATH" >/dev/null 2>&1; then
                :
            else
                _bree_write_socket_payload "$payload" | nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1 || true
            fi
            ;;
    esac
}

_bree_detach_bg() {
    ( "$@" >/dev/null 2>&1 & ) >/dev/null 2>&1
}

_bree_send_bg() {
    local payload="$1"
    if [[ "${_BREE_IN_PREEXEC:-}" == "1" ]]; then
        {
            _bree_send "$payload"
        } >/dev/null 2>&1 &
        disown
        return 0
    fi
    _bree_detach_bg _bree_send "$payload"
}

_bree_start_tracked_bg() {
    local __pid_var="$1"
    shift
    local __pid=""
    # The job's stdout goes to /dev/null, so the substitution returns as soon
    # as the subshell prints the pid, without a scratch file.
    __pid="$(
        "$@" >/dev/null 2>&1 &
        printf '%s' "$!"
    )"
    printf -v "$__pid_var" '%s' "$__pid"
}

_bree_socket_is_unix() {
    [[ -n "$BREE_SOCKET_PATH" && -S "$BREE_SOCKET_PATH" ]]
}

_bree_relay_cli_path() {
    if [[ -n "${BREE_BUNDLED_CLI_PATH:-}" && -x "${BREE_BUNDLED_CLI_PATH}" ]]; then
        printf '%s\n' "${BREE_BUNDLED_CLI_PATH}"
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
    printf '%s\n' "$value"
}

_bree_relay_rpc_bg() {
    local method="$1"
    local params="$2"
    local relay_cli=""
    _bree_socket_uses_remote_relay || return 1
    relay_cli="$(_bree_relay_cli_path)" || return 1
    _bree_detach_bg "$relay_cli" rpc "$method" "$params"
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
        printf '%s\n' "$BREE_WORKSPACE_ID"
        return 0
    fi
    [[ -n "$BREE_TAB_ID" ]] || return 1
    printf '%s\n' "$BREE_TAB_ID"
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
    local token="${path##*/}"

    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/start\007' "$HOSTNAME" "$token"

    if [[ -r "$path" ]]; then
        /bin/cat -- "$path" 2>/dev/null || true
        /bin/rm -f -- "$path" >/dev/null 2>&1 || true
    fi

    # Valid kitty-shell-cwd URIs reach Ghostty's PWD action in PTY order. The
    # following real cwd report keeps the private boundary out of title state.
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/end\007' "$HOSTNAME" "$token"
    builtin printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$HOSTNAME" "$PWD"
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
_BREE_CLAUDE_WRAPPER="${_BREE_CLAUDE_WRAPPER:-}"
_BREE_GROK_WRAPPER="${_BREE_GROK_WRAPPER:-}"
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
    local create="$1"
    shift
    (( $# )) || return 1
    local dir
    for dir in "$@"; do
        [[ "$dir" == /* ]] || return 1
        # A directory mkdir just created is ours and already 0700.
        if [[ "$create" == 1 && ! -e "$dir" && ! -L "$dir" ]] \
            && ! /bin/mkdir -m 700 -- "$dir" >/dev/null 2>&1; then
            return 1
        fi
        [[ -d "$dir" && ! -L "$dir" && -O "$dir" ]] || return 1
        # Bash can't read mode bits; find's -type d uses lstat here.
        [[ "$(/usr/bin/find "$dir" -prune -type d ! -perm -020 ! -perm -002 -print 2>/dev/null)" == "$dir" ]] || return 1
        _bree_private_path_chain "$dir" || return 1
    done
}

_bree_private_path_chain() {
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
    local current="$1"
    while true; do
        _bree_private_path_node "$current" || return 1
        [[ "$current" == "/" ]] && return 0
        current="${current%/*}"
        [[ -n "$current" ]] || current="/"
    done
}

_bree_private_path_node() {
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
_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED=""
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
                hash -r >/dev/null 2>&1 || true
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
    # `>|` forces the truncate so bree can always refresh its own generated
    # shim, even when the user's interactive bash has `noclobber` set. A plain
    # `>` is refused under noclobber and prints `cannot overwrite existing file`
    # on every prompt (the redirect failure is reported by the shell, so the
    # `2>/dev/null` on the compound command does not suppress it).
    } >|"$shim_path" 2>/dev/null || return 0
    /bin/chmod 0700 "$shim_path" >/dev/null 2>&1 || return 0

    if [[ "$command_name" == "claude" ]]; then
        export BREE_CLAUDE_WRAPPER_SHIM="$shim_path"
        export BREE_CLAUDE_WRAPPER_SHIM_ROOT="$shim_root"
        _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED="$shim_path"
    fi

    _bree_path_prepend_unique_directory_into_reply "$shim_root" "${PATH-}" "$rejected_root"
    PATH="$REPLY"
    hash -r >/dev/null 2>&1 || true
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
    local existing_type=""
    [[ -n "$integration_dir" ]] || return 0

    integration_dir="${integration_dir%/}"
    local bundle_dir="${integration_dir%/shell-integration}"
    local wrapper_path="$bundle_dir/bin/$wrapper_file"
    [[ -x "$wrapper_path" ]] || return 0

    existing_type="$(type -t "$command_name" 2>/dev/null || true)"
    printf -v "$wrapper_variable" '%s' "$wrapper_path"
    if [[ "$command_name" == "claude" ]]; then
        _bree_install_cli_command_shim "$command_name" "$wrapper_path"
    fi
    case "$existing_type" in
        alias|function)
            return 0
            ;;
    esac

    # Keep the bundled wrapper ahead of later PATH mutations. Install it
    # via eval so an existing alias cannot break parsing.
    unalias "$command_name" >/dev/null 2>&1 || true
    if [[ "$command_name" == "claude" ]]; then
        eval "$command_name() { _bree_claude_wrapper_command \"\$@\"; }"
    else
        eval "$command_name() { \"\${$wrapper_variable}\" \"\$@\"; }"
    fi
}
_bree_install_cli_wrapper claude _BREE_CLAUDE_WRAPPER bree-claude-wrapper
_bree_install_cli_wrapper grok _BREE_GROK_WRAPPER

# Throttle heavy work to avoid prompt latency.
_BREE_PWD_LAST_PWD="${_BREE_PWD_LAST_PWD:-}"
_BREE_GIT_LAST_PWD="${_BREE_GIT_LAST_PWD:-}"
_BREE_GIT_LAST_RUN="${_BREE_GIT_LAST_RUN:-0}"
_BREE_GIT_JOB_PID="${_BREE_GIT_JOB_PID:-}"
_BREE_GIT_JOB_STARTED_AT="${_BREE_GIT_JOB_STARTED_AT:-0}"
_BREE_GIT_HEAD_LAST_PWD="${_BREE_GIT_HEAD_LAST_PWD:-}"
_BREE_GIT_HEAD_PATH="${_BREE_GIT_HEAD_PATH:-}"
_BREE_GIT_HEAD_SIGNATURE="${_BREE_GIT_HEAD_SIGNATURE:-}"
# Created on first use by _bree_set_git_active_pwd, and only while git watching
# is on: the git reporters are its only readers.
_BREE_GIT_ACTIVE_PWD_FILE="${_BREE_GIT_ACTIVE_PWD_FILE:-}"
_BREE_ASYNC_JOB_TIMEOUT="${_BREE_ASYNC_JOB_TIMEOUT:-20}"
# The history file outlives the subshells that write them, so they
# live in a private per-user directory. Without one they are not used.
_BREE_BASH_STATE_DIR="${TMPDIR:-/tmp}"
_BREE_BASH_STATE_DIR="${_BREE_BASH_STATE_DIR%/}/bree-bash-$EUID"
_bree_private_dirs 1 "$_BREE_BASH_STATE_DIR" || _BREE_BASH_STATE_DIR=""
_BREE_BASH_HISTORY_LAST_FILE=""
if [[ -n "$_BREE_BASH_STATE_DIR" ]]; then
    _BREE_BASH_HISTORY_LAST_FILE="$_BREE_BASH_STATE_DIR/history-last-$$"
fi

_BREE_PORTS_LAST_RUN="${_BREE_PORTS_LAST_RUN:-0}"
_BREE_SHELL_ACTIVITY_LAST="${_BREE_SHELL_ACTIVITY_LAST:-}"
_BREE_TTY_NAME="${_BREE_TTY_NAME:-}"
_BREE_TTY_REPORTED="${_BREE_TTY_REPORTED:-0}"
_BREE_TMUX_PUSH_SIGNATURE="${_BREE_TMUX_PUSH_SIGNATURE:-}"
_BREE_TMUX_PULL_SIGNATURE="${_BREE_TMUX_PULL_SIGNATURE:-}"
# Keep BREE_SOCKET_CAPABILITY inherited; tmux's global environment is readable
# by clients that were not started inside bree.
_BREE_TMUX_SYNC_KEYS=(
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
_BREE_TMUX_SURFACE_SCOPED_KEYS=(
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
    local key value first=1
    REPLY=""
    for key in "${_BREE_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
        [[ -n "$value" ]] || continue
        if (( first )); then
            REPLY="$key=$value"
            first=0
        else
            REPLY+=$'\037'"$key=$value"
        fi
    done
}

_bree_tmux_shell_env_signature() {
    local REPLY
    _bree_tmux_shell_env_signature_into_reply
    printf '%s' "$REPLY"
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
    if [[ -e "$stale_marker" ]] && ! [[ "$server_socket" -nt "$stale_marker" ]]; then
        return 0
    fi

    _bree_tmux_shell_env_signature_into_reply
    local signature="$REPLY"
    [[ -n "$signature" ]] || return 0
    [[ "$signature" == "$_BREE_TMUX_PUSH_SIGNATURE" ]] && return 0

    local key value tmux_error
    for key in "${_BREE_TMUX_SYNC_KEYS[@]}"; do
        value="${!key}"
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
    command -v tmux >/dev/null 2>&1 || return 0

    local output filtered line key value did_change=0
    for key in "${_BREE_TMUX_SURFACE_SCOPED_KEYS[@]}"; do
        if [[ -n "${!key}" ]]; then
            unset "$key"
            did_change=1
        fi
    done

    output="$(tmux show-environment 2>/dev/null)" || return 0

    while IFS= read -r line; do
        [[ "$line" == BREE_* ]] || continue
        key="${line%%=*}"
        _bree_tmux_sync_key_is_managed "$key" || continue
        filtered+="${line}"$'\n'
    done <<< "$output"

    [[ -n "$filtered" ]] || return 0
    [[ "$filtered" == "$_BREE_TMUX_PULL_SIGNATURE" ]] && (( ! did_change )) && return 0

    while IFS= read -r line; do
        [[ "$line" == BREE_* ]] || continue
        key="${line%%=*}"
        _bree_tmux_sync_key_is_managed "$key" || continue
        value="${line#*=}"
        if [[ "${!key}" != "$value" ]]; then
            printf -v "$key" '%s' "$value"
            export "$key"
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
    fi
}

_bree_tmux_sync_bree_environment() {
    if [[ -n "$TMUX" ]]; then
        _bree_tmux_refresh_bree_environment
    else
        _bree_tmux_publish_bree_environment
    fi
}

# Resolve the HEAD file path without invoking git (fast; works for worktrees).
# Sets REPLY (empty when not in a repository) so prompt hooks need no subshell,
# and walks up with parameter expansion instead of spawning dirname per level.
_bree_git_resolve_head_path_into_reply() {
    REPLY=""
    local dir="${1:-$PWD}"
    local parent
    while :; do
        if [[ -d "$dir/.git" ]]; then
            REPLY="$dir/.git/HEAD"
            return 0
        fi
        if [[ -f "$dir/.git" ]]; then
            local line gitdir
            IFS= read -r line < "$dir/.git" || line=""
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
        case "$dir" in
            */*)
                parent="${dir%/*}"
                [[ -n "$parent" ]] || parent="/"
                ;;
            *) parent="." ;;
        esac
        [[ "$parent" == "$dir" ]] && break
        dir="$parent"
    done
    return 1
}

_bree_git_resolve_head_path() {
    local REPLY
    _bree_git_resolve_head_path_into_reply "$@" || return 1
    printf '%s\n' "$REPLY"
}

_bree_git_branch_for_path() {
    local repo_path="$1"
    local head_path="" head_line="" prefix="ref: refs/heads/"
    head_path="$(_bree_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    [[ -n "$head_path" && -r "$head_path" ]] || return 1
    IFS= read -r head_line < "$head_path" || return 1
    [[ "$head_line" == "$prefix"* ]] || return 1
    printf '%s\n' "${head_line#$prefix}"
}

_bree_set_git_active_pwd() {
    local active_pwd="$1"
    [[ -n "$active_pwd" ]] || return 0
    if [[ -z "${_BREE_GIT_ACTIVE_PWD_FILE:-}" ]]; then
        [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]] && return 0
        _BREE_GIT_ACTIVE_PWD_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/bree-git-active-pwd.XXXXXX" 2>/dev/null)"
        [[ -n "$_BREE_GIT_ACTIVE_PWD_FILE" ]] || return 0
    fi
    printf '%s\n' "$active_pwd" >| "$_BREE_GIT_ACTIVE_PWD_FILE" 2>/dev/null || true
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
    # in-repo `cd pkg` while still dropping a report once the shell has left the
    # repo entirely (the stale-branch case). Resolve both HEAD paths without
    # invoking git and compare.
    local repo_head active_head
    repo_head="$(_bree_git_resolve_head_path "$repo_path" 2>/dev/null || true)"
    active_head="$(_bree_git_resolve_head_path "$active_pwd" 2>/dev/null || true)"
    [[ -n "$repo_head" && "$repo_head" == "$active_head" ]]
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

_bree_report_tty_payload() {
    [[ -n "$BREE_TAB_ID" ]] || return 0
    [[ -n "$_BREE_TTY_NAME" ]] || return 0

    local payload="report_tty $_BREE_TTY_NAME --tab=$BREE_TAB_ID"
    if [[ -z "$TMUX" ]]; then
        [[ -n "$BREE_PANEL_ID" ]] || return 0
        payload+=" --panel=$BREE_PANEL_ID"
    fi

    printf '%s\n' "$payload"
}

_bree_report_tty_once() {
    # Send the TTY name to the app once per session so the batched port scanner
    # knows which TTY belongs to this panel.
    (( _BREE_TTY_REPORTED )) && return 0
    _bree_has_port_scan_transport || return 0

    if _bree_socket_is_unix; then
        local payload=""
        payload="$(_bree_report_tty_payload)"
        [[ -n "$payload" ]] || return 0
        _BREE_TTY_REPORTED=1
        _bree_send_bg "$payload"
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
        _bree_send_bg "$payload"
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

# Git filesystem watching belongs to bree's SidebarGitMetadataService.
# Bash reports prompt changes only; do not reintroduce per-pane timer processes.
_bree_bash_cleanup() {
    [[ -n "${_BREE_GIT_ACTIVE_PWD_FILE:-}" ]] && /bin/rm -f -- "$_BREE_GIT_ACTIVE_PWD_FILE" >/dev/null 2>&1 || true
}

_bree_command_starts_nested_shell() {
    local cmd="$1"
    local -a words=()
    read -r -a words <<< "$cmd"

    local index=0
    local word base
    while (( index < ${#words[@]} )); do
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
                while (( index < ${#words[@]} )); do
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

        base="${word##*/}"
        case "$base" in
            bash|zsh|sh|fish|nu|nix-shell)
                return 0 ;;
            nix)
                local next_index=$(( index + 1 ))
                local next_word="${words[next_index]:-}"
                case "$next_word" in
                    develop|shell)
                        return 0 ;;
                esac ;;
        esac

        return 1
    done

    return 1
}

_bree_preexec_command() {
    local cmd="${1:-${BASH_COMMAND:-}}"
    _bree_tmux_sync_bree_environment

    local bree_has_unix_socket=0
    _bree_socket_is_unix && bree_has_unix_socket=1
    (( bree_has_unix_socket )) || _bree_has_port_scan_transport || return 0
    [[ -n "$BREE_TAB_ID" ]] || return 0

    if [[ -z "$_BREE_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ -n "$t" && "$t" != "not a tty" ]] && _BREE_TTY_NAME="$t"
    fi

    _bree_report_shell_activity_state running
    _bree_report_tty_once
    _bree_ports_kick command
    if _bree_command_starts_nested_shell "$cmd"; then
        return 0
    fi
}

_bree_bash_history_command() {
    local HISTTIMEFORMAT=
    [[ -n "${_BREE_BASH_STATE_DIR:-}" ]] || return 1
    local history_file="$_BREE_BASH_STATE_DIR/history-$$-${RANDOM:-0}"
    local line="" history_number="" last_number=""
    builtin history 1 >| "$history_file" 2>/dev/null || {
        /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
        return 1
    }
    IFS= read -r line < "$history_file" || line=""
    /bin/rm -f -- "$history_file" >/dev/null 2>&1 || true
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+(.*)$ ]]; then
        history_number="${BASH_REMATCH[1]}"
        if [[ -n "${_BREE_BASH_HISTORY_LAST_FILE:-}" && -r "$_BREE_BASH_HISTORY_LAST_FILE" ]]; then
            IFS= read -r last_number < "$_BREE_BASH_HISTORY_LAST_FILE" || last_number=""
        fi
        [[ "$history_number" == "$last_number" ]] && return 1
        if [[ -n "${_BREE_BASH_HISTORY_LAST_FILE:-}" ]]; then
            printf '%s\n' "$history_number" >| "$_BREE_BASH_HISTORY_LAST_FILE" 2>/dev/null || true
        fi
        printf '%s\n' "${BASH_REMATCH[2]}"
        return 0
    fi
    return 1
}

_bree_bash_preexec_hook() {
    local cmd="${1:-}"
    local history_cmd=""
    history_cmd="$(_bree_bash_history_command 2>/dev/null || true)"
    if [[ -n "$history_cmd" ]]; then
        cmd="$history_cmd"
    fi
    _bree_preexec_command "$cmd"
}

_bree_bash_preexec_hook_subshell() {
    local _BREE_IN_PREEXEC=1
    _bree_bash_preexec_hook "$@"
}

# Per-terminal history, layered on the shell's own. HISTFILE is left alone,
# so a new terminal recalls global history and every command still reaches
# the global file exactly as it does in any other terminal. Alongside it,
# each command is appended to this surface's file; when a restored terminal
# finds entries there, they are read on top of global history so Up recalls
# what was typed in this terminal first. `history -r` entries are not new to
# this session, so bash's exit-time save never writes them back globally.
_bree_terminal_history_prompt() {
    [[ -n "${BREE_HISTORY_FILE:-}" && -n "${HISTFILE:-}" && "$HISTFILE" != /dev/null ]] || return 0
    local entry
    if [[ -z "${_BREE_HISTORY_INITIALIZED:-}" ]]; then
        _BREE_HISTORY_INITIALIZED=1
        if [[ -s "$BREE_HISTORY_FILE" ]]; then
            local limit="${HISTFILESIZE:-500}"
            if [[ "$limit" =~ ^[0-9]+$ ]] && (( $(wc -l <"$BREE_HISTORY_FILE") > limit )); then
                local trimmed
                trimmed="$(tail -n "$limit" "$BREE_HISTORY_FILE")" \
                    && printf '%s\n' "$trimmed" >"$BREE_HISTORY_FILE"
            fi
            builtin history -r "$BREE_HISTORY_FILE"
        fi
        # Anything already in the list came from a file, not from this
        # terminal's prompt; start recording after it.
        entry="$(HISTTIMEFORMAT= builtin history 1)"
        [[ "$entry" =~ ^\ *([0-9]+) ]] && _BREE_HISTORY_LAST="${BASH_REMATCH[1]}"
        return 0
    fi
    entry="$(HISTTIMEFORMAT= builtin history 1)"
    # A command HISTCONTROL or HISTIGNORE dropped leaves the last number
    # unchanged, so nothing the shell refused to keep is recorded here.
    [[ "$entry" =~ ^\ *([0-9]+)\*?\ \ (.*)$ ]] || return 0
    [[ "${BASH_REMATCH[1]}" != "${_BREE_HISTORY_LAST:-}" ]] || return 0
    _BREE_HISTORY_LAST="${BASH_REMATCH[1]}"
    printf '%s\n' "${BASH_REMATCH[2]}" >>"$BREE_HISTORY_FILE"
}

_bree_prompt_command() {
    local last_status=$?
    _bree_terminal_history_prompt
    _bree_tmux_sync_bree_environment

    local bree_has_unix_socket=0
    _bree_socket_is_unix && bree_has_unix_socket=1
    (( bree_has_unix_socket )) || _bree_has_port_scan_transport || return "$last_status"
    [[ -n "$BREE_TAB_ID" ]] || return "$last_status"

    if [[ -z "$_BREE_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _BREE_TTY_NAME="$t"
    fi

    if [[ -n "$BREE_PANEL_ID" ]]; then
        _bree_reset_terminal_keyboard_protocols
    fi
    if [[ -n "$BREE_PANEL_ID" ]] || (( ! bree_has_unix_socket )); then
        _bree_report_shell_activity_state prompt
    fi
    _bree_report_tty_once
    _bree_completion_announce

    local now="${EPOCHSECONDS:-$SECONDS}"
    local pwd="$PWD"
    if (( ! bree_has_unix_socket )); then
        if [[ "$pwd" != "$_BREE_PWD_LAST_PWD" ]]; then
            _bree_report_pwd_via_relay "$pwd" && _BREE_PWD_LAST_PWD="$pwd"
        fi
    else
        [[ -n "$BREE_PANEL_ID" ]] || return "$last_status"
    fi

    _bree_set_git_active_pwd "$pwd"

    # Post-wake socket writes can occasionally leave a probe process wedged.
    # If one probe is stale, clear the guard so fresh async probes can resume.
    if [[ -n "$_BREE_GIT_JOB_PID" ]]; then
        if ! kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
            _BREE_GIT_JOB_PID=""
            _BREE_GIT_JOB_STARTED_AT=0
        elif (( _BREE_GIT_JOB_STARTED_AT > 0 )) && (( now - _BREE_GIT_JOB_STARTED_AT >= _BREE_ASYNC_JOB_TIMEOUT )); then
            _BREE_GIT_JOB_PID=""
            _BREE_GIT_JOB_STARTED_AT=0
        fi
    fi

    # Resolve TTY name once.
    if [[ -z "$_BREE_TTY_NAME" ]]; then
        local t
        t="$(tty 2>/dev/null || true)"
        t="${t##*/}"
        [[ "$t" != "not a tty" ]] && _BREE_TTY_NAME="$t"
    fi

    _bree_report_tty_once

    # CWD: keep the app in sync with the actual shell directory.
    if (( bree_has_unix_socket )) && [[ "$pwd" != "$_BREE_PWD_LAST_PWD" ]]; then
        _BREE_PWD_LAST_PWD="$pwd"
        local qpwd="${pwd//\"/\\\"}"
        _bree_send_bg "report_pwd \"${qpwd}\" --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
    fi

    # Branch can change via aliases/tools while an older probe is still in flight.
    # Track .git/HEAD content so we can restart stale probes immediately.
    local git_head_changed=0
    if [[ "${BREE_NO_GIT_WATCH:-}" == "1" ]]; then
        if [[ -n "$_BREE_GIT_JOB_PID" ]] && kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
            kill "$_BREE_GIT_JOB_PID" >/dev/null 2>&1 || true
        fi
        _BREE_GIT_JOB_PID=""
        _BREE_GIT_JOB_STARTED_AT=0
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
                    # The first observed HEAD value is just the session baseline.
                    # Treating it as a branch change clears restore-seeded PR badges
                    # before the first background probe can confirm the current PR.
                    _BREE_GIT_HEAD_SIGNATURE="$head_signature"
                elif [[ "$head_signature" != "$_BREE_GIT_HEAD_SIGNATURE" ]]; then
                    _BREE_GIT_HEAD_SIGNATURE="$head_signature"
                    git_head_changed=1
                fi
            fi
        fi
    fi

    # Git branch/dirty can change without a directory change (e.g. `git checkout`),
    # so update on every prompt (still async + de-duped by the running-job check).
    # When pwd changes (cd into a different repo), kill the old probe and start fresh
    # so the sidebar picks up the new branch immediately.
    if [[ "${BREE_NO_GIT_WATCH:-}" != "1" && -n "$_BREE_GIT_JOB_PID" ]] && kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; then
        if [[ "$pwd" != "$_BREE_GIT_LAST_PWD" || "$git_head_changed" == "1" ]]; then
            kill "$_BREE_GIT_JOB_PID" >/dev/null 2>&1 || true
            _BREE_GIT_JOB_PID=""
            _BREE_GIT_JOB_STARTED_AT=0
        fi
    fi

    if [[ "${BREE_NO_GIT_WATCH:-}" != "1" ]] && { [[ -z "$_BREE_GIT_JOB_PID" ]] || ! kill -0 "$_BREE_GIT_JOB_PID" 2>/dev/null; }; then
        _BREE_GIT_LAST_PWD="$pwd"
        _BREE_GIT_LAST_RUN=$now
        _bree_start_tracked_bg _BREE_GIT_JOB_PID _bree_report_git_branch_for_path "$pwd"
        _BREE_GIT_JOB_STARTED_AT=$now
    fi

    # Ports: lightweight kick to the app's batched scanner every ~10s.
    if (( now - _BREE_PORTS_LAST_RUN >= 10 )); then
        _bree_ports_kick refresh
    fi
    # Hand the previous command status to PROMPT_COMMAND hooks that run after us.
    return "$last_status"
}

_bree_install_prompt_command() {
    [[ -n "${_BREE_PROMPT_INSTALLED:-}" ]] && return 0
    _BREE_PROMPT_INSTALLED=1

    local decl
    decl="$(declare -p PROMPT_COMMAND 2>/dev/null || true)"
    if [[ "$decl" == "declare -a"* ]]; then
        local existing=0
        local item
        for item in "${PROMPT_COMMAND[@]}"; do
            [[ "$item" == "_bree_prompt_command" ]] && existing=1 && break
        done
        if (( existing == 0 )); then
            PROMPT_COMMAND=("_bree_prompt_command" "${PROMPT_COMMAND[@]}")
        fi
    else
        case ";$PROMPT_COMMAND;" in
            *";_bree_prompt_command;"*) ;;
            *)
                if [[ -n "$PROMPT_COMMAND" ]]; then
                    PROMPT_COMMAND="_bree_prompt_command;$PROMPT_COMMAND"
                else
                    PROMPT_COMMAND="_bree_prompt_command"
                fi
                ;;
        esac
    fi

        if (( BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4) )); then
        if (( BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 3) )); then
            builtin readonly _BREE_BASH_PS0='${ _bree_bash_preexec_hook; }'
        else
            builtin readonly _BREE_BASH_PS0='$(_bree_bash_preexec_hook_subshell >/dev/null)'
        fi
        if [[ "$PS0" != *"${_BREE_BASH_PS0}"* ]]; then
            PS0=$PS0"${_BREE_BASH_PS0}"
        fi
    fi
}

# Ensure Resources/bin is at the front of PATH, and remove the app's
# Contents/MacOS entry so the GUI bree binary cannot shadow the CLI bree.
# Shell init (.bashrc/.bash_profile) may prepend other dirs after launch.
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
}
_bree_fix_path
unset -f _bree_fix_path

# --- Completion popup buffer pull ------------------------------------------
#
# The app's Tab popup asks the shell for its exact line by writing the private
# sequence ESC [ 999<digit> ~ (no terminal emits it; the digit is a request
# token the reply echoes). The bindings below answer over the same socket the
# shell-state reports use, and only after announcing report_completion_ready,
# so a shell without them never receives the sequence. They do not change
# READLINE_LINE or redraw. The buffer and $PWD travel base64 encoded and are
# never interpolated into shell code. bash has no clean way to draw inline
# suggestions, so there is no ghost text here.

_bree_completion_send_report() {
    local token="$1" cur="$2" cwd="$3" buf="$4" b p
    b="$(builtin printf '%s' "$buf" | command base64 | command tr -d '\n\r')"
    p="$(builtin printf '%s' "$cwd" | command base64 | command tr -d '\n\r')"
    _bree_send "report_completion_buffer $token $cur ${p:--} ${b:--} --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
}

_bree_completion_report() {
    [[ -n "$BREE_TAB_ID" && -n "$BREE_PANEL_ID" ]] || return 0
    _bree_socket_is_unix || return 0
    _bree_detach_bg _bree_completion_send_report "$1" "$READLINE_POINT" "$PWD" "$READLINE_LINE"
}

# The app forgets a panel's readiness whenever a command starts (a different
# shell may be about to take the prompt), so every prompt re-announces it.
_bree_completion_announce() {
    [[ -n "$BREE_TAB_ID" && -n "$BREE_PANEL_ID" ]] || return 0
    _bree_socket_is_unix || return 0
    _bree_send_bg "report_completion_ready --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
}

# Shell editor submit: ESC [ 9980 ~ clears the line before the app pastes.
_bree_kill_buffer() { READLINE_LINE=""; READLINE_POINT=0; }

_bree_completion_bind() {
    [[ $- == *i* ]] || return 0
    local d km
    for km in emacs vi-insert vi-command; do
        bind -m "$km" -x '"\e[9980~": _bree_kill_buffer' 2>/dev/null || true
    done
    for d in 0 1 2 3 4 5 6 7 8 9; do
        eval "_bree_completion_request_$d() { _bree_completion_report $d; }"
        for km in emacs vi-insert vi-command; do
            bind -m "$km" -x "\"\\e[999${d}~\": _bree_completion_request_$d" 2>/dev/null || true
        done
    done
}
_bree_completion_bind

_bree_detect_send_tool

_bree_install_prompt_command
