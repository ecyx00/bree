# Notifications

bree provides a notification panel for AI agents like Claude Code, Codex, and OpenCode. Notifications appear in a dedicated panel and trigger macOS system notifications.

> For inline permission / plan / question approvals directly from the sidebar (Vibe Island-style), see **[Feed](feed.md)**. `bree hooks setup` installs the Feed bridge alongside the notification hooks covered below.

## Quick Start

```bash
# Send a notification (if bree is available)
command -v bree &>/dev/null && bree notify --title "Done" --body "Task complete"

# With fallback to macOS notifications
command -v bree &>/dev/null && bree notify --title "Done" --body "Task complete" || osascript -e 'display notification "Task complete" with title "Done"'
```

## Detection

Check if `bree` CLI is available before using it:

```bash
# Shell
if command -v bree &>/dev/null; then
    bree notify --title "Hello"
fi

# One-liner with fallback
command -v bree &>/dev/null && bree notify --title "Hello" || osascript -e 'display notification "" with title "Hello"'
```

```python
# Python
import shutil
import subprocess

def notify(title: str, body: str = ""):
    if shutil.which("bree"):
        subprocess.run(["bree", "notify", "--title", title, "--body", body])
    else:
        # Fallback to macOS
        subprocess.run(["osascript", "-e", f'display notification "{body}" with title "{title}"'])
```

## CLI Usage

```bash
# Simple notification
bree notify --title "Build Complete"

# With subtitle and body
bree notify --title "Claude Code" --subtitle "Permission" --body "Approval needed"

# Post to the panel only: record the entry in the Notifications panel, sidebar
# badge and pane ring without a native banner, for a caller that shows its own
bree notify --title "Done" --desktop false

# Notify a specific workspace/surface
bree notify --title "Done" --workspace workspace:1 --surface surface:1

# Compatibility form for older scripts
bree notify --title "Done" --tab 0 --panel 1

# Capture the returned id and dismiss exactly that notification
notification_id="$(bree notify --title "Done" --body "Task complete" --id-format uuids | awk '$1 == "OK" {print $2}')"
bree dismiss-notification --id "$notification_id"

# Clear notifications for the posting surface (same caller resolution as notify)
bree notify --clear

# Clear a workspace or surface in a specific window
bree clear-notifications --window window:1 --workspace workspace:1 --surface surface:1
```

## Navigation

Use `Cmd+Shift+U` to jump to the latest unread notification. Use `Ctrl+Cmd+U` to mark the current item as oldest unread and jump to the next latest unread. Both shortcuts are configurable in Settings > Keyboard Shortcuts and in `~/.config/bree/bree.json`.

Focusing a pane marks that pane's notifications read. A notification posted without a surface belongs to the workspace instead of to a pane (bree's own memory-pressure warning is one), so switching to the workspace marks the workspace's own notifications read. The other panes in that workspace keep their notifications and any manual or restored unread markers. "Mark Workspace as Read" in the workspace context menu still clears everything in the workspace at once.

## Native banner lifetime and notification history

bree keeps its notification record and unread state until you open, mark, or
dismiss it (subject to the existing focused-surface dismissal policy). The
native macOS presentation is separate: macOS controls how long a **Banner** is
visible and may remove it after a few seconds. bree cannot extend that native
Banner lifetime. To keep the system alert visible until you dismiss it, open
**System Settings → Notifications → bree** and choose **Alert** instead of
**Banner**. The bree notification panel remains the durable place to review
notifications regardless of that macOS presentation choice.

## Suppress only the focused surface

By default bree withdraws a delivered banner when its workspace becomes visible/active, which can retract a banner for a non-focused surface (e.g. a second agent in the same visible workspace) before you notice it. Set the opt-in flag below to `true` so the auto-withdraw fires **only** for the exact focused surface — matching the delivery gate. A banner for a non-focused surface then stays up until you focus that surface (or click/dismiss it). Workspace-visible-but-not-focused surfaces and surfaces in non-visible workspaces keep their banners; explicit "mark workspace read" and clicking/typing still clear notifications as before.

```jsonc
{
  "notifications": {
    // Default: false (legacy workspace-visibility withdraw).
    // Set to true to auto-withdraw only the exact focused surface.
    "suppressOnlyFocusedSurface": true
  }
}
```

## Suppress banners while bree is focused

By default bree skips the desktop banner only when the notification is for the pane you are looking at. A notification for another workspace or pane still shows a banner even while bree is the active app. Set the opt-in flag below to `true` to skip the desktop banner for every notification while bree is the active app. Notifications that arrive after you switch to another app show banners again. Notifications still land in the sidebar with their unread state, the notification sound and custom command still run, and phone forwarding keeps its usual focused-pane rule, since bree can be frontmost while you are away from the Mac.

```jsonc
{
  "notifications": {
    // Default: false (only the focused pane skips its banner).
    // Set to true to skip banners for every notification while bree is focused.
    "suppressWhenAppFocused": true
  }
}
```

## Notification Hooks

`bree.json` can define composable hooks that receive every notification policy as JSON on stdin and return updated JSON on stdout. Hooks are off by default; bree only runs them when `notifications.hooks` contains at least one enabled hook. Hooks can filter native banners, sidebar history, sounds, custom commands, workspace reordering, and pane flashes.

```json
{
  "notifications": {
    "hooks": [
      {
        "id": "agent-filter",
        "command": "sed 's/\"desktop\":true/\"desktop\":false/'",
        "timeoutSeconds": 20
      }
    ]
  }
}
```

Hook input and output use this shape:

```json
{
  "version": 1,
  "notification": {
    "workspaceId": "3B3F0D83-...",
    "surfaceId": "7E9C1A02-...",
    "title": "Codex",
    "subtitle": "Waiting",
    "body": "Agent needs input"
  },
  "context": {
    "cwd": "/path/to/project",
    "configPath": "/path/to/project/.bree/bree.json",
    "hookId": "agent-filter",
    "appFocused": false,
    "focusedPanel": false
  },
  "agent": {
    "kind": "claude",
    "category": "turn-complete",
    "pending": false,
    "isSubagent": true
  },
  "origin": {
    "kind": "ssh-relay",
    "value": "ssh-relay:6f1c2a7e-0000-4000-8000-000000000000"
  },
  "effects": {
    "record": true,
    "markUnread": true,
    "reorderWorkspace": true,
    "desktop": true,
    "sound": true,
    "command": true,
    "paneFlash": true
  }
}
```

Global hooks from `~/.config/bree/bree.json` run first. Project hooks from parent directories to the current workspace append after that. When the caller passed `bree notify --desktop false`, the request carries `effects: {"desktop": false}` (the same shape a hook emits) and the envelope's `effects.desktop` already starts out `false`, so a hook sees the request and can still override it. Project hooks use the same trust prompt as other project `bree.json` commands before they run. Feed approval banners also pass through these hooks; disabling `desktop` suppresses the native banner while keeping the Feed item available in bree. Set `"hooksMode": "replace"` in a project `notifications` section to ignore inherited hooks. If any hook fails, times out, or returns invalid JSON, bree uses the default notification behavior and posts a hook failure alert.

### Agent-event context

Notifications that originate from an agent completion signal (agent hooks installed by `bree hooks setup`, or bree's built-in prompt-turn detection) carry an additional read-only `agent` object so hooks can implement their own per-agent notification policy:

| Field | Description |
|----------|-------------|
| `kind` | Stable lowercase agent slug (`claude`, `codex`, `grok`, `antigravity`, …) |
| `category` | `turn-complete`, `needs-permission`, or `idle-reminder` |
| `pending` | `true` when the turn ended with background work still running |
| `isSubagent` | `true` when the event came from a nested subagent session |

The `agent` object is omitted entirely for non-agent notifications (plain `bree notify`, OSC 9/99/777 escape sequences, notifications from older bree CLIs), and individual fields are omitted when unknown. Hooks cannot modify it — patches to `agent` in hook output are ignored. The same context is exported to the hook process environment as `BREE_NOTIFICATION_AGENT_KIND`, `BREE_NOTIFICATION_AGENT_CATEGORY`, `BREE_NOTIFICATION_AGENT_PENDING` (`0`/`1`), and `BREE_NOTIFICATION_AGENT_IS_SUBAGENT` (`0`/`1`); each variable is set only when the corresponding field is present.

### Origin

The `origin` object is present only for notifications whose text came from somewhere other than this Mac: `kind` is `ssh-relay` (a `bree ssh` host), and `value` is the same string the hook process sees in `BREE_NOTIFICATION_ORIGIN` — `local` or `ssh-relay:<workspace uuid>`. Hooks cannot modify it. `notifications.command` receives the same `BREE_NOTIFICATION_ORIGIN` variable. Treat remote-origin `title`, `subtitle`, and `body` as untrusted text: use them as data (`"$BREE_NOTIFICATION_BODY"` in quotes), never interpolate them into a command, an `osascript` source string, or an `eval`. A hook that wants to stay quiet for SSH hosts can gate on it:

```sh
case "$BREE_NOTIFICATION_ORIGIN" in
  ssh-relay:*) printf '{"effects":{"sound":false}}' ;;
esac
```

With no hooks configured, notification behavior is exactly bree's built-in default — configuring a hook is the explicit opt-in that hands the delivery decision to your script. For example, to keep every built-in behavior except the banner/sound/flash for subagent completions:

```json
{
  "notifications": {
    "hooks": [
      {
        "id": "mute-subagent-completions",
        "command": "if [ \"${BREE_NOTIFICATION_AGENT_IS_SUBAGENT-0}\" = \"1\" ] && [ \"$BREE_NOTIFICATION_AGENT_CATEGORY\" = \"turn-complete\" ]; then printf '{\"effects\":{\"desktop\":false,\"sound\":false,\"paneFlash\":false}}'; fi"
      }
    ]
  }
}
```

A hook can also route events into an entirely custom notification system: disable every effect (`record`, `desktop`, `sound`, `command`, `paneFlash`, …) and call your own notifier from the hook script using the JSON on stdin. Note that bree's built-in subagent suppression (`automation.suppressSubagentNotifications`, on by default) drops subagent completion events before they reach hooks; turn it off if your hook should see subagent events and make its own decision.

## Integration Examples

### Claude Code

See the [Claude Code documentation](https://docs.anthropic.com/en/docs/claude-code) for hook configuration.

### GitHub Copilot CLI

Copilot CLI supports [hooks](https://docs.github.com/en/copilot/how-tos/use-copilot-agents/coding-agent/use-hooks) that run shell commands at key lifecycle events. Add to `~/.copilot/config.json`:

```json
{
  "hooks": {
    "userPromptSubmitted": [
      {
        "type": "command",
        "bash": "if command -v bree &>/dev/null; then bree set-status copilot_cli Running; fi",
        "timeoutSec": 3
      }
    ],
    "agentStop": [
      {
        "type": "command",
        "bash": "if command -v bree &>/dev/null; then bree notify --title 'Copilot CLI' --body 'Done'; bree set-status copilot_cli Idle; else osascript -e 'display notification \"Done\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "errorOccurred": [
      {
        "type": "command",
        "bash": "if command -v bree &>/dev/null; then bree notify --title 'Copilot CLI' --subtitle 'Error' --body \"$(cat | jq -r '.errorMessage // \"An error occurred\"' 2>/dev/null | head -c 100)\"; bree set-status copilot_cli Error; else osascript -e 'display notification \"An error occurred\" with title \"Copilot CLI\"'; fi",
        "timeoutSec": 5
      }
    ],
    "sessionEnd": [
      {
        "type": "command",
        "bash": "if command -v bree &>/dev/null; then bree clear-status copilot_cli; fi",
        "timeoutSec": 3
      }
    ]
  }
}
```

Or for repo-level hooks, create `.github/hooks/notify.json`:

```json
{
  "version": 1,
  "hooks": {
    "userPromptSubmitted": [ ... ],
    "agentStop": [ ... ]
  }
}
```

### OpenAI Codex

Add to `~/.codex/config.toml`:

```toml
notify = ["bash", "-c", "command -v bree &>/dev/null && bree notify --title Codex --body \"$(echo $1 | jq -r '.\"last-assistant-message\" // \"Turn complete\"' 2>/dev/null | head -c 100)\" || osascript -e 'display notification \"Turn complete\" with title \"Codex\"'", "--"]
```

Or create a simple script `~/.local/bin/codex-notify.sh`:

```bash
#!/bin/bash
MSG=$(echo "$1" | jq -r '."last-assistant-message" // "Turn complete"' 2>/dev/null | head -c 100)
command -v bree &>/dev/null && bree notify --title "Codex" --body "$MSG" || osascript -e "display notification \"$MSG\" with title \"Codex\""
```

Then use:
```toml
notify = ["bash", "~/.local/bin/codex-notify.sh"]
```

### OpenCode Plugin

Create `.opencode/plugins/bree-notify.js`:

```javascript
export const BreeNotificationPlugin = async ({ $, }) => {
  const notify = async (title, body) => {
    try {
      await $`command -v bree && bree notify --title ${title} --body ${body}`;
    } catch {
      await $`osascript -e ${"display notification \"" + body + "\" with title \"" + title + "\""}`;
    }
  };

  return {
    event: async ({ event }) => {
      if (event.type === "session.idle") {
        await notify("OpenCode", "Session idle");
      }
    },
  };
};
```

## Environment Variables

bree sets these in child shells:

| Variable | Description |
|----------|-------------|
| `BREE_SOCKET_PATH` | Path to control socket |
| `BREE_TAB_ID` | UUID of the current tab |
| `BREE_PANEL_ID` | UUID of the current panel |

## CLI Commands

```
bree notify [--title <text>] [--subtitle <text>] [--body <text>] [--reply] [--desktop <true|false>] [--clear] [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
bree list-notifications
bree dismiss-notification (--id <uuid|notification:<uuid>> | --all-read)
bree mark-notification-read (--id <uuid|notification:<uuid>> | --workspace <id|ref> [--surface <id|ref>] | --all)
bree open-notification --id <uuid|notification:<uuid>>
bree jump-to-unread
bree clear-notifications [--workspace <id|ref|index>] [--surface <id|ref|index>] [--window <id|ref|index>]
bree set-status <key> <value>
bree clear-status <key>
bree ping
```

## Best Practices

1. **Always check availability first** - Use `command -v bree` before calling
2. **Provide fallbacks** - Use `|| osascript` for macOS fallback
3. **Keep notifications concise** - Title should be brief, use body for details
