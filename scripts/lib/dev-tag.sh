# shellcheck shell=bash
# Tag -> identity helpers for tagged dev builds (slug, bundle id, app path).
# Sourced by reload.sh and the scripts that must derive the same names.

# Raw slug WITHOUT the empty-input fallback: lowercase, ASCII non-[a-z0-9] -> '-',
# trimmed/collapsed. Empty when the tag has no ASCII alphanumerics. The ASCII
# class is deliberate (matches reload.sh + bree-debug-cli.sh socket/DerivedData
# naming); a locale-sensitive class would keep non-ASCII letters the slug drops.
bree_tag_slug_raw() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-+/-/g'
}

# slug: raw slug, falling back to "agent" only for an otherwise-empty result.
bree_tag_slug() {
  local cleaned
  cleaned="$(bree_tag_slug_raw "$1")"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# True iff the tag yields a real (non-empty) slug, i.e. it is not the empty-input
# fallback. Uses the SAME ASCII transform as the slug (not locale-sensitive
# [:alnum:], which would accept non-ASCII letters like "é" that the slug drops).
# Tag identity is correctness-critical (it selects the bundle id / socket / Mac
# app), so entry points must fail closed when this is false rather than let the
# tag collapse onto the shared fallback identity and target an unrelated app.
bree_tag_tag_has_alnum() {
  [[ -n "$(bree_tag_slug_raw "$1")" ]]
}

# Cap tag slugs at 64 characters. Reject instead of truncating because
# truncation could collapse two tagged builds onto the same identity.
bree_tag_tag_within_limit() {
  local slug
  slug="$(bree_tag_slug_raw "$1")"
  (( ${#slug} <= 64 ))
}

# Validate a dev-build tag before it selects an app bundle, socket,. "default" is the stable app instance sentinel, so allowing
# a dev tag to sanitize to that value would make the dev build impersonate the
# stable instance even though its bundle and socket are otherwise isolated.
bree_tag_validate_dev_tag() {
  local tag="$1" slug
  if ! bree_tag_tag_has_alnum "$tag"; then
    echo "error: --tag '$tag' has no letters or digits; pick a tag with at least one alphanumeric character" >&2
    return 1
  fi
  slug="$(bree_tag_slug_raw "$tag")"
  if [[ "$slug" == "default" ]]; then
    echo "error: --tag must not sanitize to 'default'; that tag is reserved for the stable app instance" >&2
    return 1
  fi
  if ! bree_tag_tag_within_limit "$tag"; then
    echo "error: --tag must sanitize to at most 64 characters" >&2
    return 1
  fi
}

# bundle id segment: lowercase, non-alnum -> '.', trimmed/collapsed.
bree_tag_bundle_seg() {
  local cleaned
  cleaned="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/./g; s/^\.+//; s/\.+$//; s/\.+/./g')"
  [[ -n "$cleaned" ]] || cleaned="agent"
  printf '%s' "$cleaned"
}

# The tagged macOS Debug app's bundle id.
bree_tag_mac_bundle_id() {
  printf 'com.bree.app.debug.%s' "$(bree_tag_bundle_seg "$1")"
}

# The locally-built tagged macOS Debug .app bundle path . Both the DerivedData dir AND the .app basename use the
# sanitized slug, matching reload.sh (`APP_NAME="Bree Dev ${TAG_SLUG}"`); the raw
# tag would miss for any tag whose slug differs (e.g. "Fix Foo" -> "fix-foo").
bree_tag_mac_app_path() {
  local slug
  slug="$(bree_tag_slug "$1")"
  printf '%s/Library/Developer/Xcode/DerivedData/bree-%s/Build/Products/Debug/Bree Dev %s.app' \
    "$HOME" "$slug" "$slug"
}
