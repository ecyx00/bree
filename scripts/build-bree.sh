#!/usr/bin/env bash
# Builds the Release Bree app (bundle id com.bree.app).
# Usage: scripts/build-bree.sh [--install] [--package]
#   --install  copy the bundle to /Applications/Bree.app, quitting only a running Bree.app.
#   --package  stamp the Bree version from VERSION, sign ad hoc, and write
#              dist/Bree-<version>-arm64.zip plus a .sha256 (release artifact, host arch only).
# --package does not touch /Applications.
# It never touches any other app in /Applications.
set -euo pipefail

BREE_RELEASE_BUNDLE_ID="com.bree.app"
BREE_APP_NAME="Bree"
BREE_INSTALL_PATH="/Applications/Bree.app"
DERIVED_DATA="$HOME/Library/Developer/Xcode/DerivedData/bree-release"
INSTALL=0
PACKAGE=0

for arg in "$@"; do
  case "$arg" in
    --install) INSTALL=1 ;;
    --package) PACKAGE=1 ;;
    *) echo "error: unknown argument: $arg" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
cd "$(dirname "$SELF")/.."

BREE_VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$BREE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: VERSION must be MAJOR.MINOR.PATCH, got '$BREE_VERSION'" >&2; exit 1; }

# Xcode build phases need zig and cargo; append so system tools keep priority.
export PATH="$PATH:/opt/homebrew/opt/zig@0.16/bin:/opt/homebrew/opt/rustup/bin"
export BREE_GHOSTTYKIT_PREPROVISIONED=1

# Release binaries must not carry the build machine's paths (they embed the user name).
# Remap every absolute root to a neutral one for Swift, C/ObjC and Rust. Later maps win, so
# the broad $HOME map comes first. Paths are derived at runtime, never hard-coded.
REPO_ROOT="$PWD"
CARGO_ROOT="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_ROOT="${RUSTUP_HOME:-$HOME/.rustup}"
PATH_MAP_PAIRS=("$HOME=/home" "$CARGO_ROOT=/cargo" "$RUSTUP_ROOT=/rustup" "$DERIVED_DATA=/build" "$REPO_ROOT=/bree")
SWIFT_PATH_FLAGS=""; C_PATH_FLAGS=""; RUST_PATH_FLAGS=""
for pair in "${PATH_MAP_PAIRS[@]}"; do
  SWIFT_PATH_FLAGS+=" -file-prefix-map $pair -debug-prefix-map $pair"
  C_PATH_FLAGS+=" -ffile-prefix-map=$pair"
  RUST_PATH_FLAGS+=" --remap-path-prefix=$pair"
done
export RUSTFLAGS="${RUSTFLAGS:-}${RUST_PATH_FLAGS}"
export BREE_PATH_MAP_CFLAGS="$C_PATH_FLAGS"

# Production Bree never comes from an incremental build: drop stale intermediates first.
rm -rf "$DERIVED_DATA/Build/Intermediates.noindex"

# The Xcode project once carried keychain-access-groups, which demands a
# provisioning profile, so override it. The path must be absolute: a relative one is resolved
# per target and breaks SwiftPM package targets (swift-crypto).
# Local install on this Mac: build the host arch only and skip dSYMs (a universal build
# with dSYMs ran the 14 GB disk out of space).
xcodebuild \
  -project bree.xcodeproj \
  -scheme bree \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  PRODUCT_BUNDLE_IDENTIFIER="$BREE_RELEASE_BUNDLE_ID" \
  BREE_AUTH_CALLBACK_SCHEME=bree \
  BREE_SIDEBAR_EXTENSION_POINT_ID="${BREE_RELEASE_BUNDLE_ID}.bree.sidebar" \
  CODE_SIGN_IDENTITY=- \
  ONLY_ACTIVE_ARCH=YES \
  DEBUG_INFORMATION_FORMAT=dwarf \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_ENTITLEMENTS="$PWD/Resources/bree.entitlements" \
  DEVELOPMENT_TEAM= \
  OTHER_SWIFT_FLAGS="\$(inherited)$SWIFT_PATH_FLAGS" \
  OTHER_CFLAGS="\$(inherited)$C_PATH_FLAGS" \
  OTHER_LDFLAGS="\$(inherited) -Wl,-S" \
  clean build

PRODUCTS_DIR="$DERIVED_DATA/Build/Products/Release"
BUILT_APP="$PRODUCTS_DIR/bree.app"
APP_PATH="$PRODUCTS_DIR/${BREE_APP_NAME}.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "error: built app not found at $BUILT_APP" >&2
  exit 1
fi

# Bree is English only: the "Strip Non-English Localizations" build phase must have run.
if find "$BUILT_APP/Contents/Resources" -type d -name '*.lproj' ! -name en.lproj ! -name Base.lproj | grep -q .; then
  echo "error: non-English .lproj directories remain in $BUILT_APP" >&2
  exit 1
fi

# Stage under the final name so the renamed bundle is never half-written.
STAGING="$PRODUCTS_DIR/.${BREE_APP_NAME}.build-$$.app"
rm -rf "$STAGING"
/bin/cp -cR "$BUILT_APP" "$STAGING"
INFO_PLIST="$STAGING/Contents/Info.plist"
for key in CFBundleName CFBundleDisplayName; do
  /usr/libexec/PlistBuddy -c "Set :${key} ${BREE_APP_NAME}" "$INFO_PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :${key} string ${BREE_APP_NAME}" "$INFO_PLIST"
done
# Bree has its own version (VERSION file); the upstream MARKETING_VERSION is bree's.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${BREE_VERSION}" "$INFO_PLIST"
# Release identity: the executable is Bree (Activity Monitor shows this name). Nothing else
# resolves Contents/MacOS/bree; the bundled CLI is Resources/bin/bree and stays as is.
mv "$STAGING/Contents/MacOS/bree" "$STAGING/Contents/MacOS/${BREE_APP_NAME}"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable ${BREE_APP_NAME}" "$INFO_PLIST"
# Permission prompts come from the localized InfoPlist.strings (UTF-16); say Bree there.
python3 -I - "$STAGING/Contents" <<'PY'
import glob, plistlib, sys
info = sys.argv[1] + "/Info.plist"
plist = plistlib.load(open(info, "rb"))
for key, value in plist.items():
    if key.endswith("UsageDescription") and isinstance(value, str):
        plist[key] = value.replace("bree", "Bree")
plistlib.dump(plist, open(info, "wb"))
for path in glob.glob(sys.argv[1] + "/Resources/*.lproj/InfoPlist.strings"):
    raw = open(path, "rb").read()
    enc = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8"
    text = raw.decode(enc)
    if "bree" in text:
        open(path, "wb").write(text.replace("bree", "Bree").encode(enc))
PY
xattr -cr "$STAGING" || true
# The plist edit invalidated the seal; re-sign (Bree Local Code Signing if present, else ad hoc) with the keychain-free entitlements.
# A release package is always ad hoc: a local certificate means nothing on another Mac.
if [[ "$PACKAGE" -eq 1 ]]; then SIGN_IDENTITY="-"; else SIGN_IDENTITY="$("$PWD/scripts/bree-sign-identity.sh")"; fi
/usr/bin/codesign --force --sign "$SIGN_IDENTITY" --timestamp=none --generate-entitlement-der \
  --entitlements Resources/bree.entitlements "$STAGING"
rm -rf "$APP_PATH"
mv "$STAGING" "$APP_PATH"
echo "Built: $APP_PATH"

if [[ "$PACKAGE" -eq 1 ]]; then
  "$PWD/scripts/package-bree.sh" "$APP_PATH" "$BREE_VERSION" "$PWD/dist"
fi

if [[ "$INSTALL" -eq 1 ]]; then
  # Match only the exact Bree install path; bree.app never matches this pattern.
  bree_process_pattern='^/Applications/Bree\.app/Contents/MacOS/'
  if pgrep -f "$bree_process_pattern" >/dev/null 2>&1; then
    osascript -e "tell application id \"${BREE_RELEASE_BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      pgrep -f "$bree_process_pattern" >/dev/null 2>&1 || break
      sleep 0.5
    done
    pkill -f "$bree_process_pattern" || true
  fi
  rm -rf "$BREE_INSTALL_PATH"
  /usr/bin/ditto "$APP_PATH" "$BREE_INSTALL_PATH"
  echo "Installed: $BREE_INSTALL_PATH"
fi
