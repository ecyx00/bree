#!/bin/bash
# Bree is English only. Drop every non-English .lproj from the app's own
# Resources (including SwiftPM resource bundles, which resolve strings from
# their own lprojs and would otherwise follow the system language) so the
# bundle ships `en` only. Frameworks, plug-ins and extensions are signed on
# embed and are left alone.
set -euo pipefail
RES="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
[ -d "$RES" ] || exit 0
find "$RES" -type d -name '*.lproj' ! -name 'en.lproj' ! -name 'Base.lproj' -prune -exec rm -rf {} +
