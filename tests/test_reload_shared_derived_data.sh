#!/usr/bin/env bash
# reload.sh gives every tag its own DerivedData unless the checkout's owner names a warm
# one through BREE_DERIVED_DATA. A tag is not a compiler input, so tags that share a warm
# DerivedData do not recompile; a fresh per-tag directory is always a cold build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

# Use the real functions, not copies.
eval "$(awk '/^tagged_derived_data_path\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^resolve_tagged_derived_data\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
declare -F resolve_tagged_derived_data >/dev/null || fail "resolve_tagged_derived_data not found in reload.sh"

unset BREE_DERIVED_DATA
[[ "$(resolve_tagged_derived_data one 0 "")" == "$HOME/Library/Developer/Xcode/DerivedData/bree-one" ]] \
  || fail "without BREE_DERIVED_DATA the default must stay one directory per tag"
[[ "$(resolve_tagged_derived_data one 0 "")" != "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "two tags must not share a DerivedData by default"

export BREE_DERIVED_DATA="/tmp/bree warm/DerivedData"
[[ "$(resolve_tagged_derived_data one 0 "")" == "/tmp/bree warm/DerivedData" ]] || fail "BREE_DERIVED_DATA ignored"
[[ "$(resolve_tagged_derived_data one 0 "")" == "$(resolve_tagged_derived_data two 0 "")" ]] \
  || fail "tags must share the warm DerivedData when BREE_DERIVED_DATA is set"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must win over BREE_DERIVED_DATA"

export BREE_DERIVED_DATA="relative/DerivedData"
if output="$(resolve_tagged_derived_data one 0 "" 2>&1)"; then
  fail "a relative BREE_DERIVED_DATA must be rejected, got: $output"
fi
[[ "$output" == *"must be an absolute path"* ]] || fail "unclear error for a relative path: $output"
[[ "$(resolve_tagged_derived_data one 1 "/explicit/dd")" == "/explicit/dd" ]] \
  || fail "--derived-data must not be blocked by an invalid BREE_DERIVED_DATA"
unset BREE_DERIVED_DATA

# The parser must record --derived-data and the tag default must go through the resolver with it.
awk '/^    --derived-data\)/,/;;/' "$ROOT/scripts/reload.sh" | grep -q 'DERIVED_SET=1' \
  || fail "the --derived-data parser no longer sets DERIVED_SET=1"
grep -Fq 'DERIVED_DATA="$(resolve_tagged_derived_data "$TAG_SLUG" "$DERIVED_SET" "${DERIVED_DATA:-}")"' "$ROOT/scripts/reload.sh" \
  || fail "reload.sh does not resolve the tag's DerivedData through resolve_tagged_derived_data"

# bree-debug-cli.sh must look for the tagged CLI where reload.sh built it.
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sock="/tmp/bree-debug-ddtest-$$.sock"
command -v python3 >/dev/null || fail "python3 is required for the test listener"
mkfifo "$tmp/ready"
# The listener accepts until the EXIT trap kills it, and reports readiness through the FIFO.
python3 - "$sock" "$tmp/ready" <<'PY' &
import socket, sys
try:
    s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(8)
finally:
    open(sys.argv[2], "w").close()
while True:
    connection, _ = s.accept()
    connection.close()
PY
server=$!
disown "$server" 2>/dev/null || true
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock"; rm -rf "$tmp"' EXIT
read -r _ < "$tmp/ready" || true
[[ -S "$sock" ]] || fail "test socket was not created"
cli_dir="$tmp/dd/Build/Products/Debug/Bree Dev ddtest-$$.app/Contents/Resources/bin"
mkdir -p "$cli_dir"
printf '#!/bin/sh\necho shared-cli "$@"\n' > "$cli_dir/bree"; chmod +x "$cli_dir/bree"
out="$(BREE_TAG="ddtest-$$" BREE_DERIVED_DATA="$tmp/dd" "$ROOT/scripts/bree-debug-cli.sh" ping 2>&1)" \
  || fail "bree-debug-cli.sh did not find the CLI in BREE_DERIVED_DATA: $out"
[[ "$out" == *"shared-cli"* ]] || fail "bree-debug-cli.sh ran something else: $out"

# A relative --derived-data would build relative to the caller's cwd. --help keeps a
# reload.sh that accepts the path from going on to build.
if out="$(cd "$tmp" && "$ROOT/scripts/reload.sh" --derived-data relative/dd --help 2>&1)"; then
  fail "a relative --derived-data must be rejected"
fi
[[ "$out" == *"--derived-data must be an absolute path"* ]] || fail "unclear error for a relative --derived-data: $out"

# The bree shim must run the CLI from the DerivedData the tag was built into, even when
# a stale build of the same tag sits in the default per-tag directory.
tag="ddtest-$$"
link="/tmp/bree-$tag"
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock" "$link" "/tmp/bree-ddstale-$$"; rm -rf "$tmp"' EXIT
eval "$(awk '/^reload_socket_is_live\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
# The shim body is a heredoc with its own top-level braces, so the function ends at the first "}" after it.
eval "$(awk '/^write_dev_cli_shim\(\) \{/ { on = 1 } on { print } on && /<<EOF$/ { doc = 1 } on && /^EOF$/ { doc = 0 } on && !doc && /^}/ { exit }' "$ROOT/scripts/reload.sh")"
declare -F write_dev_cli_shim >/dev/null || fail "write_dev_cli_shim not found in reload.sh"
fake_home="$tmp/home"
stale_app="$fake_home/Library/Developer/Xcode/DerivedData/bree-$tag/Build/Products/Debug/Bree Dev $tag.app"
shared_app="$tmp/dd/Build/Products/Debug/Bree Dev $tag.app"
mkdir -p "$stale_app/Contents/Resources/bin"
printf '#!/bin/sh\necho stale-cli "$@"\n' > "$stale_app/Contents/Resources/bin/bree"
chmod +x "$stale_app/Contents/Resources/bin/bree"
for app in "$stale_app" "$shared_app"; do
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>LSEnvironment</key><dict><key>BREE_SOCKET_PATH</key><string>$sock</string></dict></dict></plist>
PLIST
done
ln -s "$tmp/dd" "$link"
write_dev_cli_shim "$tmp/bin/bree" "$tmp/no-fallback" "$tmp/no-pointer"
out="$(env -u BREE_SOCKET -u BREE_SOCKET_PATH -u BREE_BUNDLED_CLI_PATH HOME="$fake_home" \
  "$tmp/bin/bree" --socket "$sock" ping 2>&1)" || fail "the shim found no CLI for a shared DerivedData: $out"
[[ "$out" == "shared-cli --socket $sock ping" ]] || fail "the shim did not run the CLI built into the shared DerivedData: $out"

# The cleanup reminder must name what holds the tag's build, and never a directory other tags share.
eval "$(awk '/^tag_build_cleanup_paths\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^print_tag_cleanup_commands\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
eval "$(awk '/^print_tag_cleanup_reminder\(\) \{/,/^}/' "$ROOT/scripts/reload.sh")"
sandbox="$tmp/sandbox"
mkdir -p "$sandbox"
# Reads this test's commands out of a reminder the way a shell would after a paste, with
# pkill and rm recording their arguments, one per line, instead of running.
reminder_args() {
  local output="$1" record="$2" line=""
  : > "$record"
  (
    cd "$sandbox"
    pkill() { printf '%s\n' "$@" >> "$record"; }
    rm() { printf '%s\n' "$@" >> "$record"; }
    while IFS= read -r line; do
      [[ "$line" == *"-$$"* ]] || continue
      case "$line" in
        "  pkill "*|"  rm "*) eval "$line" || true ;;
      esac
    done <<< "$output"
  ) >/dev/null 2>&1 || true
}
has_arg() { grep -Fxq -- "$1" "$2"; }
args="$tmp/args"
ln -s "$tmp/dd" "/tmp/bree-ddstale-$$"
out="$(HOME="$fake_home" print_tag_cleanup_reminder "$tag" "$tmp/dd")"
reminder_args "$out" "$args"
has_arg "$shared_app" "$args" || fail "the reminder does not remove the current tag's app from the shared DerivedData: $out"
has_arg "$tmp/dd/Build/Products/Debug/Bree Dev ddstale-$$.app" "$args" \
  || fail "the reminder does not remove a stale tag's app from the shared DerivedData: $out"
! has_arg "$tmp/dd" "$args" || fail "the reminder suggests deleting a shared DerivedData: $out"
out="$(HOME="$fake_home" print_tag_cleanup_reminder "$tag" "$fake_home/Library/Developer/Xcode/DerivedData/bree-$tag")"
reminder_args "$out" "$args"
has_arg "$fake_home/Library/Developer/Xcode/DerivedData/bree-$tag" "$args" \
  || fail "the reminder must still remove a per-tag DerivedData: $out"

# The reminder is pasted into a shell, so a path carrying shell syntax must come back out
# as that literal path and must never run.
evil_dd="$tmp/dd \"warm\" \$(touch pwned-subst) \`touch pwned-tick\`"
evil_home="$tmp/home \"two\" \$(touch pwned-home)"
evil_tag_dir="/tmp/bree-ddbad-$$-\$(touch pwned-tag)"
trap 'kill "$server" 2>/dev/null || true; rm -f "$sock" "$link" "/tmp/bree-ddstale-$$" "/tmp/bree-ddevil-$$"; rm -rf "$tmp" "$evil_tag_dir"' EXIT
mkdir -p "$evil_dd/Build/Products/Debug" "$evil_tag_dir/Build/Products/Debug"
ln -s "$evil_dd" "/tmp/bree-ddevil-$$"
out="$(HOME="$evil_home" print_tag_cleanup_reminder "$tag" "$evil_dd")"
reminder_args "$out" "$args"
pwned="$(cd "$sandbox" && ls)"
[[ -z "$pwned" ]] || fail "pasting the reminder ran shell syntax from a path ($pwned): $out"
has_arg "$evil_dd/Build/Products/Debug/Bree Dev $tag.app" "$args" \
  || fail "the current tag's app in a DerivedData with shell syntax does not parse back to its path: $out"
has_arg "$evil_dd/Build/Products/Debug/Bree Dev ddevil-$$.app" "$args" \
  || fail "a stale tag's app behind a symlink target with shell syntax does not parse back to its path: $out"
has_arg "$evil_home/Library/Application Support/bree/breed-dev-$tag.sock" "$args" \
  || fail "a HOME with shell syntax does not parse back to its path: $out"
has_arg "Bree Dev $tag.app/Contents/MacOS/Bree Dev" "$args" || fail "the pkill pattern does not parse back to the app's process: $out"
[[ "$out" != *"pwned-tag"* ]] || fail "the reminder offers cleanup for a /tmp name that is not a tag slug: $out"

echo "PASS: reload.sh shared DerivedData default"
