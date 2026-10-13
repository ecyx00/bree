#!/usr/bin/env bash
# Regression test: a checkout that was not created through bree-hq has no
# scripts/dev-backend.sh, so a tagged reload needs an explicit way to build
# against the local dev origin instead of exiting before the build starts.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/dev-backend-origin.sh
source "$ROOT_DIR/scripts/lib/dev-backend-origin.sh"

CHECKOUT="$(mktemp -d)"
trap 'rm -rf "$CHECKOUT"' EXIT
mkdir -p "$CHECKOUT/scripts"
LOCAL_ORIGIN="http://localhost:4123"

fail() { echo "FAIL: $*" >&2; exit 1; }

# Default stays strict: no helper and no URL is an error, and the message
# names the opt-in so a contributor is not left at a dead end.
unset BREE_DEV_BACKEND_URL BREE_DEV_BACKEND_MODE
if out="$(bree_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" 2>&1)"; then
  fail "default mode resolved '$out' without the shared backend helper"
fi
[[ "$out" == *"BREE_DEV_BACKEND_MODE=local"* ]] \
  || fail "the error does not tell a non-hq checkout how to proceed: $out"
echo "PASS: default mode still requires the shared backend and names the opt-in"

# Opt-in: local mode returns the local dev origin and needs no helper.
out="$(BREE_DEV_BACKEND_MODE=local bree_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN")" \
  || fail "local mode failed without the shared backend helper"
[[ "$out" == "$LOCAL_ORIGIN" ]] || fail "local mode resolved '$out', expected '$LOCAL_ORIGIN'"
echo "PASS: BREE_DEV_BACKEND_MODE=local resolves the local dev origin"

# Local mode must not quietly accept a shared URL, and an unknown mode is an error.
if BREE_DEV_BACKEND_MODE=local BREE_DEV_BACKEND_URL="https://bree-dev-backend-1.tail137216.ts.net:3800/" \
    bree_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" >/dev/null 2>&1; then
  fail "local mode accepted BREE_DEV_BACKEND_URL"
fi
if BREE_DEV_BACKEND_MODE=bogus bree_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN" >/dev/null 2>&1; then
  fail "an unknown BREE_DEV_BACKEND_MODE was accepted"
fi
echo "PASS: local mode rejects a shared URL, and unknown modes are rejected"

# The shared path is unchanged: a valid tailnet URL still resolves.
out="$(BREE_DEV_BACKEND_URL="https://bree-dev-backend-1.tail137216.ts.net:3800" \
  bree_resolve_tagged_backend probe "$CHECKOUT" "$LOCAL_ORIGIN")" || fail "shared URL no longer resolves"
[[ "$out" == "https://bree-dev-backend-1.tail137216.ts.net:3800/" ]] || fail "shared URL resolved to '$out'"
echo "PASS: the shared backend path is unchanged"

# The caller contract in reload.sh. The resolver tests above would still pass if
# reload.sh stopped handing over its local origin, or baked a shared backend URL
# into a local-mode app, so pin both.
RELOAD="$ROOT_DIR/scripts/reload.sh"
grep -Fq 'bree_resolve_tagged_backend "$TAG_SLUG" "$PWD" "$BREE_DEV_ORIGIN"' "$RELOAD" \
  || fail "reload.sh must pass its local dev origin to bree_resolve_tagged_backend"
awk '
  /if \[\[ "\$\{BREE_DEV_BACKEND_MODE:-remote\}" != "local" \]\]; then/ { guarded = 1; next }
  guarded && /export BREE_DEV_BACKEND_URL="\$BREE_DEV_ORIGIN"/ { found = 1 }
  guarded && /^  fi$/ { guarded = 0 }
  !guarded && /export BREE_DEV_BACKEND_URL=/ { unguarded = 1 }
  END { exit (found && !unguarded) ? 0 : 1 }
' "$RELOAD" || fail "reload.sh must export BREE_DEV_BACKEND_URL only outside local mode"
echo "PASS: reload.sh passes its local origin and never exports a backend URL in local mode"
