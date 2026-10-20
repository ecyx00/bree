# breed-remote (Go)

Go remote daemon for `bree ssh` bootstrap, capability negotiation, and remote proxy RPC. It is not in the terminal keystroke hot path.

## Commands

1. `breed-remote version`
2. `breed-remote serve --stdio`
3. `breed-remote serve --stdio --persistent --slot <slot> [--persistent-lease-port <port>]`
4. `breed-remote serve --persistent-stop --slot <slot>` — internal authenticated slot teardown
5. `breed-remote cli <command> [args...]` — relay bree commands to the local app over the reverse SSH forward

The `bree ssh` code path uses `serve --stdio --persistent --slot <slot>` over an SSH exec
channel. That stdio process is only a proxy to an authenticated per-slot daemon
with credentials and logs under `~/.bree/daemon/<version>/<slot>/`, so remote PTY sessions
can survive local surface close, local reconnect, and app relaunch. The persistent
server never opens a public listener; it accepts only a per-user Unix socket under
`/tmp/breed-remote-<uid>/` and the slot token.

When invoked as `bree` (via wrapper/symlink installed during bootstrap), the binary auto-dispatches to the `cli` subcommand. This is busybox-style argv[0] detection.

## RPC methods (newline-delimited JSON over stdio)

1. `hello`
2. `ping`
3. `proxy.open`
4. `proxy.close`
5. `proxy.write`
6. `proxy.stream.subscribe`
7. async `proxy.stream.data` / `proxy.stream.eof` / `proxy.stream.error` events
8. `session.open`
9. `session.close`
10. `session.attach`
11. `session.resize`
12. `session.detach`
13. `session.status`
14. `pty.attach`
15. `pty.write`
16. `pty.resize`
17. `pty.detach`
18. `pty.close`
19. `pty.list`

Current integration in bree:
1. `workspace.remote.configure` now bootstraps this binary over SSH when missing.
2. Client sends `hello` before enabling remote proxy transport.
3. Local workspace proxy broker serves SOCKS5 + HTTP CONNECT and tunnels stream traffic through `proxy.*` RPC over `serve --stdio`, using daemon-pushed stream events instead of polling reads. Both handshakes require a per-tunnel credential that only the embedded browser receives.
4. Daemon status/capabilities are exposed in `workspace.remote.status -> remote.daemon` (including `session.resize.min`).
5. Persistent SSH terminals require the `pty.session.persistent_daemon` capability before bree will restore a saved remote PTY session ID after relaunch.

## Persistent SSH PTY daemon

`bree ssh` uses one persistent daemon slot per CLI-launched SSH workspace. The
slot name is generated locally, validated as `[A-Za-z0-9._-]{1,128}`, and sent
to the remote daemon bootstrap as `--slot`.

Remote slot files:
1. `/tmp/breed-remote-<uid>/breed-<slot-hash>.sock` authenticated Unix socket for stdio proxies.
2. `~/.bree/daemon/<version>/<slot>/auth.token` random 32-byte hex token, mode `0600`.
3. `~/.bree/daemon/<version>/<slot>/daemon.lock` single-owner lock.
4. `~/.bree/daemon/<version>/<slot>/daemon.log` startup and crash diagnostics.

Each `serve --stdio --persistent` bridge includes a fresh `bridge_lease_id` in
its authenticated socket handshake. The persistent server tracks authenticated
bridge connections and lets the newest authenticated bridge take over the slot,
closing older connections (including half-open SSH bridges) without touching
the persistent PTY sessions.

PTY lifecycle:
1. A local attach creates or reuses a named `pty.*` session in the persistent daemon.
2. If the local surface closes, the stdio proxy disconnects and its attachment detaches, but the PTY process and bounded scrollback remain in the daemon.
3. `bree ssh-session-list` calls `pty.list`; `bree ssh-session-attach` creates a new local terminal whose startup script calls `ssh-pty-attach --require-existing`.
4. `bree ssh-session-cleanup` calls `pty.close` to terminate a persisted PTY session explicitly.
5. Sessions with no attachments keep their last-known size and are reaped by the daemon idle TTL.
6. Closing the owning workspace sends an authenticated slot-shutdown request, waits a bounded interval for the daemon lock to be released, and removes the relay's shell-state directory. As defense in depth, a daemon launched with `--persistent-lease-port` observes that exact `~/.bree/relay/<port>.slot` lease, exits after the observed lease disappears and stdio disconnects, and removes the matching shell-state directory. Older callers that omit the flag retain the prior behavior without unsafe broad lease scanning.

## Distribution

Release and nightly builds publish prebuilt `breed-remote` binaries on GitHub Releases for:
1. `darwin/arm64`
2. `darwin/amd64`
3. `linux/arm64`
4. `linux/amd64`

The app embeds a compact manifest in `Info.plist` with:
1. exact release asset URLs
2. pinned SHA-256 digests
3. release tag and checksums asset URL

Release and nightly apps download and cache the matching binary locally, verify its SHA-256, then upload it to the remote host if needed. Dev builds can opt into a local `go build` fallback with `BREE_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1`.

To inspect what a given app build trusts, run:
1. `bree remote-daemon-status`
2. `bree remote-daemon-status --os linux --arch amd64`

The command prints the exact release asset URL, expected SHA-256, local cache status, and a copy-pasteable `gh attestation verify` command for the selected platform.

## CLI relay

The `cli` subcommand (or `bree` wrapper/symlink) connects to the local bree app through an SSH reverse forward and relays commands using the v2 JSON-RPC protocol.

Socket discovery order:
1. `--socket <path>` flag
2. `BREE_SOCKET_PATH` environment variable
3. `~/.bree/socket_addr` file (written by the app after the reverse relay establishes)

For TCP addresses, the CLI dials once and only refreshes `~/.bree/socket_addr` a single time if the first address was stale. Relay metadata is published only after the reverse forward is ready, so steady-state use does not rely on polling.

Authenticated relay details:
1. Each SSH workspace gets its own relay ID and relay token.
2. The app runs a local loopback relay server that requires an HMAC-SHA256 challenge-response before forwarding a command to the real local Unix socket.
   Authentication is mutual: the CLI sends its own nonce with its MAC and sends nothing further until the relay's success line carries `relay_mac`, an HMAC over a `bree-relay-server-proof` label, the relay ID and both nonces. Another remote user who binds the forwarded port while it is down cannot produce it. The CLI also refuses a TCP relay address that has no relay credentials. The relay still answers clients that send no nonce with the plain v1 `{"ok":true}`.
3. The remote shell never gets direct access to the local app socket. It only gets the reverse-forwarded relay port plus `~/.bree/relay/<port>.auth`, which is written with `0600` permissions and removed when the relay stops.
4. Authentication is not authorization. `RemoteRelayCommandPolicy` rejects unlisted methods, command-bearing startup parameters, invalid selectors, and every parameter outside the selected method’s explicit schema. The app then verifies a request HMAC binding the originating workspace and active local SSH controller generation, and validates targets against its live remote terminal identities (`RemoteRelayAuthorizationPolicy`); aliases translate IDs but do not grant ownership. Local/browser panels in a remote workspace are excluded. Dispatch rechecks the controller generation and live ownership before acting; replacing or retiring the controller invalidates previously admitted requests. Input, close, scrollback, and selection reads also recheck the actual terminal target, and relay reads bypass cached topology responses. `surface.split` is withheld because its local fallback can spawn a Mac PTY. `surface.create`, `pane.create`, `surface.respawn`, `surface.send_key`, workspace/window/group creation, and global listing/navigation methods are denied. The `surface.resume.*` methods are not relay methods: a binding carries a command that would run on the Mac, and the app also refuses any relay-origin binding (ecyx00/bree#14907). `notification.create_for_target` accepts no `reply_shape`; the app delivers a relayed notification with the relay origin, no reply, and the remote destination in its title. For a relay caller, `workspace.remote.status` and the `terminal_session_*` lifecycle methods return only `enabled`, `state`, and `connected` in `remote`, and omit the local `window_id` and `window_ref`. `agent.hook.enqueue` admits only Claude lifecycle events (`session-start`, `prompt-submit`, `stop`, `notification`, `session-end`, `pre-tool-use`) with `relay_backed: true` and an owned `workspace_id`/`surface_id`; the app rebuilds the hook environment from those selectors and drops host paths from the payload. `agent.hook.barrier` and decision hooks stay unavailable. Relay-side denials return `remote_relay_denied`; app-side ownership denials return `remote_relay_*_denied` without executing the requested operation.

Integration additions for the relay path:

1. Bootstrap installs `~/.bree/bin/bree` wrapper and keeps a default daemon target (`~/.bree/bin/breed-remote-current`).
2. A background `ssh -N -R` process reverse-forwards a TCP port to the authenticated local relay server. The relay address is written to `~/.bree/socket_addr` on the remote.
3. Relay startup writes `~/.bree/relay/<port>.daemon_path` so the wrapper can route each shell to the correct daemon binary when multiple local bree instances or versions coexist.
4. Relay startup writes `~/.bree/relay/<port>.auth` with the relay ID and token needed for HMAC authentication.

### Claude Code hooks

The relay shell bootstrap writes `~/.bree/relay/<port>.shell/bin/bree-claude-wrapper`, which the shell integration's `claude` shim runs. When `~/.bree/bin/bree claude-wrapper --bree-probe` succeeds (a local check with no relay round trip) it execs `bree claude-wrapper`; an older CLI without the verb gets plain `claude` with the bree shims dropped from `PATH`. `bree claude-wrapper` resolves the real `claude` from `PATH` (skipping bree shims) and, when the relay answers `system.ping`, adds one `--settings` file with relay hooks. Existing `--settings` arguments are merged into that file because Claude Code applies only the last one; launchers that put their own `--settings` and `CLAUDE_CONFIG_DIR` in front of `claude` keep both. A marker env var stops a launcher that re-resolves `claude` from stacking hooks twice, and the shim directories are dropped from `PATH` before exec. Merged copies live in `~/.bree/claude-settings/` (mode `0600`) and are pruned after 7 idle days.

Each hook runs `bree claude-hook <event>`, which always prints `{}` and exits 0. It sends `agent.hook.enqueue` with the surface from `BREE_WORKSPACE_ID`/`BREE_SURFACE_ID`, the Claude process TTY, and a payload of at most 6 KiB without `cwd` or transcript paths. `BREE_CLAUDE_HOOKS_DISABLED=1` turns both off. With no local PID to check, the app shows this status only on a live pane that the hooks reported for, and clears it when the relay connection drops.

The shim only sees launches from a shell that bree started. A Claude session whose shell never saw bree, such as one inside a tmux server that was running before bree attached to it, or one a supervisor restarted, has no `BREE_*` variables and no shim on `PATH`. For those, run `~/.bree/bin/bree claude-hook install` once on the host. It adds the same hook events to Claude's user settings (`$CLAUDE_CONFIG_DIR/settings.json`, else `~/.claude/settings.json`; `--settings-file <path>` picks another file), keeps every other setting, and can be repeated; `bree claude-hook uninstall` removes only these entries. Launchers that merge the user's `~/.claude/settings.json` into their own `--settings` pick the hooks up too. The installed commands, `bree claude-hook --user-settings <event>`:

- do nothing outside bree, and when the CLI is missing;
- step aside when the shim already added hooks to this Claude (the wrapper's marker variable together with its `BREE_CLAUDE_PID` naming this process; a marker inherited from a wrapped Claude that started the tmux server does not count), and for a Claude process that has another Claude process above it, such as `claude -p` run by an agent's tool call;
- inside tmux, when a bree client is attached to the hook's tmux session (or a session grouped with it), route to that client: they ask tmux for the pane's window and the attached clients, prefer a client whose current window holds the pane and then the most recently active one, read its `BREE_SOCKET_PATH`, `BREE_WORKSPACE_ID` and `BREE_SURFACE_ID` from `/proc/<pid>/environ` (Linux; same user only), and send the client's TTY as `caller_tty`. If that client's relay port has no auth file any more (a persistent remote terminal that outlived a reconnect), they follow the slot named by the persistent daemon above the client to the port that leases it now. Inside tmux they never use the pane's own `BREE_*` variables, which come from whichever shell started the tmux server, so with no bree client attached they do nothing. Outside tmux they need `BREE_SOCKET_PATH`, `BREE_WORKSPACE_ID` and `BREE_SURFACE_ID` from their own environment and never fall back to `~/.bree/socket_addr`, which can name another workspace's relay;
- share one 3-second budget between the tmux queries and the relay round trip, inside the 5-second hook timeout they declare, so Claude always gets `{}`.

Install and uninstall rewrite the file only when the hooks change: an uninstall with no settings file creates nothing, numbers keep their exact text, and a `hooks` value that is not an object is refused rather than replaced. The installed commands call the stable `~/.bree/bin/bree`, so they survive upgrades.

Every Claude session in one tmux session reports to the one bree surface attached to it. Claude reads hooks when a session starts, so sessions that were already running pick them up only after a restart (for example `claude --resume <id>`, or the launcher's own resume).

### Protocol and flags

All relay commands use v2 JSON-RPC. Flags map to JSON params via `flagToParamKey` (e.g. `--workspace` → `workspace_id`). Boolean flags (`--focus`) accept `true`/`false`/`1`/`0`/`yes`/`no` and are sent as JSON booleans.

Environment fallbacks:
- `BREE_WORKSPACE_ID` — used as `workspace_id` when `--workspace` is not provided
- `BREE_SURFACE_ID` — used as `surface_id` when `--surface` is not provided

### Migration notes

**Core discovery over SSH/Mosh**:

```sh
bree --json rpc system.ping '{}'
bree --json rpc system.capabilities '{}'
bree --json list-workspaces
```

`breed-remote` also supports the command forms `bree --json ping` and
`bree --json capabilities`. The `rpc` subcommand sends the method name exactly:
`rpc ping` and `rpc capabilities` are not aliases for the `system.*` methods.
A `method_not_found` response is a failure, even if an older client printed it
without a failing exit status. The remote daemon exits 1 for server denials and
unknown-method responses.

Through the authenticated relay, `workspace.list` returns
`{"scope":"remote_workspace","workspaces":[{"id":"<owner UUID>","title":"<owner title>"}]}`.
It lists only the originating workspace, regardless of which local workspace is
selected. An optional `workspace_id` must resolve to that same owner;
`--window`, other workspace IDs, short handles, and additional selectors are
rejected. Local window IDs, selection/order, daemon/connection state, paths,
credentials, and conversation metadata are omitted. Unrestricted local callers
retain the full response.

`system.capabilities` returns `protocol`, `version`, `scope: "remote_workspace"`,
and only method names with reviewed relay parameter contracts. These names are
not grants: each call must still satisfy its parameter schema, authenticated
connection generation, and live workspace/surface ownership checks. No local
socket path, access mode, or unrelated mobile capabilities are returned.

**SSH/Mosh 経由の基本情報の取得**:
上記の `system.ping`、`system.capabilities`、`list-workspaces` を使用してください。
`breed-remote` では `bree --json ping` と `bree --json capabilities` も使用できます。
`rpc` はメソッド名をそのまま送信するため、`rpc ping` と `rpc capabilities` は別名として
扱われません。`method_not_found` は成功ではなく、リモートデーモンはサーバー側の拒否や
不明なメソッドに対して終了コード 1 を返します。

リレー経由の `workspace.list` は、認証された接続元ワークスペースの UUID とタイトルのみを
返します。Mac で選択中のワークスペースには依存しません。任意の `workspace_id` は同じ所有者を
指す必要があり、`--window`、他のワークスペース、短縮ハンドル、追加のセレクターは拒否されます。
ウィンドウ ID、選択状態や順序、デーモンや接続の状態、パス、認証情報、会話の内容は含まれません。
通常のローカル接続の応答は変わりません。

`system.capabilities` は `protocol`、`version`、`scope: "remote_workspace"` と、
リレーで審査済みのパラメーター定義を持つメソッド名だけを返します。メソッド名の一覧は権限の
付与ではありません。呼び出しごとにパラメーター、認証済み接続の世代、現在のワークスペースと
サーフェスの所有権を検証します。ローカルソケットのパス、アクセスモード、無関係なモバイル機能は
返しません。

**`new-workspace`**: The flag `--working-directory` was removed. It was accepted by the old relay but sent the wrong param name (`working_directory` instead of `cwd`), so the server silently ignored it. Use `--cwd` for the working directory. The flag `--command` is now supported: it sends the command text to the new workspace's default surface after creation.

**Relay authorization (GHSA-9vmv-3hjw-j28c)**: the remote CLI exposes only the authorization allowlist, even if a command appears in its command table. `new-workspace`, `new-window`, `new-surface`, `new-pane`, `send-key`, global workspace/window listing, and focus/navigation commands are denied. Allowed surface operations require the explicit live remote target consumed by that handler; adding an unrelated owned selector does not authorize a request. Use `new-split` with the owning workspace and terminal surface IDs for a remote terminal split.

**`send` / `send-key`**: The `--text` and `--key` flags were removed. Both commands now take their argument positionally, matching the Mac CLI convention: `bree send "hello world"` and `bree send-key ctrl+c`.

**Window commands**: Prior to this release, `list-windows`, `current-window`, `new-window`, `focus-window`, and `close-window` used a v1 text protocol and returned plain-text responses (e.g. `window:abc123` per line). They now use v2 JSON-RPC and return JSON. Scripts parsing that output will need updating.

Browser and workspace group commands remain in the remote CLI command table for protocol compatibility, but all `browser.*` and `workspace.group.*` methods are denied through the reverse SSH relay. Their presence in the CLI help or command table does not grant access to local browser or workspace-group operations.
