package main

import (
	"strings"
	"testing"
)

func FuzzTmuxCompatArgParser(f *testing.F) {
	for _, seed := range []string{
		`new-session -d -s build -c /tmp echo ok`,
		`split-window -h -P -F #{pane_id}`,
		`capture-pane -p -S -2000`,
		`display-message -p -F #{session_name}:#{window_name}:#{pane_id}`,
		`-L bree has-session -t main`,
		`-- send-keys -l C-c Enter`,
	} {
		f.Add(seed)
	}

	f.Fuzz(func(t *testing.T, input string) {
		fields := strings.Fields(input)
		_, _, _ = splitTmuxCmd(fields)
		// The first list contains tmux flags that require values, and the second contains flag-only options.
		// Keep both lists in sync with parseTmuxArgs coverage and the source-named tmux corpus tests.
		_ = parseTmuxArgs(fields, []string{"-c", "-F", "-n", "-s", "-t", "-x", "-y", "-S", "-E"}, []string{"-A", "-b", "-d", "-D", "-h", "-J", "-L", "-N", "-p", "-P", "-R", "-U", "-v"})
	})
}

func FuzzTmuxRenderFormatSupportedSubset(f *testing.F) {
	for _, seed := range []string{
		`#{session_name}`,
		`#{window_id}:#{window_index}:#{window_name}`,
		`#{pane_id} #{pane_width}x#{pane_height}`,
		`#{unknown} #{session_name} #{also_unknown}`,
		`#[fg=#ff0000]#{pane_id}`,
	} {
		f.Add(seed)
	}

	ctx := map[string]string{
		"session_name": "bree",
		"window_id":    "@workspace",
		"window_index": "1",
		"window_name":  "main",
		"pane_id":      "%pane",
		"pane_width":   "120",
		"pane_height":  "40",
	}

	f.Fuzz(func(t *testing.T, format string) {
		_ = tmuxRenderFormat(format, ctx, "fallback")
	})
}

func FuzzTmuxSendKeysTokens(f *testing.F) {
	for _, seed := range []string{
		`Enter`,
		`C-c C-d C-z C-l`,
		`Escape Tab BSpace`,
		`printf hello Enter`,
		`38;2;255;0;0m OSC 11 truecolor`,
	} {
		f.Add(seed, false)
		f.Add(seed, true)
	}

	f.Fuzz(func(t *testing.T, input string, literal bool) {
		_ = tmuxSendKeysText(strings.Fields(input), literal)
	})
}
