# bree-tui

`bree-tui` is the Rust TUI multiplexer in this repository. It keeps a tree of machines, sessions, workspaces, screens, panes, tabs, terminals, and browsers. Its public CLI and SDKs expose those resources through `bree.protocol/2`.

## Documentation

- [Docs index](docs/README.md)
- [Getting started](docs/getting-started.md)
- [Remote daemon and clients](docs/remote.md)
- [Remote workspace RPC contract](spec/remote-rpc.md)
- [Concepts](docs/concepts.md)
- [Keyboard](docs/keyboard.md)
- [Mouse](docs/mouse.md)
- [Configuration](docs/configuration.md)
- [Machines and remote sessions](docs/machines.md)
- [Public CLI](spec/cli.md)
- [SDK contract](spec/bindings.md)
- [Public resource protocol](spec/resource-api-v2.md)
- [Raw control protocol](docs/protocol.md)
- [Browser panes](docs/browser-panes.md)
- [Agent hooks](docs/agent-hooks.md)

## Build

Builds need Zig 0.16.0, a Rust toolchain, and the `ghostty` submodule initialized. The `ghostty-vt-sys` crate builds `libghostty-vt.a` from the submodule with Zig before compiling the Rust crates.

```bash
cd bree-tui
cargo build -p bree-tui
```

## Run

`machine-agent` is available only on Unix platforms.

```bash
cd bree-tui
cargo run -p bree-tui
cargo run -p bree-tui -- --session agents
cargo run -p bree-tui -- server start --session agents
cargo run -p bree-tui -- server status --session agents
cargo run -p bree-tui -- server stop --session agents
cargo run -p bree-tui -- attach --session agents
cargo run -p bree-tui -- attach --session agents --terminal <terminal-id>
cargo run -p bree-tui -- machine-agent --session agents
```

The default session is `main`. Default sockets live at `$TMPDIR/bree-tui-<uid>/<session>.sock`; use `--socket <path>` for an explicit path. Detach from an attached TUI with prefix `d`, which is `Ctrl-b d` by default.

`server start` is the canonical durable headless session command. The older
`--headless` spelling remains a compatibility alias.

`attach --terminal <id>` attaches one PTY terminal by its stable ID from `bree terminal list`. It uses the full host terminal without the sidebar, status bar, pane border, or other tabs.

Pane layout stays tiled by default. Press `Ctrl-b g` to append a terminal to the right at two-thirds of the viewport width. The existing layout keeps its width, so a continuous horizontal scrollbar appears in the status bar. Focusing a pane reveals it with an animated viewport movement. `Ctrl-b N` or `Alt-n` reapplies Zellij's automatic layout inside the focused horizontal column. `Ctrl-b +` and `Ctrl-b -` grow and shrink the focused split or column. `Ctrl-b U` undoes the latest structural layout action on the focused screen; undoing pane creation asks for confirmation before closing the pane.

The public control CLI is noun-first:

```bash
bree workspace create --name api
bree workspace current run -- cargo test
bree terminal term_0123456789abcdef0123456789abcdef screen read
bree session current events --jsonl
```

Use `bree server start|status|stop|reload-config` for one named local durable
session. `server stop` is idempotent when absent and preserves saved topology.
Shared routing options can precede the scope, as in
`bree --session agents server status`. Lifecycle JSON errors use stable codes
and do not expose raw transport or server error text.
Use the `remote` command group for authenticated network access:
`bree remote connect|ssh|forward|browser-proxy|rpc`, `remote enroll`, and
`remote known-daemons`. `remote stop` stops only a replaceable SSH sidecar.
Use `server stop` for a listener owned by `server start`; it also stops the
local owner and its workspaces. Start the owning process with `server start`
and explicit remote-listener flags.
The old top-level remote commands and `remote-stop` remain compatibility
aliases for one release cycle. Detached local startup is deferred until bree
has an explicit supervisor and readiness contract.

Cloud links can share one user-space WireGuard peer through `bree wg hub`.
The hub reads an owner-only WireGuard config, exposes an owner-only Unix SOCKS5
socket, and accepts only literal IP addresses inside `AllowedIPs`. Clients use
`remote connect --wireguard-hub <socket>`. Packagers must check that
`remote-probe --json` reports both the `wireguard-hub` and `browser-proxy`
capabilities before they ship a desktop build that requires private Cloud
routes.

Resource IDs are opaque typed strings. Selectors also accept `current` or an exact name. Duplicate names return `selector.ambiguous` with every candidate ID; use an ID to choose one. Prefix a reserved or ID-shaped name with `name:`.

Packaged builds can run as `npx bree`. The optional machine rail lets that local client switch among the current session, Unix sockets, and SSH sessions. It is disabled by default and activates when machine sidebar settings or a valid `machines` entry enable it. Packaged releases install a pinned remote binary when needed; source builds require the exact matching binary remotely. SSH remains noninteractive with strict host-key checking and disabled forwarding. See [Machines and remote sessions](docs/machines.md).

```bash
npx bree
npx bree machine-agent --session agents
npx bree ssh dev@buildbox --session agents
ssh -T dev@buildbox bree relay --session agents
```

The Unix-only `machine-agent` shares an existing local session through one outbound SSH registration with bree.cloud. It prints a one-time pairing code and opens no listener. The final command is a low-level raw JSON-lines diagnostic. Use the machine rail or `bree ssh` for the managed remote lifecycle.

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; `BREE_TUI_TERM` can override the terminal runtime default, with `BREE_MUX_TERM` retained as a legacy fallback.

## Browser ownership

Browser tabs are attach-only. bree-tui never discovers or launches Chrome and never owns browser profiles, cookies, or targets. A live bree-browser process publishes its ephemeral loopback CDP endpoint and stable tab-to-target mapping over the trusted local control socket. If that provider disappears, the canonical tab and layout remain and reconnect when the provider returns. `BREE_MUX_CDP_URL` remains an explicit development-only endpoint.

bree-browser starts its bundled TUI with the upstream Vercel `agent-browser` provider enabled. New terminal shells inherit a caller-local agent-browser session and a `browser.provider` plugin backed by the same bree-browser process, so ordinary `agent-browser snapshot`, `click`, `fill`, and related commands operate on a browser tab in that terminal's canonical workspace instead of spawning or auto-discovering another Chrome. Selection is deterministic and does not read any frontend's active/focus state; set `BREE_TUI_BROWSER_TAB_ID` to choose an exact stable tab when a workspace contains several browser tabs.

## Development

```bash
cd bree-tui
cargo test
```

The smoke scripts expect a built `bree-tui` binary unless `BREE_TUI_BIN` is set.

```bash
cd bree-tui
cargo build -p bree-tui
python3 scripts/smoke-tui.py
python3 scripts/smoke-attach.py
```
