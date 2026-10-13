#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BREE_TAG:-}" ]]; then
  cat >&2 <<'EOF'
BREE_TAG is required.

Usage:
  BREE_TAG=<tag> scripts/bree-debug-cli.sh <bree-command> [args...]

Example:
  BREE_TAG=codext scripts/bree-debug-cli.sh list-workspaces
EOF
  exit 2
fi

if [[ ! "$BREE_TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "Invalid BREE_TAG: $BREE_TAG" >&2
  exit 2
fi

if [[ $# -eq 0 ]]; then
  echo "Usage: BREE_TAG=$BREE_TAG scripts/bree-debug-cli.sh <bree-command> [args...]" >&2
  exit 2
fi

sanitize_bundle() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

sanitize_path() {
  local raw="$1"
  local cleaned
  cleaned="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g')"
  if [[ -z "$cleaned" ]]; then
    cleaned="agent"
  fi
  printf '%s\n' "$cleaned"
}

tag_slug="$(sanitize_path "$BREE_TAG")"
tag_bundle_id="$(sanitize_bundle "$BREE_TAG")"

socket_path="/tmp/bree-debug-${tag_slug}.sock"
if [[ ! -S "$socket_path" ]]; then
  cat >&2 <<EOF
Tagged Bree socket not found:
  $socket_path

Launch the tagged app first:
  ./scripts/reload.sh --tag $BREE_TAG --launch
EOF
  exit 1
fi

# Same default as reload.sh: a checkout that exports BREE_DERIVED_DATA builds every tag there.
derived_data="${BREE_DERIVED_DATA:-${HOME}/Library/Developer/Xcode/DerivedData/bree-${tag_slug}}"
if [[ "$derived_data" != /* ]]; then
  echo "error: BREE_DERIVED_DATA must be an absolute path, got '$derived_data'" >&2
  exit 1
fi
cli_path="${derived_data}/Build/Products/Debug/Bree Dev ${tag_slug}.app/Contents/Resources/bin/bree"
# A fleet build restored with `bree-ci publish-hq` lives in the HQ Tag Opener cache.
cached_cli_path="${HOME}/Library/Application Support/bree/tag-app-cache/bree-${tag_slug}/Bree Dev ${tag_slug}.app/Contents/Resources/bin/bree"
if [[ ! -x "$cli_path" && -x "$cached_cli_path" ]]; then
  cli_path="$cached_cli_path"
fi
if [[ ! -x "$cli_path" ]]; then
  cat >&2 <<EOF
Tagged Bree CLI not found:
  $cli_path
  $cached_cli_path

Build the tagged app first:
  ./scripts/reload.sh --tag $BREE_TAG
EOF
  exit 1
fi

unset BREE_SOCKET
unset BREE_SOCKET_PASSWORD
unset BREE_WORKSPACE_ID
unset BREE_SURFACE_ID
unset BREE_TAB_ID
unset BREE_PANEL_ID
unset BREED_UNIX_PATH
unset BREE_DEBUG_LOG
export BREE_SOCKET_PATH="$socket_path"
export BREE_TAG="$tag_slug"
export BREE_BUNDLE_ID="com.bree.app.debug.${tag_bundle_id}"
export BREE_BUNDLED_CLI_PATH="$cli_path"
exec "$cli_path" "$@"
