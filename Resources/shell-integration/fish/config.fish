# bree shell integration for fish
# Injected automatically, do not source manually.

set -l _bree_integration_enabled 1
if set -q BREE_SHELL_INTEGRATION; and test "$BREE_SHELL_INTEGRATION" = 0
    set _bree_integration_enabled 0
end

if test "$_bree_integration_enabled" != 0
    set -g _BREE_SEND_TOOL ""
    if command -sq ncat
        set -g _BREE_SEND_TOOL ncat
    else if command -sq socat
        set -g _BREE_SEND_TOOL socat
    else if command -sq nc
        set -g _BREE_SEND_TOOL nc
    end

    set -g _BREE_SHELL_ACTIVITY_LAST ""
    set -g _BREE_PORTS_LAST_RUN 0
    set -g _BREE_TTY_NAME ""
    set -g _BREE_TTY_REPORTED 0
    set -g _BREE_PWD_LAST_PWD ""
    set -g _BREE_TMUX_PULL_SIGNATURE ""
    set -g _BREE_TMUX_PUSH_SIGNATURE ""
    # Keep BREE_SOCKET_CAPABILITY inherited; tmux's global environment is
    # readable by clients that were not started inside bree.
    set -g _BREE_TMUX_SYNC_KEYS \
        BREE_BUNDLED_CLI_PATH \
        BREE_BUNDLE_ID \
        BREED_UNIX_PATH \
        BREE_REPO_ROOT \
        BREE_DEBUG_LOG \
        BREE_LOAD_GHOSTTY_ZSH_INTEGRATION \
        BREE_PORT \
        BREE_PORT_END \
        BREE_PORT_RANGE \
        BREE_REMOTE_DAEMON_ALLOW_LOCAL_BUILD \
        BREE_SHELL_INTEGRATION \
        BREE_SHELL_INTEGRATION_DIR \
        BREE_SOCKET_ENABLE \
        BREE_SOCKET_MODE \
        BREE_SOCKET_PATH \
        BREE_SSH_ATTEMPT_ID \
        BREE_TAB_ID \
        BREE_TAG \
        BREE_TERMINAL_LIFECYCLE_ID \
        BREE_WORKSPACE_ID
    set -g _BREE_TMUX_SURFACE_SCOPED_KEYS BREE_HISTORY_FILE BREE_PANEL_ID BREE_SURFACE_ID

    function _bree_tmux_sync_key_is_managed --argument-names candidate
        contains -- "$candidate" $_BREE_TMUX_SYNC_KEYS
    end

    function _bree_tmux_shell_env_signature
        set -l parts
        for key in $_BREE_TMUX_SYNC_KEYS
            set -q $key; or continue
            test -n "$$key"; or continue
            set -a parts "$key=$$key"
        end
        string join \x1f -- $parts
    end

    # A published environment only matters to a running default tmux server;
    # skip the tmux client spawn on every prompt when none is running. tmux
    # ignores a TMUX_TMPDIR that does not resolve and falls back to /tmp.
    function _bree_tmux_default_server_socket
        set -q _BREE_TMUX_UID; or set -g _BREE_TMUX_UID (id -u)
        set -l tmpdir /tmp
        if set -q TMUX_TMPDIR; and test -n "$TMUX_TMPDIR"; and test -e "$TMUX_TMPDIR"
            set tmpdir (string replace -r '/$' '' -- "$TMUX_TMPDIR")
        end
        printf '%s\n' "$tmpdir/tmux-$_BREE_TMUX_UID/default"
    end

    function _bree_tmux_default_server_running
        test -S (_bree_tmux_default_server_socket)
    end

    function _bree_tmux_publish_bree_environment
        if set -q TMUX; and test -n "$TMUX"
            return 0
        end
        command -sq tmux; or functions -q tmux; or return 0
        set -l server_socket (_bree_tmux_default_server_socket)
        test -S "$server_socket"; or return 0
        # An exited server can leave its socket behind. When tmux reports nothing
        # listening there, the marker records that socket as dead; a new server rebinds the socket,
        # which makes it newer than the marker. test exits 2 when -nt is not
        # supported, which keeps the old always-try behavior.
        set -l stale_marker "$server_socket.bree-unreachable"
        if test -e "$stale_marker"
            test "$server_socket" -nt "$stale_marker" 2>/dev/null
            test $status -eq 1; and return 0
        end

        set -l signature (_bree_tmux_shell_env_signature)
        test -n "$signature"; or return 0
        test "$signature" = "$_BREE_TMUX_PUSH_SIGNATURE"; and return 0

        for key in $_BREE_TMUX_SYNC_KEYS
            set -q $key; or continue
            test -n "$$key"; or continue
            set -l tmux_error (tmux set-environment -g "$key" "$$key" 2>&1 >/dev/null)
            if test $status -ne 0
                # Only a dead socket earns the marker; other failures retry.
                if string match -qr 'no server running|error connecting|Connection refused' -- "$tmux_error"
                    printf '' 2>/dev/null >"$stale_marker"
                end
                return 0
            end
        end
        for key in $_BREE_TMUX_SURFACE_SCOPED_KEYS
            tmux set-environment -gu "$key" >/dev/null 2>&1; or return 0
        end
        set -g _BREE_TMUX_PUSH_SIGNATURE "$signature"
    end

    function _bree_tmux_refresh_bree_environment
        set -q TMUX; and test -n "$TMUX"; or return 0
        command -sq tmux; or functions -q tmux; or return 0

        set -l did_change 0
        for key in $_BREE_TMUX_SURFACE_SCOPED_KEYS
            if set -q $key
                set -e $key
                set did_change 1
            end
        end

        set -l output (tmux show-environment 2>/dev/null); or return 0
        set -l filtered
        for line in $output
            string match -q 'BREE_*=*' -- "$line"; or continue
            set -l parts (string split -m 1 '=' -- "$line")
            _bree_tmux_sync_key_is_managed "$parts[1]"; or continue
            set -a filtered "$line"
        end
        test (count $filtered) -gt 0; or return 0

        set -l signature (string join \x1e -- $filtered)
        if test "$signature" = "$_BREE_TMUX_PULL_SIGNATURE"; and test "$did_change" = 0
            return 0
        end

        for line in $filtered
            set -l parts (string split -m 1 '=' -- "$line")
            set -l key "$parts[1]"
            set -l value "$parts[2]"
            if not set -q $key; or test "$$key" != "$value"
                set -gx $key "$value"
                set did_change 1
            end
        end

        set -g _BREE_TMUX_PULL_SIGNATURE "$signature"
        if test "$did_change" = 1
            set -g _BREE_TTY_REPORTED 0
            set -g _BREE_SHELL_ACTIVITY_LAST ""
            set -g _BREE_PWD_LAST_PWD ""
        end
    end

    function _bree_tmux_sync_bree_environment
        if set -q TMUX; and test -n "$TMUX"
            _bree_tmux_refresh_bree_environment
        else
            _bree_tmux_publish_bree_environment
        end
    end

    function _bree_restore_scrollback_once
        set -l path "$BREE_RESTORE_SCROLLBACK_FILE"
        test -n "$path"; or return 0
        set -e BREE_RESTORE_SCROLLBACK_FILE
        set -l token (string replace -r '^.*/' '' -- "$path")
        set -l host (/bin/hostname)

        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/start\007' "$host" "$token"
        if test -r "$path"
            /bin/cat -- "$path" 2>/dev/null; or true
            /bin/rm -f -- "$path" >/dev/null 2>&1; or true
        end
        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s/.bree/session-scrollback-replay/%s/end\007' "$host" "$token"
        printf '\033]1337;CurrentDir=kitty-shell-cwd://%s%s\007' "$host" "$PWD"
    end
    _bree_restore_scrollback_once

    # First-launch welcome banner. bree passes the path of a one-shot token file
    # in BREE_SHOW_WELCOME_FILE instead of typing `bree welcome` into the first
    # workspace's shell, so the banner prints during startup and never lands in
    # shell history. Only the shell whose `rm` of the token succeeds prints it,
    # and never inside tmux, so children that inherited the variable cannot repeat it.
    function _bree_show_welcome_once
        set -l token "$BREE_SHOW_WELCOME_FILE"
        set -e BREE_SHOW_WELCOME_FILE
        test -n "$token"; or return 0
        /bin/rm -- "$token" >/dev/null 2>&1; or return 0
        test -z "$TMUX"; or return 0
        set -l cli (string replace -r '/?shell-integration/?$' '' -- "$BREE_SHELL_INTEGRATION_DIR")/bin/bree
        if not test -x "$cli"
            set cli (command -s bree)
        end
        test -n "$cli"; or return 0
        "$cli" welcome 2>/dev/null; or true
    end
    _bree_show_welcome_once

    function _bree_now
        if test -n "$EPOCHSECONDS"
            printf '%s\n' "$EPOCHSECONDS"
        else
            date +%s
        end
    end

    function _bree_socket_is_unix
        test -n "$BREE_SOCKET_PATH"; and test -S "$BREE_SOCKET_PATH"
    end

    function _bree_relay_cli_path
        if test -n "$BREE_BUNDLED_CLI_PATH"; and test -x "$BREE_BUNDLED_CLI_PATH"
            printf '%s\n' "$BREE_BUNDLED_CLI_PATH"
            return 0
        end
        command -v bree 2>/dev/null
    end

    function _bree_socket_uses_remote_relay
        test -n "$BREE_SOCKET_PATH"; or return 1
        string match -q '/*' -- "$BREE_SOCKET_PATH"; and return 1
        string match -q '*:*' -- "$BREE_SOCKET_PATH"; or return 1
        set -l relay_cli (_bree_relay_cli_path)
        test -n "$relay_cli"
    end

    function _bree_write_socket_payload --argument-names payload
        if set -q BREE_SOCKET_CAPABILITY
            and test -n "$BREE_SOCKET_CAPABILITY"
            and not string match -qr '[[:space:]]' -- "$BREE_SOCKET_CAPABILITY"
            printf '_bree_capability_v1 %s %s\n' "$BREE_SOCKET_CAPABILITY" "$payload"
        else
            printf '%s\n' "$payload"
        end
    end

    function _bree_send --argument-names payload
        test -n "$payload"; or return 0
        test -n "$BREE_SOCKET_PATH"; or return 0
        if test -x /usr/bin/nc
            # Apple's -N takes a value, so use the bounded response-waiting form.
            _bree_write_socket_payload "$payload" | /usr/bin/nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1; or true
            return 0
        end
        switch "$_BREE_SEND_TOOL"
            case ncat
                _bree_write_socket_payload "$payload" | ncat -w 1 -U "$BREE_SOCKET_PATH" --send-only >/dev/null 2>&1
            case socat
                _bree_write_socket_payload "$payload" | socat -T 1 - "UNIX-CONNECT:$BREE_SOCKET_PATH" >/dev/null 2>&1
            case nc
                _bree_write_socket_payload "$payload" | nc -N -U "$BREE_SOCKET_PATH" >/dev/null 2>&1; or \
                    _bree_write_socket_payload "$payload" | nc -w 1 -U "$BREE_SOCKET_PATH" >/dev/null 2>&1
        end
    end

    function _bree_send_bg --argument-names payload
        _bree_send "$payload" >/dev/null 2>&1 &
    end

    function _bree_json_escape --argument-names value
        set -l backslash "\\"
        set -l escaped_backslash "\\\\"
        set -l quote '"'
        set -l escaped_quote '\"'
        string replace -a "$backslash" "$escaped_backslash" -- "$value" \
            | string replace -a "$quote" "$escaped_quote" \
            | string replace -a (printf '\n') "\\n" \
            | string replace -a (printf '\r') "\\r" \
            | string replace -a (printf '\t') "\\t"
    end

    function _bree_relay_workspace_id
        if test -n "$BREE_WORKSPACE_ID"
            printf '%s\n' "$BREE_WORKSPACE_ID"
            return 0
        end
        test -n "$BREE_TAB_ID"; or return 1
        printf '%s\n' "$BREE_TAB_ID"
    end

    function _bree_relay_rpc_bg --argument-names method params
        _bree_socket_uses_remote_relay; or return 1
        set -l relay_cli (_bree_relay_cli_path)
        test -n "$relay_cli"; or return 1
        "$relay_cli" rpc "$method" "$params" >/dev/null 2>&1 &
    end

    function _bree_relay_rpc --argument-names method params
        _bree_socket_uses_remote_relay; or return 1
        set -l relay_cli (_bree_relay_cli_path)
        test -n "$relay_cli"; or return 1
        set -l response ("$relay_cli" rpc "$method" "$params" 2>/dev/null); or return 1
        set response (string join '' -- $response)
        string match -q '*"ok":false*' -- "$response"; and return 1
        string match -q '*"ok": false*' -- "$response"; and return 1
        return 0
    end

    function _bree_report_tty_via_relay
        _bree_socket_uses_remote_relay; or return 1
        test -n "$_BREE_TTY_NAME"; or return 1
        test -n "$BREE_TERMINAL_LIFECYCLE_ID"; or return 1
        test -n "$BREE_SSH_ATTEMPT_ID"; or return 1
        set -l workspace_id (_bree_relay_workspace_id); or return 1
        set -l tty_name_json (_bree_json_escape "$_BREE_TTY_NAME")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"tty_name\":\"$tty_name_json\",\"terminal_lifecycle_id\":\"$BREE_TERMINAL_LIFECYCLE_ID\",\"attempt_id\":\"$BREE_SSH_ATTEMPT_ID\""
        if test -n "$BREE_PANEL_ID"
            set params "$params,\"surface_id\":\"$BREE_PANEL_ID\""
        end
        set params "$params}"
        _bree_relay_rpc surface.report_tty "$params"
    end

    function _bree_report_pwd_via_relay --argument-names pwd
        _bree_socket_uses_remote_relay; or return 1
        test -n "$pwd"; or return 1
        set -l workspace_id (_bree_relay_workspace_id); or return 1
        set -l pwd_json (_bree_json_escape "$pwd")
        set -l params "{\"workspace_id\":\"$workspace_id\",\"path\":\"$pwd_json\""
        if test -n "$BREE_PANEL_ID"
            set params "$params,\"surface_id\":\"$BREE_PANEL_ID\""
        end
        set params "$params}"
        _bree_relay_rpc_bg surface.report_pwd "$params"
    end

    function _bree_report_shell_activity_state_via_relay --argument-names state
        _bree_socket_uses_remote_relay; or return 1
        test -n "$state"; or return 1
        set -l workspace_id (_bree_relay_workspace_id); or return 1
        set -l params "{\"workspace_id\":\"$workspace_id\",\"state\":\"$state\""
        if test -n "$BREE_PANEL_ID"
            set params "$params,\"surface_id\":\"$BREE_PANEL_ID\""
        end
        if test -n "$BREE_TERMINAL_LIFECYCLE_ID"
            set params "$params,\"terminal_lifecycle_id\":\"$BREE_TERMINAL_LIFECYCLE_ID\""
        end
        set params "$params}"
        _bree_relay_rpc_bg surface.report_shell_state "$params"
    end

    function _bree_ports_kick_via_relay --argument-names reason
        _bree_socket_uses_remote_relay; or return 1
        set -l workspace_id (_bree_relay_workspace_id); or return 1
        test -n "$reason"; or set reason command
        set -l params "{\"workspace_id\":\"$workspace_id\",\"reason\":\"$reason\""
        if test -n "$BREE_PANEL_ID"
            set params "$params,\"surface_id\":\"$BREE_PANEL_ID\""
        end
        set params "$params}"
        _bree_relay_rpc_bg surface.ports_kick "$params"
    end

    function _bree_path_prepend_unique_directory --argument-names directory skipped_directory
        test -n "$directory"; or return 0
        set -l next_path "$directory"
        for entry in $PATH
            test "$entry" = "$directory"; and continue
            test -n "$skipped_directory"; and test "$entry" = "$skipped_directory"; and continue
            set -a next_path "$entry"
        end
        set -gx PATH $next_path
    end

    function _bree_fix_path
        set -q BREE_SHELL_INTEGRATION_DIR; and test -n "$BREE_SHELL_INTEGRATION_DIR"; or return 0
        set -l integration_dir (string trim -r -c / -- "$BREE_SHELL_INTEGRATION_DIR")
        string match -q '*/Resources/shell-integration' -- "$integration_dir"; or return 0
        set -l resources_dir (string replace -r '/shell-integration$' '' -- "$integration_dir")
        set -l gui_dir (string replace -r '/Resources$' '/MacOS' -- "$resources_dir")
        set -l bin_dir "$resources_dir/bin"
        test -d "$bin_dir"; or return 0
        _bree_path_prepend_unique_directory "$bin_dir" "$gui_dir"
    end

    # Succeeds when every directory, checked in order, is an absolute path to
    # a real directory (not a symlink) owned by this user that no one else can
    # write to, with a safe ancestry. Sticky shared ancestors (such as /tmp)
    # are safe; a non-sticky writable ancestor can rename a checked child.
    function _bree_private_dirs --argument-names create
        set -e argv[1]
        test (count $argv) -gt 0; or return 1
        for dir in $argv
            string match -q '/*' -- "$dir"; or return 1
            # A directory mkdir just created is ours and already 0700.
            if test "$create" = 1; and not test -e "$dir"; and not test -L "$dir"
                /bin/mkdir -m 700 -- "$dir" >/dev/null 2>&1; or return 1
            end
            test -d "$dir"; and not test -L "$dir"; and test -O "$dir"; or return 1
            # fish can't read mode bits; find's -type d uses lstat here.
            set -l private_dir (/usr/bin/find "$dir" -prune -type d ! -perm -020 ! -perm -002 -print 2>/dev/null)
            test "$private_dir" = "$dir"; or return 1
            _bree_private_path_chain "$dir"; or return 1
        end
    end

    function _bree_private_path_chain --argument-names start
        set -l paths "$start"
        set -l canonical (_bree_resolve_path "$start"); or return 1
        test "$canonical" = "$start"; or set -a paths "$canonical"
        for chain_start in $paths
            set -l current "$chain_start"
            while true
                _bree_private_path_node "$current"; or return 1
                test "$current" = /; and break
                set current (string replace -r '/[^/]*$' '' -- "$current")
                test -n "$current"; or set current /
            end
        end
    end

    function _bree_resolve_path --argument-names path
        if test -x /usr/bin/realpath
            /usr/bin/realpath -- "$path"
        else if test -x /bin/realpath
            /bin/realpath -- "$path"
        else if test -x /usr/bin/readlink
            /usr/bin/readlink -f -- "$path"
        else
            return 1
        end
    end

    function _bree_private_path_node --argument-names current
        set -l owner
        if test -d "$current"; and not test -L "$current"
            set owner (/usr/bin/find -P "$current" -prune \( -uid "$EUID" -o -uid 0 \) -print 2>/dev/null)
            test "$owner" = "$current"; or return 1
            set -l private (/usr/bin/find -P "$current" -prune -type d ! -perm -020 ! -perm -002 -print 2>/dev/null)
            test "$private" = "$current"; and return 0
            set -l sticky (/usr/bin/find -P "$current" -prune -type d -perm -1000 -print 2>/dev/null)
            test "$sticky" = "$current"; and return 0
            return 1
        end
        if test -L "$current"
            set owner (/usr/bin/find -P "$current" -prune \( -uid "$EUID" -o -uid 0 \) -print 2>/dev/null)
            test "$owner" = "$current"
            return $status
        end
        return 1
    end

    set -g _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED ""
    function _bree_install_cli_command_shim --argument-names command_name wrapper_path
        set -l surface_component "$fish_pid"
        if set -q BREE_SURFACE_ID; and test -n "$BREE_SURFACE_ID"
            set surface_component "$BREE_SURFACE_ID"
        end
        set -l shim_root ""
        if set -q BREE_CLAUDE_WRAPPER_SHIM_ROOT
            set shim_root (string trim -r -c / -- "$BREE_CLAUDE_WRAPPER_SHIM_ROOT")
        end
        set -l tmp_root /tmp
        if set -q TMPDIR; and test -n "$TMPDIR"
            set tmp_root (string trim -r -c / -- "$TMPDIR")
        end
        set -l legacy_shim_root "$tmp_root/bree-cli-shims/$surface_component"
        set -l shim_dot .bree
        switch "$BREE_BUNDLE_ID"
            case com.bree.app
                set shim_dot .bree
            case com.bree.app.debug.bree
                set shim_dot .bree-dev
        end
        set -l shim_state "$HOME/$shim_dot"
        set -l rejected_root ""
        # An inherited root is reused only while it is still private.
        # Otherwise the shell makes its own, and skips the shim if it can't.
        if test -z "$shim_root"; or not string match -q "*/bree-cli-shims/$surface_component" -- "$shim_root"; or test "$shim_root" = "$legacy_shim_root"; or not _bree_private_dirs 0 (string replace -r '/[^/]*$' '' -- "$shim_root") "$shim_root"
            # Keep a shim root this shell did not accept off PATH.
            if string match -qr '/bree-cli-shims/[^/]+$' -- "$shim_root"
                set rejected_root "$shim_root"
            end
            set shim_root "$shim_state/bree-cli-shims/$surface_component"
            if not string match -q '/*' -- "$HOME"; or not _bree_private_dirs 1 "$shim_state" "$shim_state/bree-cli-shims" "$shim_root"
                if test "$command_name" = claude
                    set -e BREE_CLAUDE_WRAPPER_SHIM
                    set -e BREE_CLAUDE_WRAPPER_SHIM_ROOT
                    set -g _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED ""
                end
                if test -n "$rejected_root"
                    set -l next_path
                    for entry in $PATH
                        test "$entry" = "$rejected_root"; or set -a next_path "$entry"
                    end
                    set -gx PATH $next_path
                end
                return 0
            end
        end
        set -l shim_path "$shim_root/$command_name"
        begin
            printf '%s\n' '#!/usr/bin/env bash'
            if test "$command_name" = claude
                printf 'bree_wrapper=%s\n' (string escape --style=script -- "$wrapper_path")
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
                printf 'export BREE_CLAUDE_WRAPPER_SHIM=%s\n' (string escape --style=script -- "$shim_path")
                printf 'export BREE_CLAUDE_WRAPPER_SHIM_ROOT=%s\n' (string escape --style=script -- "$shim_root")
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
                printf 'exec %s "$@"\n' (string escape --style=script -- "$wrapper_path")
            end
        end >"$shim_path" 2>/dev/null; or return 0
        chmod 0700 "$shim_path" >/dev/null 2>&1; or return 0
        if test "$command_name" = claude
            set -gx BREE_CLAUDE_WRAPPER_SHIM "$shim_path"
            set -gx BREE_CLAUDE_WRAPPER_SHIM_ROOT "$shim_root"
            set -g _BREE_CLAUDE_WRAPPER_SHIM_VERIFIED "$shim_path"
        end
        _bree_path_prepend_unique_directory "$shim_root" "$rejected_root"
    end

    function _bree_install_cli_wrapper --argument-names command_name wrapper_file
        if test "$command_name" = claude; and set -q BREE_CLAUDE_INTEGRATION_DISABLED; and test "$BREE_CLAUDE_INTEGRATION_DISABLED" = 1
            return 0
        end
        test -n "$BREE_SHELL_INTEGRATION_DIR"; or return 0
        set -l integration_dir (string replace -r '/$' '' -- "$BREE_SHELL_INTEGRATION_DIR")
        set -l bundle_dir (string replace -r '/shell-integration$' '' -- "$integration_dir")
        set -l wrapper_path "$bundle_dir/bin/$wrapper_file"
        test -x "$wrapper_path"; or return 0

        if test "$command_name" = claude
            _bree_install_cli_command_shim "$command_name" "$wrapper_path"
        end
        functions -q "$command_name"; and return 0
        switch "$command_name"
            case claude
                function claude --wraps "$wrapper_path" --inherit-variable wrapper_path
                    # Only run a shim this shell wrote into a directory it checked.
                    if test -n "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED"; and test "$BREE_CLAUDE_WRAPPER_SHIM" = "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED"; and test -x "$_BREE_CLAUDE_WRAPPER_SHIM_VERIFIED"
                        "$BREE_CLAUDE_WRAPPER_SHIM" $argv
                    else if test -x "$wrapper_path"
                        "$wrapper_path" $argv
                    else
                        command claude $argv
                    end
                end
            case grok
                function grok --wraps "$wrapper_path" --inherit-variable wrapper_path
                    "$wrapper_path" $argv
                end
        end
    end

    _bree_install_cli_wrapper claude bree-claude-wrapper
    _bree_install_cli_wrapper grok grok

    function _bree_report_tty_once
        test "$_BREE_TTY_REPORTED" = 1; and return 0
        if test -z "$_BREE_TTY_NAME"
            set -g _BREE_TTY_NAME (tty 2>/dev/null | string replace -r '^.*/' '')
        end
        test -n "$_BREE_TTY_NAME"; or return 0
        test "$_BREE_TTY_NAME" != "not a tty"; or return 0

        if _bree_socket_is_unix
            test -n "$BREE_TAB_ID"; or return 0
            test -n "$BREE_PANEL_ID"; or return 0
            set -g _BREE_TTY_REPORTED 1
            _bree_send_bg "report_tty $_BREE_TTY_NAME --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
        else if _bree_socket_uses_remote_relay
            # Treat the first relay report as a readiness barrier. Latch only
            # after acknowledgement so later prompts retry transient failures.
            _bree_report_tty_via_relay; or return 0
            set -g _BREE_TTY_REPORTED 1
        end
    end

    function _bree_report_shell_activity_state --argument-names state
        test -n "$state"; or return 0
        test -n "$BREE_TAB_ID"; or return 0
        if _bree_socket_is_unix
            test -n "$BREE_PANEL_ID"; or return 0
        end
        test "$_BREE_SHELL_ACTIVITY_LAST" = "$state"; and return 0
        set -g _BREE_SHELL_ACTIVITY_LAST "$state"
        if _bree_socket_is_unix
            set -l payload "report_shell_state $state --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
            if test -n "$BREE_TERMINAL_LIFECYCLE_ID"
                set payload "$payload --terminal-lifecycle-id=$BREE_TERMINAL_LIFECYCLE_ID"
            end
            _bree_send_bg "$payload"
        else
            _bree_report_shell_activity_state_via_relay "$state"; or set -g _BREE_SHELL_ACTIVITY_LAST ""
        end
    end

    function _bree_reset_terminal_keyboard_protocols
        isatty stdout; or test -n "$BREE_TEST_FORCE_KEYBOARD_RESET$BREE_TEST_FORCE_KITTY_RESET"; or return 0
        printf '\033[>m\033[<8u'
    end

    function _bree_ports_kick --argument-names reason
        test -n "$reason"; or set reason command
        test -n "$BREE_TAB_ID"; or return 0
        set -g _BREE_PORTS_LAST_RUN (_bree_now)
        if _bree_socket_is_unix
            test -n "$BREE_PANEL_ID"; or return 0
            _bree_send_bg "ports_kick --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID --reason=$reason"
        else
            _bree_ports_kick_via_relay "$reason"
        end
    end

    function _bree_preexec --on-event fish_preexec
        _bree_tmux_sync_bree_environment
        _bree_report_tty_once
        _bree_report_shell_activity_state running
        _bree_ports_kick command
    end

    function _bree_prompt --on-event fish_prompt
        _bree_tmux_sync_bree_environment
        _bree_reset_terminal_keyboard_protocols
        _bree_report_tty_once
        _bree_report_shell_activity_state prompt
        set -l pwd "$PWD"
        if test "$pwd" != "$_BREE_PWD_LAST_PWD"
            if _bree_socket_is_unix
                if test -n "$BREE_TAB_ID"; and test -n "$BREE_PANEL_ID"
                    set -l qpwd (_bree_json_escape "$pwd")
                    if _bree_send_bg "report_pwd \"$qpwd\" --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
                        set -g _BREE_PWD_LAST_PWD "$pwd"
                    end
                end
            else if _bree_report_pwd_via_relay "$pwd"
                set -g _BREE_PWD_LAST_PWD "$pwd"
            end
        end
        set -l now (_bree_now)
        if test (math "$now - $_BREE_PORTS_LAST_RUN") -ge 5
            _bree_ports_kick refresh
        end
        _bree_completion_announce
    end

    # Completion popup buffer pull. The app's Tab popup asks the shell for its
    # exact line by writing the private sequence ESC [ 999<digit> ~ (no
    # terminal emits it; the digit is a request token the reply echoes). The
    # binds below answer over the same socket the shell-state reports use,
    # and only after the shell announced report_completion_ready, so a shell
    # without them never receives the sequence. They neither change nor
    # repaint the command line. The buffer and $PWD travel base64 encoded.
    # fish draws its own inline suggestions, so there is no ghost text here.
    function _bree_completion_report --argument-names token
        test -n "$BREE_TAB_ID"; and test -n "$BREE_PANEL_ID"; or return 0
        _bree_socket_is_unix; or return 0
        set -l buf (commandline -b | string collect -N | base64 | tr -d '\n\r')
        set -l cwd (printf '%s' "$PWD" | base64 | tr -d '\n\r')
        test -n "$buf"; or set buf -
        test -n "$cwd"; or set cwd -
        _bree_send_bg "report_completion_buffer $token "(commandline -C)" $cwd $buf --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
    end

    # The app forgets a panel's readiness whenever a command starts (a
    # different shell may be about to take the prompt), so every prompt
    # re-announces it.
    function _bree_completion_announce
        test -n "$BREE_TAB_ID"; and test -n "$BREE_PANEL_ID"; or return 0
        _bree_socket_is_unix; or return 0
        _bree_send_bg "report_completion_ready --tab=$BREE_TAB_ID --panel=$BREE_PANEL_ID"
    end

    # Shell editor submit: ESC [ 9980 ~ clears the line before the app pastes.
    function _bree_kill_buffer
        commandline -r ""
    end

    if status is-interactive
        for _bree_mode in default insert visual
            bind -M $_bree_mode '\e[9980~' _bree_kill_buffer 2>/dev/null
        end
        for _bree_d in 0 1 2 3 4 5 6 7 8 9
            eval "function _bree_completion_request_$_bree_d; _bree_completion_report $_bree_d; end"
            for _bree_mode in default insert visual
                bind -M $_bree_mode '\e[999'$_bree_d'~' _bree_completion_request_$_bree_d 2>/dev/null
            end
        end
        set -e _bree_d _bree_mode
    end
end

set -l _bree_user_config_home ""
if set -q BREE_FISH_CONFIG_HOME
    set _bree_user_config_home "$BREE_FISH_CONFIG_HOME"
else if set -q HOME
    set _bree_user_config_home "$HOME/.config"
end

set -l _bree_user_config "$_bree_user_config_home/fish/config.fish"
if not set -q BREE_FISH_USER_CONFIG_ALREADY_LOADED; and test -n "$_bree_user_config_home"; and test "$_bree_user_config_home" != "$XDG_CONFIG_HOME"
    set -gx XDG_CONFIG_HOME "$_bree_user_config_home"

    set -l _bree_user_functions "$_bree_user_config_home/fish/functions"
    if test -d "$_bree_user_functions"; and not contains -- "$_bree_user_functions" $fish_function_path
        set -g fish_function_path "$_bree_user_functions" $fish_function_path
    end

    set -l _bree_user_completions "$_bree_user_config_home/fish/completions"
    if test -d "$_bree_user_completions"; and not contains -- "$_bree_user_completions" $fish_complete_path
        set -g fish_complete_path "$_bree_user_completions" $fish_complete_path
    end

    for _bree_user_conf in "$_bree_user_config_home"/fish/conf.d/*.fish
        if test -r "$_bree_user_conf"
            source "$_bree_user_conf"
        end
    end

    if test -r "$_bree_user_config"
        source "$_bree_user_config"
    end
end

# Run after the user's config so bree's bundled commands keep precedence even
# when shell startup replaced PATH. Remote integrations do not use the bundled
# `shell-integration` layout, so the helper leaves their PATH unchanged.
functions -q _bree_fix_path; and _bree_fix_path
functions -e _bree_fix_path
