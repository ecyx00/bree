# Getting started

## Prerequisites

Builds need Zig 0.16.0, a Rust toolchain, and the `ghostty` submodule. `ghostty-vt-sys` compiles `libghostty-vt.a` from that submodule, so an uninitialized submodule fails before the TUI starts. The first `cargo run` below compiles the TUI and then starts it.

## Local session

A normal run starts an in-process mux, opens the TUI, and serves the control socket.

```bash
cd bree-tui
cargo run -p bree-tui
cargo run -p bree-tui -- --session agents
```

The default session is `main`. Quitting a local TUI shuts down that in-process session and removes its socket.

Use one command for the common interactive case. The owner lifecycle stays
explicit when you split it across terminals:

| Command | Behavior |
| --- | --- |
| `bree` | Create or attach the interactive default `main` session. |
| `bree --session NAME` | Create or attach the named interactive session. |
| `bree server start --session NAME` | Start a headless owner only. |
| `bree attach --session NAME` | Attach an existing owner; it does not create one. |

This differs from tmux or Zellij attach-or-create shortcuts by keeping server
ownership and stop behavior explicit. Use the first two forms unless another
terminal must own the server lifecycle.

When migrating a script that used an attach-or-create command, keep one owner
and one client. Run the owner in one terminal:

```bash
bree server start --session agents
```

Then attach from another terminal:

```bash
bree attach --session agents
```

The owner must stay supervised by the caller. Do not replace this with a blind
`attach` retry, because a retry cannot distinguish a missing owner from an
owner that is still becoming ready.

Press `Ctrl-b` to reveal the active prefix commands in the bottom bar. Press `Ctrl-b ?` for the full scrollable shortcut list. Right-click a pane for pane actions, or anywhere in the sidebar for sidebar actions; hold Shift while right-clicking when an inner terminal app owns mouse input.

Use `--term <value>` to set `TERM` for child PTYs. Without it, children get `xterm-256color`; the terminal runtime also honors `BREE_TUI_TERM` when no CLI value is supplied, with `BREE_MUX_TERM` retained as a legacy fallback.

## Durable server and attach

A plain `bree` run starts (or reuses) a detached headless owner for the
session and attaches to it as a client, so several `bree` runs for the same
session share one live session and detaching never ends it. `server ensure`
does the same start-or-reuse without attaching. Set
`{"server":{"detached_owner":false}}` to host the session inside the first
TUI process instead.

`server start` starts only the mux backend and control socket, in the
foreground. `server status` checks it, `server stop` stops it, and `attach`
opens a TUI on the session.

```bash
cd bree-tui
cargo run -p bree-tui -- server start --session agents
```

Attach a TUI to that session from another terminal.

```bash
cd bree-tui
cargo run -p bree-tui -- attach --session agents
```

Detach from an attached TUI with prefix `d`. With default keys, that is `Ctrl-b d`. The server keeps running, and another `attach` reconnects to the same tree. PTY tabs attach with a Ghostty VT-state replay followed by a live output stream.

PTY programs may emit inline images with the Kitty graphics protocol. bree-tui preserves those images across local, attached, and remote sessions when the outer terminal supports Kitty graphics, subject to the configured replay and transport byte limits; graphics beyond the replay budget may be omitted.

Attach one terminal without the sidebar, status bar, pane border, or other tabs:

```bash
cargo run -p bree-tui -- attach --session agents --terminal <terminal-id>
```

Use the noun-first public CLI to inspect or automate individual resources:

```bash
cargo run -p bree-tui -- workspace list
cargo run -p bree-tui -- workspace current run -- cargo test
cargo run -p bree-tui -- terminal term_0123456789abcdef0123456789abcdef attach --jsonl
```

Resource selectors accept a typed opaque ID, `current`, or an exact name. Names need not be unique. An ambiguous name returns every candidate ID without changing state.

## Remote machines

The optional machine rail keeps rendering local while it connects individual sessions through Unix sockets or SSH. It is disabled for the default local run and activates when machine sidebar settings or a valid `machines` entry enable it. The SSH connector checks the remote binary, installs the pinned packaged binary when needed, starts the named headless mux and sidecar, and reconnects without nesting a second TUI. Source builds require the exact matching binary to be installed remotely. See [Machines](machines.md).

Packaged clients use the same configuration and can start with:

```bash
npx bree
```

See [Machines](machines.md) for Unix and SSH examples, rail input, and remote setup.

To share an existing local session through bree.cloud without a public listener, run its outbound machine agent separately:

```bash
npx bree machine-agent --session agents
```

Run this command from an interactive terminal with `/dev/tty`; the agent fails closed without a controlling terminal, including on reconnects. The first registration prints the one-time code used by `+ ssh host` on bree.cloud.

## Sessions and sockets

The default socket path is:

```text
$TMPDIR/bree-tui-<uid>/<session>.sock
```

The usual default is `$XDG_RUNTIME_DIR/bree-tui-<uid>/main.sock` when `XDG_RUNTIME_DIR` is set, then `$TMPDIR/bree-tui-<uid>/main.sock`, then `/tmp/bree-tui-<uid>/main.sock`. `--session <name>` changes the final file name. `--socket <path>` bypasses the session-derived path. Server-started child processes receive both `BREE_TUI_SOCKET` and legacy `BREE_MUX_SOCKET` with the socket path.

## Isolated products on top of bree-tui

A program that builds its own product on bree-tui, such as an agent orchestrator or a test harness, must own a dedicated session. It must not share `main` or a person's interactive session. The session is the isolation unit: each session has its own control socket, workspace tree, and durable state subtree, so `server stop`, `session reset-state`, or a crash in one session never touches another.

```bash
bree server start --session <product>-<instance> --headless
bree --session <product>-<instance> workspace create --name task-1
bree server stop --session <product>-<instance>
```

Put the product name and an instance discriminator in the session name, for example `firstmate-a1b2c3`. Two installations of one product then coexist on one machine without cross-matching each other's workspaces. Address every call with `--session <name>` or the exact `--socket` path, and store the typed resource IDs a mutation returns instead of resolving by display name later.

The default config path is shared with the person's own bree-tui and can enable a machine provider or key remaps the product does not expect. Point `BREE_TUI_CONFIG` at a product-owned config file. Sessions already keep separate state subtrees under the platform state directory; pass `--state <path>` only when the product must keep its state out of the shared root entirely.

## Platforms and XDG

bree-tui supports macOS and Linux; Windows support via ConPTY is planned for phase 2. The TUI config path resolves `BREE_TUI_CONFIG`, then legacy `BREE_MUX_CONFIG`, then `$XDG_CONFIG_HOME/bree/bree-tui.json` or `~/.config/bree/bree-tui.json`. Existing `mux.json` files remain supported and are used when `bree-tui.json` is absent.

Browser tabs attach to a live bree-browser provider. bree-tui does not launch Chrome or manage browser profiles; `browser.cdp_url` is a development-only override.

## Development flow

Run tests from `bree-tui/`.

```bash
cargo test
```

Run the smoke scripts against a built binary. Set `BREE_TUI_BIN` to test a non-default binary.

```bash
cargo build -p bree-tui
python3 scripts/smoke-tui.py
python3 scripts/smoke-attach.py
```

This checkout does not contain `scripts/mux-dev.sh`; use the cargo and smoke commands above for the TUI flow.
