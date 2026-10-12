#!/usr/bin/env bash
# Zips a built Bree.app for release.
# Usage: scripts/package-bree.sh <Bree.app> <version> <out-dir>
# Writes <out-dir>/Bree-<version>-arm64.zip and <zip>.sha256. Called by build-bree.sh --package.
set -euo pipefail
APP="${1:?usage: package-bree.sh <Bree.app> <version> <out-dir>}"
VERSION="${2:?missing version}"
OUT="${3:?missing out-dir}"
[[ -d "$APP" ]] || { echo "error: not a directory: $APP" >&2; exit 1; }
ZIP="$OUT/Bree-${VERSION}-arm64.zip"
mkdir -p "$OUT"
rm -f "$ZIP" "$ZIP.sha256"
/usr/bin/ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
echo "Packaged: $ZIP"
cat "$ZIP.sha256"
