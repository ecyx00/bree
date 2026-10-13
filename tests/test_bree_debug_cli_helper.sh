#!/usr/bin/env bash
# Regression test: the tag-bound debug CLI helper scrubs ambient bree env and
# routes commands through the tagged socket and tagged bundled CLI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TAG="Debug_Helper.Test"
TAG_SLUG="debug-helper-test"
TAG_BUNDLE_ID="debug.helper.test"
SOCKET_PATH="/tmp/bree-debug-${TAG_SLUG}.sock"
TMP_DIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  rm -rf "$TMP_DIR"
  rm -f "$SOCKET_PATH"
}
trap cleanup EXIT

FAKE_HOME="$TMP_DIR/home"
FAKE_CLI_DIR="$FAKE_HOME/Library/Developer/Xcode/DerivedData/bree-${TAG_SLUG}/Build/Products/Debug/Bree Dev ${TAG_SLUG}.app/Contents/Resources/bin"
FAKE_CLI="$FAKE_CLI_DIR/bree"
mkdir -p "$FAKE_CLI_DIR"
cat > "$FAKE_CLI" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "env" ]]; then
  env | sort
  exit 0
fi
printf 'fake bree argv:'
printf ' %q' "$@"
printf '\n'
EOF
chmod +x "$FAKE_CLI"

rm -f "$SOCKET_PATH"
python3 - "$SOCKET_PATH" <<'PY' >/dev/null 2>&1 &
import os
import socket
import sys
import time

path = sys.argv[1]
try:
    os.unlink(path)
except FileNotFoundError:
    pass

sock = socket.socket(socket.AF_UNIX)
sock.bind(path)
sock.listen(1)
time.sleep(60)
PY
SERVER_PID="$!"

for _ in {1..100}; do
  if [[ -S "$SOCKET_PATH" ]]; then
    break
  fi
  sleep 0.05
done

if [[ ! -S "$SOCKET_PATH" ]]; then
  echo "FAIL: test socket was not created at $SOCKET_PATH"
  exit 1
fi

OUTPUT="$(
  HOME="$FAKE_HOME" \
  BREE_TAG="$TAG" \
  BREE_SOCKET="/tmp/main-bree-legacy.sock" \
  BREE_SOCKET_PATH="/tmp/main-bree.sock" \
  BREE_SOCKET_PASSWORD="main-secret" \
  BREE_BUNDLE_ID="com.bree.app" \
  BREE_BUNDLED_CLI_PATH="/Applications/bree.app/Contents/Resources/bin/bree" \
  BREE_WORKSPACE_ID="main-workspace" \
  BREE_TAB_ID="main-tab" \
  BREE_SURFACE_ID="main-surface" \
  BREE_PANEL_ID="main-panel" \
  BREED_UNIX_PATH="/tmp/main-breed.sock" \
  BREE_DEBUG_LOG="/tmp/main-bree.log" \
  "$ROOT_DIR/scripts/bree-debug-cli.sh" env
)"

require_line() {
  local expected="$1"
  if ! grep -Fxq "$expected" <<<"$OUTPUT"; then
    echo "FAIL: expected env line not found: $expected"
    echo "$OUTPUT"
    exit 1
  fi
}

reject_prefix() {
  local prefix="$1"
  if grep -Eq "^${prefix}=" <<<"$OUTPUT"; then
    echo "FAIL: unexpected env line with prefix: $prefix"
    echo "$OUTPUT"
    exit 1
  fi
}

require_line "BREE_SOCKET_PATH=$SOCKET_PATH"
require_line "BREE_TAG=$TAG_SLUG"
require_line "BREE_BUNDLE_ID=com.bree.app.debug.${TAG_BUNDLE_ID}"
require_line "BREE_BUNDLED_CLI_PATH=$FAKE_CLI"

reject_prefix "BREE_SOCKET"
reject_prefix "BREE_SOCKET_PASSWORD"
reject_prefix "BREE_WORKSPACE_ID"
reject_prefix "BREE_TAB_ID"
reject_prefix "BREE_SURFACE_ID"
reject_prefix "BREE_PANEL_ID"
reject_prefix "BREED_UNIX_PATH"
reject_prefix "BREE_DEBUG_LOG"

# A build restored by publish-hq lives in the HQ Tag Opener cache, not DerivedData.
CACHED_CLI_DIR="$FAKE_HOME/Library/Application Support/bree/tag-app-cache/bree-${TAG_SLUG}/Bree Dev ${TAG_SLUG}.app/Contents/Resources/bin"
mkdir -p "$CACHED_CLI_DIR"
cp "$FAKE_CLI" "$CACHED_CLI_DIR/bree"
rm -rf "$FAKE_HOME/Library/Developer/Xcode/DerivedData"
OUTPUT="$(HOME="$FAKE_HOME" BREE_TAG="$TAG" "$ROOT_DIR/scripts/bree-debug-cli.sh" env)"
require_line "BREE_BUNDLED_CLI_PATH=$CACHED_CLI_DIR/bree"

echo "PASS: bree-debug-cli.sh routes through the tagged CLI/socket and scrubs ambient bree env"
