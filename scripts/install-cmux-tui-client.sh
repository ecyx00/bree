#!/usr/bin/env bash
# Installs a locally built cmux-tui client into an app bundle as
# Contents/Resources/bin/cmux-tui. Bree builds it from cmux-tui/ with cargo
# (see reload.sh); nothing is downloaded.
#
#   CMUX_TUI_CLIENT_LOCAL=<binary> scripts/install-cmux-tui-client.sh <app-path>
#     [--require-capability <name>]...
set -euo pipefail

usage() { sed -n '2,7p' "$0"; }

APP_PATH=""
REQUIRED_CAPABILITIES=()
while (( $# )); do
  case "$1" in
    --require-capability) shift; REQUIRED_CAPABILITIES+=("${1:?--require-capability needs a value}") ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 64 ;;
    *) APP_PATH="$1" ;;
  esac
  shift
done
[[ -n "$APP_PATH" && -d "$APP_PATH/Contents" ]] || { echo "error: app bundle not found at '${APP_PATH:-<missing>}'" >&2; exit 1; }
[[ -f "${CMUX_TUI_CLIENT_LOCAL:-}" ]] || { echo "error: CMUX_TUI_CLIENT_LOCAL not found: ${CMUX_TUI_CLIENT_LOCAL:-<unset>}" >&2; exit 1; }
DEST_DIR="$APP_PATH/Contents/Resources/bin"
DEST="$DEST_DIR/cmux-tui"
mkdir -p "$DEST_DIR"
install -m 755 "$CMUX_TUI_CLIENT_LOCAL" "$DEST"

probe="$("$DEST" remote-probe --json 2>/dev/null || true)"
[[ "$probe" == *'"app":"cmux-tui"'* ]] || {
  echo "error: installed binary does not probe as cmux-tui: $probe" >&2
  exit 1
}
# Bash 3.2 treats an empty array as unset under nounset.
for capability in ${REQUIRED_CAPABILITIES[@]+"${REQUIRED_CAPABILITIES[@]}"}; do
  [[ "$probe" == *"\"$capability\""* ]] || {
    echo "error: required cmux-tui capability is missing: $capability" >&2
    exit 1
  }
done
echo "Installed local cmux-tui client at $DEST"
