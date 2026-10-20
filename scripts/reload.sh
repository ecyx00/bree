#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELOAD_ORIGINAL_ARGS=("$@")
# shellcheck source=scripts/lib/dev-tag.sh
source "$SCRIPT_DIR/lib/dev-tag.sh"


APP_NAME="Bree Dev"
BUNDLE_ID="com.bree.app.debug"
BASE_APP_NAME="Bree Dev"
DERIVED_DATA=""
NAME_SET=0
BUNDLE_SET=0
DERIVED_SET=0
TAG=""
LAUNCH=0
BUILD_ONLY=0
BREE_DEBUG_LOG=""
BREE_DEV_PORT=""
BREE_DEV_PORT_END=""
BREE_DEV_PORT_RANGE=""
BREE_DEV_ORIGIN=""
BREE_DEV_API_BASE_URL_VALUE=""
BREE_AUTH_WWW_ORIGIN_VALUE=""
BREE_WWW_ORIGIN_VALUE=""
PROD_AUTH=0
CLI_PATH=""
NO_GLOBAL_CLI_LINKS="${BREE_RELOAD_NO_GLOBAL_CLI_LINKS:-0}"
# Matches BreeStateDirectory (non-TCC ~/.local/state/bree) where the app/CLI now
# read the last-socket-path markers (https://github.com/ecyx00/bree/issues/5146).
# Resolve the real account home via getpwuid (the same syscall
# homeDirectoryForCurrentUser uses) rather than $HOME, which a shell can override.
# perl ships with macOS and returns the full home path even when it contains spaces;
# `dscl ... | awk` mis-parses such paths because dscl wraps a value with spaces onto
# a second line. `|| true` keeps the lookup from aborting the script under
# `set -euo pipefail`; an empty result falls back to $HOME.
_bree_account_home="$(perl -e 'print((getpwuid($<))[7])' 2>/dev/null || true)"
LAST_SOCKET_PATH_DIR="${_bree_account_home:-$HOME}/.local/state/bree"
LEGACY_SOCKET_PATH_DIR="${_bree_account_home:-$HOME}/Library/Application Support/bree"
SWIFT_FRONTEND_WORKAROUND=0
XCODEBUILD_STARTED=0
XCODEBUILD_OUTPUT_VALID=0
XCODEBUILD_CLEANED_OUTPUTS=0
CAN_PUBLISH_RELOAD_STATE=1
RELOAD_PUBLICATION_SKIP_REASON=""

reload_socket_is_live() {
  local socket_path="$1"
  [[ -S "$socket_path" ]] || return 1
  if command -v perl >/dev/null 2>&1; then
    # A listener with a saturated Unix-socket backlog can leave a blocking
    # connect() parked forever. Make the probe non-blocking and give the
    # kernel at most two seconds to complete it. A timeout (or an
    # indeterminate probe error) is treated as live so stale cleanup never
    # races a listener that is merely unable to accept right now.
    perl -MFcntl=:DEFAULT -MSocket -MIO::Select -MErrno=EAGAIN,EWOULDBLOCK,EINPROGRESS,EALREADY,EISCONN,ECONNREFUSED,ENOENT -e '
      my $path = shift;
      exit 1 unless -S $path;
      socket(my $socket, PF_UNIX, SOCK_STREAM, 0) or exit 0;
      my $flags = fcntl($socket, F_GETFL, 0);
      defined($flags) && fcntl($socket, F_SETFL, $flags | O_NONBLOCK) or exit 0;
      if (connect($socket, sockaddr_un($path))) {
        close($socket);
        exit 0;
      }
      my $connect_error = 0 + $!;
      unless ($connect_error == EINPROGRESS || $connect_error == EALREADY
          || $connect_error == EAGAIN || $connect_error == EWOULDBLOCK) {
        close($socket);
        exit(($connect_error == ECONNREFUSED || $connect_error == ENOENT) ? 1 : 0);
      }
      my $selector = IO::Select->new($socket);
      my @ready = $selector->can_write(2);
      unless (@ready) {
        close($socket);
        exit 0;
      }
      my $error_bytes = getsockopt($socket, SOL_SOCKET, SO_ERROR);
      unless (defined($error_bytes)) {
        close($socket);
        exit 0;
      }
      my $socket_error = unpack("i", $error_bytes);
      close($socket);
      exit 0 if $socket_error == 0 || $socket_error == EISCONN;
      exit 1 if $socket_error == ECONNREFUSED || $socket_error == ENOENT;
      exit 0;
    ' "$socket_path" >/dev/null 2>&1
    return $?
  fi
  if command -v nc >/dev/null 2>&1 && nc -z -U -w 2 "$socket_path" </dev/null >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

reload_cleanup_tag_state_with_lock() {
  local socket_path="$1"
  local slug="$2"
  local marker_path="$3"
  local legacy_marker_path="$4"
  local tmp_marker="$5"
  local pointer_path="$6"
  local publish_socket_path="${7:-}"
  local publish_cli_path="${8:-}"
  local lock_path="${socket_path}.lock"
  perl -MFcntl=:DEFAULT -MFcntl=:flock -MSocket -MIO::Select -MFile::Basename=dirname -MFile::Temp=tempfile -MErrno=EEXIST,ECONNREFUSED,ENOENT,EAGAIN,EWOULDBLOCK,EINPROGRESS,EALREADY,EISCONN -e '
    my ($socket_path, $lock_path, $slug, @discovery_paths) = @ARGV;
    my ($publish_socket_path, $publish_cli_path) = ("", "");
    if (@discovery_paths >= 6) {
      $publish_cli_path = pop @discovery_paths;
      $publish_socket_path = pop @discovery_paths;
    }
    my $pointer_path = pop @discovery_paths;
    my $pointer_lock_path = "${pointer_path}.lock";
    my $created_lock = 0;
    my $fh;

    sub current_path_matches_handle {
      my ($path, $before) = @_;
      my @after = lstat($path);
      return @after && $before->[0] == $after[0] && $before->[1] == $after[1];
    }

    sub unlink_created_lock {
      my ($path, $handle_stat, $created) = @_;
      unlink($path) if $created && current_path_matches_handle($path, $handle_stat);
    }

    sub read_owned_discovery_file {
      my ($path) = @_;
      sysopen(my $read_fh, $path, O_RDONLY | O_NOFOLLOW) or return;
      my @identity = stat($read_fh);
      unless (@identity && (($identity[2] & 0170000) == 0100000)
          && $identity[4] == $< && $identity[3] == 1
          && $identity[7] >= 0 && $identity[7] <= 4096) {
        close($read_fh);
        return;
      }
      my $value = "";
      my $count = sysread($read_fh, $value, 4097);
      close($read_fh);
      return unless defined($count) && $count <= 4096;
      $value =~ s/^\s+|\s+$//g;
      return (\@identity, $value);
    }

    sub clear_matching_discovery_file {
      my ($path, $expected, $is_suffix) = @_;
      my ($before, $value) = read_owned_discovery_file($path);
      return 1 unless $before;
      my $matches = $is_suffix
        ? length($value) >= length($expected) && substr($value, -length($expected)) eq $expected
        : $value eq $expected;
      return 1 unless $matches;

      my ($after, $current) = read_owned_discovery_file($path);
      return 0 unless $after && $before->[0] == $after->[0] && $before->[1] == $after->[1];
      my $still_matches = $is_suffix
        ? length($current) >= length($expected) && substr($current, -length($expected)) eq $expected
        : $current eq $expected;
      return 0 unless $still_matches;
      return unlink($path) || $! == ENOENT;
    }

    sub socket_is_live_or_unknown {
      my ($path) = @_;
      return 0 unless -S $path;
      socket(my $probe, PF_UNIX, SOCK_STREAM, 0) or return 1;
      my $flags = fcntl($probe, F_GETFL, 0);
      return 1 unless defined($flags) && fcntl($probe, F_SETFL, $flags | O_NONBLOCK);
      if (connect($probe, sockaddr_un($path))) {
        close($probe);
        return 1;
      }
      my $connect_error = 0 + $!;
      unless ($connect_error == EINPROGRESS || $connect_error == EALREADY
          || $connect_error == EAGAIN || $connect_error == EWOULDBLOCK) {
        close($probe);
        return ($connect_error == ECONNREFUSED || $connect_error == ENOENT) ? 0 : 1;
      }
      my $selector = IO::Select->new($probe);
      my @ready = $selector->can_write(2);
      unless (@ready) {
        close($probe);
        return 1;
      }
      my $error_bytes = getsockopt($probe, SOL_SOCKET, SO_ERROR);
      unless (defined($error_bytes)) {
        close($probe);
        return 1;
      }
      my $socket_error = unpack("i", $error_bytes);
      close($probe);
      return 1 if $socket_error == 0 || $socket_error == EISCONN;
      return 0 if $socket_error == ECONNREFUSED || $socket_error == ENOENT;
      return 1;
    }

    sub write_discovery_file {
      my ($path, $value) = @_;
      return 0 unless defined($value) && length($value) <= 4095 && $value !~ /[\r\n\0]/;
      my $directory = dirname($path);
      return 0 unless -d $directory;
      my @target = lstat($path);
      if (@target) {
        return 0 unless (($target[2] & 0170000) == 0100000)
            && $target[4] == $< && $target[3] == 1;
      } elsif ($! != ENOENT) {
        return 0;
      }
      my ($temporary_fh, $temporary_path) = eval {
        tempfile(".bree-discovery.XXXXXX", DIR => $directory, UNLINK => 0)
      };
      return 0 unless $temporary_fh && $temporary_path;
      my $ok = print {$temporary_fh} $value, "\n";
      $ok = 0 unless close($temporary_fh);
      unless ($ok && rename($temporary_path, $path)) {
        unlink($temporary_path);
        return 0;
      }
      return 1;
    }

    sub acquire_owned_file_lock {
      my ($path) = @_;
      my $lock_fh;
      for (1 .. 3) {
        if (sysopen($lock_fh, $path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0600)) {
          last;
        }
        return unless $! == EEXIST;
        if (sysopen($lock_fh, $path, O_RDWR | O_NOFOLLOW)) {
          last;
        }
        return unless $! == ENOENT;
      }
      return unless $lock_fh;

      my @handle_identity = stat($lock_fh);
      unless (@handle_identity && (($handle_identity[2] & 0170000) == 0100000)
          && $handle_identity[4] == $< && $handle_identity[3] == 1) {
        close($lock_fh);
        return;
      }
      my $locked = eval {
        local $SIG{ALRM} = sub { die "pointer lock timeout\n" };
        alarm 10;
        my $result = flock($lock_fh, LOCK_EX);
        alarm 0;
        $result;
      };
      alarm 0;
      unless ($locked) {
        close($lock_fh);
        return;
      }

      my @path_identity = lstat($path);
      unless (@path_identity && $path_identity[0] == $handle_identity[0]
          && $path_identity[1] == $handle_identity[1]) {
        flock($lock_fh, LOCK_UN);
        close($lock_fh);
        return;
      }
      return $lock_fh;
    }

    # Claim the lock inode before unlinking anything. If a replacement listener
    # follows the same protocol, either it owns this lock or we do; there is no
    # unlocked unlink window between the liveness check and cleanup.
    if (sysopen($fh, $lock_path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0600)) {
      $created_lock = 1;
    } elsif ($! == EEXIST && sysopen($fh, $lock_path, O_RDWR | O_NOFOLLOW)) {
      $created_lock = 0;
    } else {
      exit 1;
    }

    my @lock_stat = stat($fh);
    unless (@lock_stat && (($lock_stat[2] & 0170000) == 0100000)
        && $lock_stat[4] == $< && $lock_stat[3] == 1
        && flock($fh, LOCK_EX | LOCK_NB)) {
      close($fh);
      unlink($lock_path) if $created_lock;
      exit 1;
    }

    # The non-blocking probe has a bounded poll deadline. A timeout or any
    # indeterminate result protects the path; only ECONNREFUSED/ENOENT prove
    # that the listener is stale. Age and inode timestamps are never consulted.
    if (socket_is_live_or_unknown($socket_path)) {
      unlink_created_lock($lock_path, \@lock_stat, $created_lock);
      flock($fh, LOCK_UN);
      close($fh);
      exit 1;
    }

    # Remove only a current-user socket inode. A regular file, symlink, or
    # foreign-owned node is protected even when no listener answers.
    my @socket_stat = lstat($socket_path);
    if (@socket_stat) {
      unless (($socket_stat[2] & 0170000) == 0140000 && $socket_stat[4] == $<
          && $socket_stat[3] == 1) {
        unlink_created_lock($lock_path, \@lock_stat, $created_lock);
        flock($fh, LOCK_UN);
        close($fh);
        exit 1;
      }
      my @current_socket_stat = lstat($socket_path);
      if (@current_socket_stat && $current_socket_stat[0] == $socket_stat[0]
          && $current_socket_stat[1] == $socket_stat[1]) {
        unlink($socket_path) or do {
          flock($fh, LOCK_UN);
          close($fh);
          exit 1;
        };
      }
    }

    # Marker cleanup and (for a successful tagged reload) marker publication
    # stay inside the same lock ownership window. A replacement listener cannot
    # publish new state until every conditional removal and write has finished.
    if (length($publish_socket_path)) {
      unless (write_discovery_file($discovery_paths[0], $publish_socket_path)
          && write_discovery_file($discovery_paths[2], $publish_socket_path)
          && clear_matching_discovery_file($discovery_paths[1], $socket_path, 0)) {
        flock($fh, LOCK_UN);
        close($fh);
        exit 1;
      }
    } else {
      for my $marker (@discovery_paths) {
        unless (clear_matching_discovery_file($marker, $socket_path, 0)) {
          flock($fh, LOCK_UN);
          close($fh);
          exit 1;
        }
      }
    }
    # The pointer is global across tags, so its own persistent lock must cover
    # the final ownership check and unlink. A per-tag socket lock alone cannot
    # exclude another tag publishing a replacement pointer.
    my $pointer_lock_fh = acquire_owned_file_lock($pointer_lock_path);
    unless ($pointer_lock_fh) {
      flock($fh, LOCK_UN);
      close($fh);
      exit 1;
    }
    my $cli_suffix = "/Bree Dev ${slug}.app/Contents/Resources/bin/bree";
    my $pointer_ok = length($publish_cli_path)
      ? write_discovery_file($pointer_path, $publish_cli_path)
      : clear_matching_discovery_file($pointer_path, $cli_suffix, 1);
    unless ($pointer_ok) {
      flock($pointer_lock_fh, LOCK_UN);
      close($pointer_lock_fh);
      flock($fh, LOCK_UN);
      close($fh);
      exit 1;
    }
    flock($pointer_lock_fh, LOCK_UN);
    close($pointer_lock_fh);

    # Do not unlink a lock pathname that was replaced while we held the old
    # inode. This also handles a listener that intentionally recreated its lock.
    my @current_lock_stat = lstat($lock_path);
    if (@current_lock_stat && $current_lock_stat[0] == $lock_stat[0]
        && $current_lock_stat[1] == $lock_stat[1]) {
      unlink($lock_path) or do {
        flock($fh, LOCK_UN);
        close($fh);
        exit 1;
      };
    }
    flock($fh, LOCK_UN);
    close($fh);
    exit 0;
  ' "$socket_path" "$lock_path" "$slug" "$marker_path" "$legacy_marker_path" "$tmp_marker" "$pointer_path" "$publish_socket_path" "$publish_cli_path" >/dev/null 2>&1
}

derive_socket_marker_names() {
  local bundle_id="${1:-}"
  local tag_slug="${2:-}"
  local variant_slug=""

  # Keep this table in lockstep with SocketPathMarkerFiles.variant. In
  # particular, an identifier that is not one of the known bree flavors is
  # stable (rather than an implicitly-tagged dev build), and an empty suffix
  # uses the unscoped nightly/rc/staging/dev marker name.
  bundle_id="$(printf '%s' "$bundle_id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  BREE_RELOAD_MARKER_NAME="last-socket-path"
  BREE_RELOAD_TMP_MARKER="/tmp/bree-last-socket-path"
  case "$bundle_id" in
    com.bree.app.nightly)
      BREE_RELOAD_MARKER_NAME="nightly-last-socket-path"
      BREE_RELOAD_TMP_MARKER="/tmp/bree-nightly-last-socket-path"
      ;;
    com.bree.app.nightly.*)
      variant_slug="$(sanitize_path "${bundle_id#com.bree.app.nightly.}")"
      if [[ -n "$variant_slug" ]]; then
        BREE_RELOAD_MARKER_NAME="nightly-${variant_slug}-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-nightly-${variant_slug}-last-socket-path"
      else
        BREE_RELOAD_MARKER_NAME="nightly-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-nightly-last-socket-path"
      fi
      ;;
    com.bree.app.rc)
      BREE_RELOAD_MARKER_NAME="rc-last-socket-path"
      BREE_RELOAD_TMP_MARKER="/tmp/bree-rc-last-socket-path"
      ;;
    com.bree.app.rc.*)
      variant_slug="$(sanitize_path "${bundle_id#com.bree.app.rc.}")"
      if [[ -n "$variant_slug" ]]; then
        BREE_RELOAD_MARKER_NAME="rc-${variant_slug}-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-rc-${variant_slug}-last-socket-path"
      else
        BREE_RELOAD_MARKER_NAME="rc-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-rc-last-socket-path"
      fi
      ;;
    com.bree.app.staging)
      BREE_RELOAD_MARKER_NAME="staging-last-socket-path"
      BREE_RELOAD_TMP_MARKER="/tmp/bree-staging-last-socket-path"
      ;;
    com.bree.app.staging.*)
      variant_slug="$(sanitize_path "${bundle_id#com.bree.app.staging.}")"
      if [[ -n "$variant_slug" ]]; then
        BREE_RELOAD_MARKER_NAME="staging-${variant_slug}-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-staging-${variant_slug}-last-socket-path"
      else
        BREE_RELOAD_MARKER_NAME="staging-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-staging-last-socket-path"
      fi
      ;;
    com.bree.app.debug)
      variant_slug="$(sanitize_path "$tag_slug")"
      if [[ -n "$variant_slug" ]]; then
        BREE_RELOAD_MARKER_NAME="dev-${variant_slug}-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-dev-${variant_slug}-last-socket-path"
      else
        BREE_RELOAD_MARKER_NAME="dev-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-dev-last-socket-path"
      fi
      ;;
    com.bree.app.debug.*)
      variant_slug="$(sanitize_path "${bundle_id#com.bree.app.debug.}")"
      if [[ -n "$variant_slug" ]]; then
        BREE_RELOAD_MARKER_NAME="dev-${variant_slug}-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-dev-${variant_slug}-last-socket-path"
      else
        BREE_RELOAD_MARKER_NAME="dev-last-socket-path"
        BREE_RELOAD_TMP_MARKER="/tmp/bree-dev-last-socket-path"
      fi
      ;;
  esac
}

cleanup_stale_tag_state() {
  local slug="$1"
  local socket_path="${2:-/tmp/bree-debug-${slug}.sock}"
  local publish_socket_path="${3:-}"
  local publish_cli_path="${4:-}"
  derive_socket_marker_names "${BUNDLE_ID:-}" "$slug"
  local marker_name="$BREE_RELOAD_MARKER_NAME"
  local tmp_marker="$BREE_RELOAD_TMP_MARKER"
  # The Bree dev build (BreeIdentity .breeDev) owns its own state folders; it must
  # never publish markers into bree's ~/.local/state/bree or Application Support/bree.
  if [[ "${BUNDLE_ID:-}" == "com.bree.app.debug.bree" ]]; then
    LAST_SOCKET_PATH_DIR="${_bree_account_home:-$HOME}/.local/state/bree-dev"
    LEGACY_SOCKET_PATH_DIR="${_bree_account_home:-$HOME}/Library/Application Support/Bree Dev"
  fi
  local marker_path="${LAST_SOCKET_PATH_DIR}/${marker_name}"
  local legacy_marker_path="${LEGACY_SOCKET_PATH_DIR}/${marker_name}"

  # The Perl transaction performs the liveness probe after acquiring the tag
  # lock, so validation, stale-node removal, and publication share one owner.
  local pointer_path="/tmp/bree-last-cli-path"
  if [[ -n "$publish_socket_path" ]]; then
    mkdir -p "$LAST_SOCKET_PATH_DIR" || return 1
  fi
  reload_cleanup_tag_state_with_lock \
    "$socket_path" \
    "$slug" \
    "$marker_path" \
    "$legacy_marker_path" \
    "$tmp_marker" \
    "$pointer_path" \
    "$publish_socket_path" \
    "$publish_cli_path"
}

cleanup_stale_cli_pointer_target() {
  local pointer_path="/tmp/bree-last-cli-path"
  [[ -f "$pointer_path" && ! -L "$pointer_path" ]] || return 0
  local cli_path=""
  cli_path="$(LC_ALL=C /usr/bin/head -c 4097 "$pointer_path" 2>/dev/null | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' || true)"
  (( ${#cli_path} <= 4096 )) || return 0
  [[ -n "$cli_path" ]] || return 0
  local bundle_path=""
  case "$cli_path" in
    */Contents/Resources/bin/bree)
      bundle_path="${cli_path%/Contents/Resources/bin/bree}"
      ;;
    *)
      return 0
      ;;
  esac
  local app_name="${bundle_path##*/}"
  app_name="${app_name%.app}"
  [[ "$app_name" == "Bree Dev "* ]] || return 0
  local slug="${app_name#Bree Dev }"
  [[ "$slug" =~ ^[A-Za-z0-9_-]+$ ]] || return 0
  local socket_path=""
  if [[ -x /usr/libexec/PlistBuddy && -f "$bundle_path/Contents/Info.plist" ]]; then
    socket_path="$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:BREE_SOCKET_PATH' "$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
  fi
  socket_path="$(printf '%s' "$socket_path" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  cleanup_stale_tag_state "$slug" "${socket_path:-/tmp/bree-debug-${slug}.sock}"
}

wait_for_tag_socket_lock_release() {
  local socket_path="$1"
  local lock_path="${socket_path}.lock"
  if ! command -v perl >/dev/null 2>&1; then
    RELOAD_PUBLICATION_SKIP_REASON="socket lock wait unavailable because perl was not found"
    return 1
  fi

  local wait_status=0
  if perl -MFcntl=:DEFAULT -MFcntl=:flock -MErrno=ENOENT -e '
    my ($lock_path) = @ARGV;
    sysopen(my $fh, $lock_path, O_RDWR | O_NOFOLLOW) or exit($! == ENOENT ? 0 : 4);
    my @before = stat($fh);
    exit 3 unless @before && (($before[2] & 0170000) == 0100000)
        && $before[4] == $< && $before[3] == 1;
    $SIG{ALRM} = sub { exit 2 };
    alarm 10;
    flock($fh, LOCK_EX) or exit 4;
    alarm 0;
    my @after = lstat($lock_path);
    # A clean app stop unlinks the lock pathname before releasing this inode.
    # Absence therefore proves teardown completed; a different inode means a
    # replacement instance claimed the tag and must block publication.
    exit 3 if !@after && $! != ENOENT;
    exit 3 if @after && ($before[0] != $after[0] || $before[1] != $after[1]);
    flock($fh, LOCK_UN);
    close($fh);
    exit 0;
  ' "$lock_path" >/dev/null 2>&1; then
    return 0
  else
    wait_status=$?
  fi

  case "$wait_status" in
    2) RELOAD_PUBLICATION_SKIP_REASON="timed out waiting for the previous tag socket lock to be released" ;;
    3) RELOAD_PUBLICATION_SKIP_REASON="tag socket lock identity changed while waiting for teardown" ;;
    *) RELOAD_PUBLICATION_SKIP_REASON="could not acquire the previous tag socket lock (status ${wait_status})" ;;
  esac
  return 1
}

should_skip_ghostty_cli_helper_zig_build() {
  [[ "${BREE_SKIP_ZIG_BUILD:-}" == "1" ]]
}

write_dev_cli_shim() {
  local target="$1"
  local fallback_bin="$2"
  local cli_path_file="${3:-/tmp/bree-last-cli-path}"
  local cli_path_file_literal=""
  local fallback_bin_literal=""
  local socket_probe_function=""
  printf -v cli_path_file_literal '%q' "$cli_path_file"
  printf -v fallback_bin_literal '%q' "$fallback_bin"
  socket_probe_function="$(declare -f reload_socket_is_live)"
  socket_probe_function="${socket_probe_function/reload_socket_is_live/socket_is_live}"
  mkdir -p "$(dirname "$target")"
  cat > "$target" <<EOF
#!/usr/bin/env bash
# bree dev shim (managed by scripts/reload.sh)
set -euo pipefail

CLI_PATH_FILE=${cli_path_file_literal}
SOCKET_ARG=""
EXPECT_SOCKET_VALUE=0
HAS_EXPLICIT_SOCKET=0
for arg in "\$@"; do
  if [[ "\$EXPECT_SOCKET_VALUE" == "1" ]]; then
    SOCKET_ARG="\$arg"
    EXPECT_SOCKET_VALUE=0
    HAS_EXPLICIT_SOCKET=1
    continue
  fi
  case "\$arg" in
    --socket)
      EXPECT_SOCKET_VALUE=1
      HAS_EXPLICIT_SOCKET=1
      ;;
    --socket=*)
      SOCKET_ARG="\${arg#--socket=}"
      HAS_EXPLICIT_SOCKET=1
      ;;
  esac
done

${socket_probe_function}

cli_bundle_for_path() {
  local cli_path="\$1"
  local bundle_path=""
  bundle_path="\$(cd "\$(dirname "\$cli_path")/../../.." 2>/dev/null && pwd -P)" || return 1
  [[ "\$bundle_path" == *.app && -f "\$bundle_path/Contents/Info.plist" ]] || return 1
  printf '%s\\n' "\$bundle_path"
}

bundle_socket_path() {
  local bundle_path="\$1"
  local socket_path=""
  if [[ -x /usr/libexec/PlistBuddy ]]; then
    socket_path="\$(/usr/libexec/PlistBuddy -c 'Print :LSEnvironment:BREE_SOCKET_PATH' "\$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
  fi
  if [[ -n "\$socket_path" ]]; then
    printf '%s\\n' "\$socket_path"
    return 0
  fi

  local app_name="\${bundle_path##*/}"
  app_name="\${app_name%.app}"
  if [[ "\$app_name" == "Bree Dev "* ]]; then
    local tag="\${app_name#Bree Dev }"
    [[ "\$tag" =~ ^[A-Za-z0-9_-]+\$ ]] || return 1
    printf '/tmp/bree-debug-%s.sock\\n' "\$tag"
    return 0
  fi
  return 1
}

live_cli_bundle() {
  local cli_path="\$1"
  [[ -f "\$cli_path" && -x "\$cli_path" && "\$cli_path" != "\$0" ]] || return 1
  local bundle_path=""
  bundle_path="\$(cli_bundle_for_path "\$cli_path")" || return 1
  local socket_path=""
  socket_path="\$(bundle_socket_path "\$bundle_path")" || return 1
  socket_is_live "\$socket_path" || return 1
  printf '%s\\n' "\$bundle_path"
}

if [[ -n "\${BREE_SOCKET_PATH:-}" || -n "\${BREE_SOCKET:-}" ]]; then
  HAS_EXPLICIT_SOCKET=1
fi
if [[ -n "\$SOCKET_ARG" ]]; then
  SOCKET_NAME="\$(basename "\$SOCKET_ARG")"
  if [[ "\$SOCKET_NAME" == bree-debug-*.sock ]]; then
    TAG="\${SOCKET_NAME#bree-debug-}"
    TAG="\${TAG%.sock}"
    if [[ "\$TAG" =~ ^[A-Za-z0-9_-]+$ ]]; then
      # reload.sh links /tmp/bree-<tag> to the DerivedData it built the tag into,
      # which is not the per-tag default when tags share one.
      TAG_CLI_SUFFIX="Build/Products/Debug/Bree Dev \$TAG.app/Contents/Resources/bin/bree"
      for TAG_CLI in "/tmp/bree-\$TAG/\$TAG_CLI_SUFFIX" "\$HOME/Library/Developer/Xcode/DerivedData/bree-\$TAG/\$TAG_CLI_SUFFIX"; do
        # /tmp is shared, so only trust a CLI this user owns.
        [[ -O "\$TAG_CLI" ]] || continue
        if live_cli_bundle "\$TAG_CLI" >/dev/null; then
          if [[ "\$HAS_EXPLICIT_SOCKET" == "0" ]] || socket_is_live "\$SOCKET_ARG"; then
            exec "\$TAG_CLI" "\$@"
          fi
        fi
      done
    fi
  fi
fi
if [[ -n "\${BREE_BUNDLED_CLI_PATH:-}" ]] && [[ -f "\$BREE_BUNDLED_CLI_PATH" ]] && [[ -x "\$BREE_BUNDLED_CLI_PATH" ]] && [[ "\$BREE_BUNDLED_CLI_PATH" != "\$0" ]]; then
  # Inherited terminal identity is authoritative when the caller explicitly
  # supplied a socket. For ambient calls, validate liveness only when the
  # bundle carries reload-managed socket metadata; ordinary installed bundles
  # delegate directly to their own CLI.
  BUNDLED_APP_PATH=""
  BUNDLED_SOCKET_PATH=""
  if [[ "\$HAS_EXPLICIT_SOCKET" == "1" ]]; then
    exec "\$BREE_BUNDLED_CLI_PATH" "\$@"
  elif BUNDLED_APP_PATH="\$(cli_bundle_for_path "\$BREE_BUNDLED_CLI_PATH" 2>/dev/null)" &&
       BUNDLED_SOCKET_PATH="\$(bundle_socket_path "\$BUNDLED_APP_PATH" 2>/dev/null)"; then
    if socket_is_live "\$BUNDLED_SOCKET_PATH"; then
      exec "\$BREE_BUNDLED_CLI_PATH" "\$@"
    fi
  else
    # Stable, nightly, staging, and other installed bundles need not carry the
    # reload-managed socket metadata. Preserve their inherited CLI identity.
    exec "\$BREE_BUNDLED_CLI_PATH" "\$@"
  fi
fi

CLI_PATH_OWNER="\$(stat -f '%u' "\$CLI_PATH_FILE" 2>/dev/null || stat -c '%u' "\$CLI_PATH_FILE" 2>/dev/null || echo -1)"
if [[ "\$HAS_EXPLICIT_SOCKET" == "0" && -r "\$CLI_PATH_FILE" ]] && [[ ! -L "\$CLI_PATH_FILE" ]] && [[ "\$CLI_PATH_OWNER" == "\$(id -u)" ]]; then
  CLI_PATH="\$(cat "\$CLI_PATH_FILE" 2>/dev/null || true)"
  if live_cli_bundle "\$CLI_PATH" >/dev/null; then
    exec "\$CLI_PATH" "\$@"
  fi
fi

if [[ -x ${fallback_bin_literal} ]]; then
  exec ${fallback_bin_literal} "\$@"
fi

echo "error: no reload-selected dev bree CLI found. Run ./scripts/reload.sh --tag <name> first." >&2
exit 1
EOF
  chmod +x "$target"
}

publish_reload_cli_links() {
  local cli_path="$1"
  if [[ ! -x "$cli_path" ]]; then
    return 0
  fi
  if [[ "$NO_GLOBAL_CLI_LINKS" == "1" ]]; then
    return 0
  fi

  ln -sfn "$cli_path" /tmp/bree-cli || true

  # Stable shim that always follows the last reload-selected dev CLI.
  DEV_CLI_SHIM="$HOME/.local/bin/bree-dev"
  write_dev_cli_shim "$DEV_CLI_SHIM" "/Applications/bree.app/Contents/Resources/bin/bree"
}

publish_reload_cli_path() {
  local cli_path="$1"
  if [[ ! -x "$cli_path" ]]; then
    return 0
  fi
  if [[ "$NO_GLOBAL_CLI_LINKS" == "1" ]]; then
    return 0
  fi

  reload_write_cli_pointer "/tmp/bree-last-cli-path" "$cli_path" || return 1
  publish_reload_cli_links "$cli_path"
}

reload_write_cli_pointer() {
  local target="$1"
  local value="$2"

  # The exiting app and every tag reload use this same persistent lock. The
  # pointer rename stays atomic for lock-free readers, while writers/removers
  # cannot invalidate one another between ownership validation and mutation.
  perl -MFcntl=:DEFAULT -MFcntl=:flock -MFile::Basename=dirname -MFile::Temp=tempfile -MErrno=EEXIST,ENOENT -e '
    my ($target, $value) = @ARGV;
    exit 1 if !length($value) || length($value) > 4095 || $value =~ /[\r\n\0]/;
    my $lock_path = "${target}.lock";
    my $lock_fh;
    for (1 .. 3) {
      if (sysopen($lock_fh, $lock_path, O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW, 0600)) {
        last;
      }
      exit 1 unless $! == EEXIST;
      if (sysopen($lock_fh, $lock_path, O_RDWR | O_NOFOLLOW)) {
        last;
      }
      exit 1 unless $! == ENOENT;
    }
    exit 1 unless $lock_fh;

    my @handle_identity = stat($lock_fh);
    exit 1 unless @handle_identity && (($handle_identity[2] & 0170000) == 0100000)
        && $handle_identity[4] == $< && $handle_identity[3] == 1;
    local $SIG{ALRM} = sub { exit 1 };
    alarm 10;
    flock($lock_fh, LOCK_EX) or exit 1;
    alarm 0;
    my @path_identity = lstat($lock_path);
    exit 1 unless @path_identity && $path_identity[0] == $handle_identity[0]
        && $path_identity[1] == $handle_identity[1];

    my @target_identity = lstat($target);
    if (@target_identity) {
      exit 1 unless (($target_identity[2] & 0170000) == 0100000)
          && $target_identity[4] == $< && $target_identity[3] == 1;
    } else {
      exit 1 unless $! == ENOENT;
    }

    my $directory = dirname($target);
    my ($temporary_fh, $temporary_path) = tempfile(
      ".bree-discovery.XXXXXX",
      DIR => $directory,
      UNLINK => 0,
    );
    my $ok = print {$temporary_fh} $value, "\n";
    $ok = 0 unless close($temporary_fh);
    unless ($ok && rename($temporary_path, $target)) {
      unlink($temporary_path);
      exit 1;
    }
    flock($lock_fh, LOCK_UN);
    close($lock_fh);
  ' "$target" "$value" >/dev/null 2>&1
}

reload_write_discovery_file() {
  local target="$1"
  local value="$2"
  local directory=""
  directory="$(dirname "$target")" || return 1
  local temporary=""

  # Discovery files are current-user state. Refuse symlinked or foreign-owned
  # targets, and publish through an atomic same-directory rename so an exiting
  # app can never mistake a partially-written replacement for its own marker.
  [[ ! -L "$target" ]] || return 1
  if [[ -e "$target" ]]; then
    local owner=""
    owner="$(stat -f '%u' "$target" 2>/dev/null || stat -c '%u' "$target" 2>/dev/null || echo -1)"
    [[ "$owner" == "$(id -u)" ]] || return 1
  fi
  mkdir -p "$directory" || return 1
  temporary="$(mktemp "$directory/.bree-discovery.XXXXXX")" || return 1
  if ! (umask 077; printf '%s\n' "$value" > "$temporary"); then
    rm -f -- "$temporary"
    return 1
  fi
  if ! mv -f -- "$temporary" "$target"; then
    rm -f -- "$temporary"
    return 1
  fi
}

usage() {
  cat <<'EOF'
Usage: ./scripts/reload.sh --tag <name> [options]

Options:
  --tag <name>           Required. Short tag for parallel builds (e.g., feature-xyz-lol).
                         Sets app name, bundle id, and derived data path unless overridden.
                         After a successful build, terminates any running app with this tag
                         so macOS launches the freshly-built binary on cmd-click or --launch.
  --launch               Launch the app after building. Without this flag, the script
                         builds and prints the app path but does not open it.
  --build-only           Build and validate a tagged app without replacing or
                         stopping the running tagged app, daemon, or tag state.
                         Cannot be combined with --launch.
  --prod-auth            Point this tagged Debug build at production Stack auth,
                         bree APIs, and the production Iroh broker.
                         Without it, tagged builds use the shared dev backend, which
                         needs a bree-hq checkout. Outside one, set
                         BREE_DEV_BACKEND_MODE=local to use http://localhost:<port>.
  --name <app name>      Override app display/bundle name.
  --bundle-id <id>       Override bundle identifier.
  --derived-data <path>  Override derived data path.
                         Defaults to BREE_DERIVED_DATA when set (an absolute
                         path to a DerivedData kept warm for this checkout and
                         shared by its tags), else one directory per tag.
  --no-global-cli-links  Do not update /tmp/bree-cli, /tmp/bree-last-cli-path,
                         or the ~/.local/bin/bree-dev shim. Useful for isolated dogfood.
  --swift-frontend-workaround
                         Work around Swift arm64 frontend spins for this reload
                         only by disabling batch mode, debug symbol emission,
                         and AArch64 GlobalISel. Also enabled by
                         BREE_SWIFT_FRONTEND_WORKAROUND=1.
  --swift-disable-global-isel
                         Alias for --swift-frontend-workaround.
  -h, --help             Show this help.
EOF
}

sanitize_bundle() {
  bree_tag_bundle_seg "$1"
}

sanitize_path() {
  bree_tag_slug_raw "$1"
}

is_valid_port() {
  local port="${1:-}"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$port))
  (( numeric >= 1 && numeric <= 65535 ))
}

is_positive_integer() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 1
  local numeric=$((10#$value))
  (( numeric > 0 ))
}

choose_bree_dev_port() {
  if is_valid_port "${BREE_PORT:-}"; then
    echo "$BREE_PORT"
    return 0
  fi
  if is_valid_port "${PORT:-}"; then
    echo "$PORT"
    return 0
  fi
  echo "3777"
}

choose_bree_dev_port_range() {
  if is_positive_integer "${BREE_PORT_RANGE:-}"; then
    echo "$BREE_PORT_RANGE"
    return 0
  fi
  echo "1"
}

choose_bree_dev_port_end() {
  local start="$1"
  local range="$2"
  if is_valid_port "${BREE_PORT_END:-}"; then
    echo "$BREE_PORT_END"
    return 0
  fi
  local start_num=$((10#$start))
  local range_num=$((10#$range))
  local end=$((start_num + range_num - 1))
  if (( end > 65535 )); then
    end="$start_num"
  fi
  echo "$end"
}

set_plist_env() {
  local plist="$1"
  local key="$2"
  local value="$3"
  /usr/libexec/PlistBuddy -c "Set :LSEnvironment:${key} \"${value}\"" "$plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :LSEnvironment:${key} string \"${value}\"" "$plist"
}

set_plist_url_scheme() {
  local plist="$1"
  local scheme="$2"
  /usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:1:CFBundleURLSchemes:0 \"${scheme}\"" "$plist" 2>/dev/null \
    || true
}

tagged_derived_data_path() {
  local slug="$1"
  echo "$HOME/Library/Developer/Xcode/DerivedData/bree-${slug}"
}

# A tag only changes the bundle id, names, socket and state files. None of those
# are compiler inputs, so a new tag built into a DerivedData that is already warm
# for this checkout recompiles nothing, while a fresh per-tag DerivedData is a full
# cold build. BREE_DERIVED_DATA lets whatever owns the checkout (a pool of reused
# worktrees, a fleet lease) name that warm directory once, so callers do not have
# to pass --derived-data on every reload. It must be absolute, and only one build
# may use it at a time; that is the owner's lock to hold, not this script's.
resolve_tagged_derived_data() {
  # Precedence: --derived-data, then BREE_DERIVED_DATA, then one directory per tag.
  local slug="$1" explicit_set="${2:-0}" explicit_path="${3:-}"
  if [[ "$explicit_set" -eq 1 ]]; then
    echo "$explicit_path"
    return 0
  fi
  if [[ -n "${BREE_DERIVED_DATA:-}" ]]; then
    if [[ "$BREE_DERIVED_DATA" != /* ]]; then
      echo "error: BREE_DERIVED_DATA must be an absolute path, got '$BREE_DERIVED_DATA'" >&2
      return 1
    fi
    echo "$BREE_DERIVED_DATA"
    return 0
  fi
  tagged_derived_data_path "$slug"
}

remove_app_bundle_output() {
  local path="${1:-}"
  if [[ -z "$path" || ! -e "$path" ]]; then
    return 0
  fi
  if [[ -z "${BUILD_PRODUCTS_DEBUG_DIR:-}" ]]; then
    echo "warning: refusing to remove app output without a build products directory: $path" >&2
    return 0
  fi
  case "$path" in
    "$BUILD_PRODUCTS_DEBUG_DIR"/*.app)
      rm -rf "$path"
      ;;
    *)
      echo "warning: refusing to remove unexpected app output: $path" >&2
      ;;
  esac
}

cleanup_incomplete_xcodebuild_outputs() {
  if [[ "$XCODEBUILD_CLEANED_OUTPUTS" -eq 1 ]]; then
    return 0
  fi
  XCODEBUILD_CLEANED_OUTPUTS=1
  remove_app_bundle_output "${XCODEBUILD_SOURCE_APP_PATH:-}"
  # A normal reload replaces the tagged bundle, so a stale one must not survive a
  # failed build. Build-only never writes it, and a running tagged app executes
  # from it, so leave it alone.
  if [[ "${BUILD_ONLY:-0}" -ne 1 ]]; then
    remove_app_bundle_output "${XCODEBUILD_TAG_APP_PATH:-}"
  fi
  remove_app_bundle_output "${TAG_APP_STAGING_PATH:-}"
}

validate_app_bundle() {
  local app_path="$1"
  local executable_name="$2"
  local executable_path="$app_path/Contents/MacOS/$executable_name"
  local info_plist="$app_path/Contents/Info.plist"

  if [[ ! -d "$app_path" ]]; then
    echo "error: app bundle not found after xcodebuild: $app_path" >&2
    return 1
  fi
  if [[ ! -f "$info_plist" ]]; then
    echo "error: app Info.plist not found after xcodebuild: $info_plist" >&2
    return 1
  fi
  if [[ ! -x "$executable_path" ]]; then
    echo "error: app executable not found after xcodebuild: $executable_path" >&2
    return 1
  fi
}

# Prints the rm -rf targets that hold a tag's build, each escaped for a shell. A DerivedData
# that is not the tag's own may hold other tags, so only the tag's app is removed from it.
tag_build_cleanup_paths() {
  local tag="$1" derived="${2:-}"
  local own="" link="/tmp/bree-${tag}"
  own="$(tagged_derived_data_path "$tag")"
  if [[ -z "$derived" && -L "$link" ]]; then
    derived="$(readlink "$link" 2>/dev/null || true)"
  fi
  if [[ -n "$derived" && "$derived" != "$own" && "$derived" != "$link" ]]; then
    printf '%q ' "${derived%/}/Build/Products/Debug/Bree Dev ${tag}.app"
    [[ -d "$own" ]] || return 0
  fi
  printf '%q ' "$own"
}

# Prints the commands that remove one tag's build and state. They are meant to be pasted
# into a shell, and a DerivedData, symlink target, or HOME can hold any character, so every
# argument is escaped with %q instead of being wrapped in quotes.
print_tag_cleanup_commands() {
  local tag="$1" derived="${2:-}"
  printf '  pkill -f %q\n' "Bree Dev ${tag}.app/Contents/MacOS/Bree Dev"
  printf '  rm -rf %s%q %q\n' "$(tag_build_cleanup_paths "$tag" "$derived")" "/tmp/bree-${tag}" "/tmp/bree-debug-${tag}.sock"
  printf '  rm -f %q\n' "/tmp/bree-debug-${tag}.log"
  printf '  rm -f %q\n' "$HOME/Library/Application Support/bree/breed-dev-${tag}.sock"
}

print_tag_cleanup_reminder() {
  local current_slug="$1"
  local current_derived="${2:-}"
  local path=""
  local tag=""
  local seen=" "
  local -a stale_tags=()

  while IFS= read -r -d '' path; do
    if [[ "$path" == /tmp/bree-* ]]; then
      tag="${path#/tmp/bree-}"
    elif [[ "$path" == "$HOME/Library/Developer/Xcode/DerivedData/bree-"* ]]; then
      tag="${path#"$HOME"/Library/Developer/Xcode/DerivedData/bree-}"
    else
      continue
    fi
    if [[ "$tag" == "$current_slug" ]]; then
      continue
    fi
    # Anyone can create a name under /tmp. Only a tag slug names a build of ours.
    if [[ ! "$tag" =~ ^[A-Za-z0-9_-]+$ ]]; then
      continue
    fi
    # Only surface stale debug tag builds.
    if [[ ! -d "$path/Build/Products/Debug" ]]; then
      continue
    fi
    if [[ "$seen" == *" $tag "* ]]; then
      continue
    fi
    seen="${seen}${tag} "
    stale_tags+=("$tag")
  done < <(
    # The trailing slash makes find descend when /tmp is itself a symlink.
    find /tmp/ -maxdepth 1 -name 'bree-*' -print0 2>/dev/null
    find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 1 -type d -name 'bree-*' -print0 2>/dev/null
  )

  echo
  echo "Tag cleanup status:"
  echo "  current tag: ${current_slug} (keep this running until you verify)"
  if [[ "${#stale_tags[@]}" -eq 0 ]]; then
    echo "  stale tags: none"
    echo "  stale cleanup: not needed"
  else
    echo "  stale tags:"
    for tag in "${stale_tags[@]}"; do
      echo "    - ${tag}"
    done
    echo "Cleanup stale tags only:"
    for tag in "${stale_tags[@]}"; do
      print_tag_cleanup_commands "$tag"
    done
  fi
  echo "After you verify current tag, cleanup command:"
  print_tag_cleanup_commands "$current_slug" "$current_derived"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag)
      TAG="${2:-}"
      if [[ -z "$TAG" ]]; then
        echo "error: --tag requires a value" >&2
        exit 1
      fi
      shift 2
      ;;
    --name)
      APP_NAME="${2:-}"
      if [[ -z "$APP_NAME" ]]; then
        echo "error: --name requires a value" >&2
        exit 1
      fi
      NAME_SET=1
      shift 2
      ;;
    --bundle-id)
      BUNDLE_ID="${2:-}"
      if [[ -z "$BUNDLE_ID" ]]; then
        echo "error: --bundle-id requires a value" >&2
        exit 1
      fi
      BUNDLE_ID_LOWER="$(printf '%s' "$BUNDLE_ID" | tr '[:upper:]' '[:lower:]')"
      if [[ "$BUNDLE_ID_LOWER" == "com.bree.app" || ( "$BUNDLE_ID_LOWER" == com.bree.app.* && "$BUNDLE_ID_LOWER" != com.bree.app.debug.* ) ]]; then
        echo "error: --bundle-id $BUNDLE_ID is not a com.bree.app.debug.* id; reload.sh would quit a user's running bree" >&2
        exit 1
      fi
      BUNDLE_SET=1
      shift 2
      ;;
    --launch)
      LAUNCH=1
      shift
      ;;
    --build-only)
      BUILD_ONLY=1
      shift
      ;;
    --prod-auth)
      PROD_AUTH=1
      shift
      ;;
    --derived-data)
      DERIVED_DATA="${2:-}"
      if [[ -z "$DERIVED_DATA" ]]; then
        echo "error: --derived-data requires a value" >&2
        exit 1
      fi
      if [[ "$DERIVED_DATA" != /* ]]; then
        echo "error: --derived-data must be an absolute path, got '$DERIVED_DATA'" >&2
        exit 1
      fi
      DERIVED_SET=1
      shift 2
      ;;
    --no-global-cli-links)
      NO_GLOBAL_CLI_LINKS=1
      shift
      ;;
    --swift-disable-global-isel)
      SWIFT_FRONTEND_WORKAROUND=1
      shift
      ;;
    --swift-frontend-workaround)
      SWIFT_FRONTEND_WORKAROUND=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ "$BUILD_ONLY" -eq 1 && "$LAUNCH" -eq 1 ]]; then
  echo "error: --build-only cannot be combined with --launch" >&2
  exit 1
fi

if [[ -z "$TAG" ]]; then
  echo "error: --tag is required (example: ./scripts/reload.sh --tag fix-sidebar-theme)" >&2
  usage
  exit 1
fi

# Tagged builds normally compile the base product name and stage a distinct
# tag-named bundle. An explicit base-name override removes that staging
# boundary, so build-only would overwrite the bundle a running tagged process
# can be executing from. Refuse that shape before any cleanup or build starts.
if [[ "$BUILD_ONLY" -eq 1 && "$NAME_SET" -eq 1 && "$APP_NAME" == "$BASE_APP_NAME" ]]; then
  echo "error: --build-only cannot use --name '$BASE_APP_NAME'; omit --name or choose a distinct tagged app name" >&2
  exit 1
fi

if [[ -n "$TAG" ]]; then
  if ! bree_tag_validate_dev_tag "$TAG"; then
    exit 1
  fi
  TAG_ID="$(sanitize_bundle "$TAG")"
  TAG_SLUG="$(sanitize_path "$TAG")"
  # Serialize the complete reload, including cleanup and log publication.
  # Xcode's database lock alone is too late: a losing reload's cleanup can
  # delete the active build's generated app before it finishes signing.
  if [[ "${BREE_RELOAD_TAG_LOCK_OWNER:-}" != "$PPID" ]]; then
    exec python3 "$SCRIPT_DIR/lib/tagged-reload-lock.py" \
      "$TAG_SLUG" "$0" "${RELOAD_ORIGINAL_ARGS[@]}"
  fi
  if [[ "$NAME_SET" -eq 0 ]]; then
    APP_NAME="Bree Dev ${TAG_SLUG}"
  fi
  if [[ "$BUNDLE_SET" -eq 0 ]]; then
    BUNDLE_ID="com.bree.app.debug.${TAG_ID}"
  fi
  DERIVED_DATA="$(resolve_tagged_derived_data "$TAG_SLUG" "$DERIVED_SET" "${DERIVED_DATA:-}")"
  if [[ "$BUILD_ONLY" -ne 1 ]]; then
    cleanup_stale_cli_pointer_target || true
    cleanup_stale_tag_state "$TAG_SLUG" || true
  fi
fi

BREE_DEV_PORT="$(choose_bree_dev_port)"
BREE_DEV_PORT_RANGE="$(choose_bree_dev_port_range)"
BREE_DEV_PORT_END="$(choose_bree_dev_port_end "$BREE_DEV_PORT" "$BREE_DEV_PORT_RANGE")"
BREE_DEV_ORIGIN="http://localhost:${BREE_DEV_PORT}"
if [[ -n "$TAG" && "$PROD_AUTH" -eq 0 ]]; then
  source "$PWD/scripts/lib/dev-backend-origin.sh"
  BREE_DEV_ORIGIN="$(bree_resolve_tagged_backend "$TAG_SLUG" "$PWD" "$BREE_DEV_ORIGIN")" || exit 1
  # Local mode has no shared backend to bake into the app or the Iroh broker default.
  if [[ "${BREE_DEV_BACKEND_MODE:-remote}" != "local" ]]; then
    export BREE_DEV_BACKEND_URL="$BREE_DEV_ORIGIN"
  fi
fi
BREE_DEV_API_BASE_URL_VALUE="${BREE_DEV_API_BASE_URL:-$BREE_DEV_ORIGIN}"
BREE_AUTH_WWW_ORIGIN_VALUE="$BREE_DEV_ORIGIN"
BREE_WWW_ORIGIN_VALUE="$BREE_DEV_ORIGIN"
if [[ "$PROD_AUTH" -eq 1 ]]; then
  if [[ -n "${BREE_DEV_API_BASE_URL:-}" && "$BREE_DEV_API_BASE_URL" != "https://github.com/ecyx00/bree" ]]; then
    echo "error: --prod-auth cannot use API origin '$BREE_DEV_API_BASE_URL'; production builds must use https://github.com/ecyx00/bree" >&2
    exit 1
  fi
  BREE_DEV_API_BASE_URL_VALUE="https://github.com/ecyx00/bree"
  BREE_AUTH_WWW_ORIGIN_VALUE="https://github.com/ecyx00/bree"
  BREE_WWW_ORIGIN_VALUE="https://github.com/ecyx00/bree"
fi

# Quiet logging: capture all noisy build output (xcodebuild, zig, codesign,
# plistbuddy, etc.) to a single log file. On success we print only a one-line
# summary plus the App/CLI paths. On failure we dump the log.
RELOAD_LOG="/tmp/bree-reload-${TAG_SLUG}.log"
RELOAD_START_TIME="$(date +%s)"
: > "$RELOAD_LOG"

BUILD_PRODUCTS_DEBUG_DIR=""
XCODEBUILD_SOURCE_APP_NAME="$APP_NAME"
XCODEBUILD_SOURCE_APP_PATH=""
XCODEBUILD_TAG_APP_PATH=""
TAG_APP_FINAL_PATH=""
TAG_APP_STAGING_PATH=""
if [[ -n "$DERIVED_DATA" ]]; then
  BUILD_PRODUCTS_DEBUG_DIR="${DERIVED_DATA}/Build/Products/Debug"
  if [[ -n "$TAG" ]]; then
    XCODEBUILD_SOURCE_APP_NAME="$BASE_APP_NAME"
  fi
  XCODEBUILD_SOURCE_APP_PATH="${BUILD_PRODUCTS_DEBUG_DIR}/${XCODEBUILD_SOURCE_APP_NAME}.app"
  if [[ -n "$TAG" && "$APP_NAME" != "$XCODEBUILD_SOURCE_APP_NAME" ]]; then
    XCODEBUILD_TAG_APP_PATH="${BUILD_PRODUCTS_DEBUG_DIR}/${APP_NAME}.app"
  fi
fi

# Save the original stdout/stderr so the EXIT trap can write the user-facing
# summary after the body redirect, then redirect bulk output into the log.
exec 3>&1 4>&2
exec >>"$RELOAD_LOG" 2>&1

reload_finalize() {
  local rc=$?
  trap - EXIT
  exec 1>&3 2>&4
  local elapsed=$(( $(date +%s) - RELOAD_START_TIME ))
  if [[ "$rc" -ne 0 ]]; then
    if [[ "$XCODEBUILD_STARTED" -eq 1 && "$XCODEBUILD_OUTPUT_VALID" -ne 1 ]]; then
      cleanup_incomplete_xcodebuild_outputs
      echo "==> removed incomplete xcodebuild app outputs" >&2
    elif [[ -n "${TAG_APP_STAGING_PATH:-}" && -e "$TAG_APP_STAGING_PATH" ]]; then
      remove_app_bundle_output "$TAG_APP_STAGING_PATH"
      echo "==> removed incomplete staged tagged app" >&2
    fi
    if [[ -s "$RELOAD_LOG" ]]; then
      cat "$RELOAD_LOG" >&2
    fi
    echo "" >&2
    echo "==> reload FAILED (exit $rc) after ${elapsed}s" >&2
    echo "==> log: $RELOAD_LOG" >&2
    exit "$rc"
  fi
  echo "==> reload succeeded in ${elapsed}s"
  echo "==> log: $RELOAD_LOG"
  if [[ "$BUILD_ONLY" -ne 1 && -n "${APP_PATH:-}" ]]; then
    echo
    echo "App path:"
    echo "  $APP_PATH"
  fi
  if [[ -n "${BREE_DEV_ORIGIN:-}" ]]; then
    echo
    echo "Dev web origin:"
    echo "  $BREE_DEV_ORIGIN"
    echo "Dev API origin:"
    echo "  $BREE_DEV_API_BASE_URL_VALUE"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      echo "Dev web command:"
      echo "  cd web && BREE_PORT=$BREE_DEV_PORT BREE_PORT_RANGE=$BREE_DEV_PORT_RANGE BREE_PORT_END=$BREE_DEV_PORT_END BREE_AUTH_CALLBACK_SCHEME=bree-dev-$TAG_SLUG bun dev"
    fi
  fi
  if [[ "$BUILD_ONLY" -ne 1 && -x "${CLI_PATH:-}" ]]; then
    echo
    echo "CLI path:"
    echo "  $CLI_PATH"
    echo "CLI helpers:"
    if [[ "$NO_GLOBAL_CLI_LINKS" == "1" ]]; then
      echo "  preserved existing global bree CLI links (--no-global-cli-links)"
    elif [[ "${CAN_PUBLISH_RELOAD_STATE:-1}" -ne 1 ]]; then
      echo "  not published: ${RELOAD_PUBLICATION_SKIP_REASON:-tag discovery ownership could not be verified}"
    else
      echo "  /tmp/bree-cli ..."
      echo "  $HOME/.local/bin/bree-dev ..."
      if [[ -n "${BREE_SHIM_TARGET:-}" ]]; then
        echo "  $BREE_SHIM_TARGET ..."
      fi
      echo "If your shell still resolves the old bree, run: rehash"
    fi
  fi
  if [[ "${SWIFT_FRONTEND_WORKAROUND_EFFECTIVE:-0}" -eq 1 ]]; then
    echo
    echo "Swift workaround:"
    echo "  batch mode, debug symbols, and AArch64 GlobalISel disabled for this reload"
  fi
  if [[ "$BUILD_ONLY" -eq 1 ]]; then
    echo
    echo "Build-only validation complete. The running tagged app, breed, and tag state were left unchanged."
    if [[ -n "${TAG_APP_STAGING_PATH:-}" && -e "$TAG_APP_STAGING_PATH" ]]; then
      remove_app_bundle_output "$TAG_APP_STAGING_PATH"
      echo "==> removed temporary build-only artifact"
    fi
  elif [[ "$LAUNCH" -eq 0 ]]; then
    echo
    echo "Build complete. Pass --launch to open the app, or cmd-click the path above."
  fi
}
trap reload_finalize EXIT

# Tell the user we're starting (visible even though body output is redirected).
echo "==> reload starting (tag: ${TAG}, log: ${RELOAD_LOG})" >&3

# Managed profiles already supply their own SourcePackages path. Warm that
# exact path from local seeds before resolution; cache warming never downloads
# on the reload path, and populated native state is never replaced.
if [[ "${GITHUB_ACTIONS:-false}" != "true" && -n "${BREE_SOURCE_PACKAGES_DIR:-}" && "${BREE_LOCAL_CACHE_PREFLIGHT:-1}" == "1" ]]; then
  CACHE_PREFLIGHT_RECEIPT="${RELOAD_LOG}.cache.json"
  if python3 "$PWD/scripts/local-build-cache-preflight.py" \
      --local-only --source-packages-dir "$BREE_SOURCE_PACKAGES_DIR" --receipt "$CACHE_PREFLIGHT_RECEIPT"; then
    if python3 - "$CACHE_PREFLIGHT_RECEIPT" <<'PY'
import json
import sys
with open(sys.argv[1]) as stream:
    verified = json.load(stream).get("ghosttykit", {}).get("verified_install") is True
raise SystemExit(0 if verified else 1)
PY
    then
      export BREE_GHOSTTYKIT_PREPROVISIONED=1
    fi
  else
    echo "==> Build cache preflight unavailable; using normal dependency setup."
  fi
fi

# CI can verify/download the xcframework before deciding whether Zig is needed.
# Fail closed if that caller assertion is inconsistent with the checkout.
if [[ "${BREE_GHOSTTYKIT_PREPROVISIONED:-0}" == "1" ]]; then
  if [[ ! -d "$PWD/GhosttyKit.xcframework" ]]; then
    echo "error: BREE_GHOSTTYKIT_PREPROVISIONED=1 but GhosttyKit.xcframework is missing" >&2
    exit 1
  fi
  echo "==> Reusing caller-provisioned GhosttyKit.xcframework"
else
  "$PWD/scripts/ensure-ghosttykit.sh"
fi

if should_skip_ghostty_cli_helper_zig_build; then
  export BREE_SKIP_ZIG_BUILD=1
fi

XCODEBUILD_ARGS=(
  -project bree.xcodeproj
  -scheme bree
  -configuration Debug
  -destination 'platform=macOS'
)
if [[ -n "$DERIVED_DATA" ]]; then
  XCODEBUILD_ARGS+=(-derivedDataPath "$DERIVED_DATA")
fi
if [[ -n "${BREE_SOURCE_PACKAGES_DIR:-}" ]]; then
  mkdir -p "$BREE_SOURCE_PACKAGES_DIR"
  XCODEBUILD_ARGS+=(-clonedSourcePackagesDirPath "$BREE_SOURCE_PACKAGES_DIR")
fi
if [[ "${BREE_DISABLE_AUTOMATIC_PACKAGE_RESOLUTION:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(-disableAutomaticPackageResolution)
fi
if [[ -z "$TAG" ]]; then
  XCODEBUILD_ARGS+=(
    INFOPLIST_KEY_CFBundleName="$APP_NAME"
    INFOPLIST_KEY_CFBundleDisplayName="$APP_NAME"
  )
fi
XCODEBUILD_ARGS+=(PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID")
# Scope the sidebar ExtensionKit point per build tag so concurrent dev builds (and
# their tagged sample extensions) don't share one point. The host bundle declares
# the point under Contents/Extensions, and Info.plist carries the same identifier.
if [[ -n "$TAG" ]]; then
  XCODEBUILD_ARGS+=(BREE_SIDEBAR_EXTENSION_POINT_ID="${BUNDLE_ID}.bree.sidebar")
fi
# Forward explicit BREE_SKIP_ZIG_BUILD to xcodebuild run script phases.
if [[ "${BREE_SKIP_ZIG_BUILD:-}" == "1" ]]; then
  XCODEBUILD_ARGS+=(BREE_SKIP_ZIG_BUILD=1)
fi
SWIFT_OTHER_FLAGS='$(inherited)'
if [[ "$SWIFT_FRONTEND_WORKAROUND" -eq 1 || "${BREE_SWIFT_FRONTEND_WORKAROUND:-}" == "1" || "${BREE_SWIFT_DISABLE_GLOBAL_ISEL:-}" == "1" ]]; then
  SWIFT_FRONTEND_WORKAROUND_EFFECTIVE=1
  echo "==> Swift frontend workaround enabled for this reload"
  XCODEBUILD_ARGS+=(SWIFT_ENABLE_BATCH_MODE=NO)
  XCODEBUILD_ARGS+=(DEBUG_INFORMATION_FORMAT=)
  XCODEBUILD_ARGS+=(GCC_GENERATE_DEBUGGING_SYMBOLS=NO)
  SWIFT_OTHER_FLAGS+=" -Xllvm -aarch64-enable-global-isel-at-O=-1"
else
  SWIFT_FRONTEND_WORKAROUND_EFFECTIVE=0
fi
if [[ "${BREE_SWIFT_INCREMENTAL_DIAGNOSTICS:-0}" == "1" ]]; then
  SWIFT_INCREMENTAL_DIAGNOSTICS_EFFECTIVE=1
  echo "==> Swift incremental diagnostics enabled for this reload"
  # These Swift driver diagnostics report scheduling/rebuild decisions and job
  # lifecycle without changing the incremental dependency decision itself.
  SWIFT_OTHER_FLAGS+=" -v -driver-show-incremental -driver-show-job-lifecycle -driver-time-compilation"
  XCODEBUILD_ARGS+=(-showBuildTimingSummary)
else
  SWIFT_INCREMENTAL_DIAGNOSTICS_EFFECTIVE=0
fi
if [[ "${BREE_RELOAD_APP_EMIT_MODULE:-0}" != "1" ]]; then
  # A dev build runs the app; nothing imports its Swift module (only breeTests,
  # which reload never builds) and no Objective-C includes its generated header.
  # Xcode's integrated driver still emits the module in a separate job that
  # type-checks every declaration in the app. The standalone driver with
  # -no-emit-module-separately emits none, the same change #14364 made for
  # breeTests; the app's Debug configuration generates no Objective-C header.
  # Settings are per target, so packages and the CLI are unchanged. App edits
  # rebuild ~13 s faster on a 12-core runner. lldb's po/expr in app frames need
  # the module: set BREE_RELOAD_APP_EMIT_MODULE=1 to emit it again.
  # shellcheck disable=SC2016 # Xcode expands $(TARGET_NAME), not the shell
  XCODEBUILD_ARGS+=(
    'SWIFT_USE_INTEGRATED_DRIVER=$(BREE_RELOAD_INTEGRATED_DRIVER_$(TARGET_NAME):default=YES)'
    BREE_RELOAD_INTEGRATED_DRIVER_bree=NO
    'SWIFT_INSTALL_MODULE=$(BREE_RELOAD_INSTALL_MODULE_$(TARGET_NAME):default=YES)'
    BREE_RELOAD_INSTALL_MODULE_bree=NO
  )
  # shellcheck disable=SC2016
  SWIFT_OTHER_FLAGS+=' $(BREE_RELOAD_SWIFT_FLAGS_$(TARGET_NAME))'
  XCODEBUILD_ARGS+=(BREE_RELOAD_SWIFT_FLAGS_bree=-no-emit-module-separately)
fi
if [[ "$SWIFT_OTHER_FLAGS" != '$(inherited)' ]]; then
  XCODEBUILD_ARGS+=("OTHER_SWIFT_FLAGS=$SWIFT_OTHER_FLAGS")
fi
XCODEBUILD_ARGS+=(build)

if [[ -n "$BUILD_PRODUCTS_DEBUG_DIR" ]]; then
  mkdir -p "$BUILD_PRODUCTS_DEBUG_DIR"
  cleanup_incomplete_xcodebuild_outputs
  XCODEBUILD_CLEANED_OUTPUTS=0
fi

XCODEBUILD_LOCK_DIR="${TMPDIR:-/tmp}/bree-xcodebuild-$(id -u).locks"
XCODEBUILD_LOCK_CONCURRENCY="${BREE_XCODEBUILD_LOCK_CONCURRENCY:-5}"
if ! is_positive_integer "$XCODEBUILD_LOCK_CONCURRENCY"; then
  echo "error: xcodebuild lock concurrency must be a positive integer" >&2
  exit 1
fi
XCODEBUILD_LOCK_WAIT_SECONDS="${BREE_XCODEBUILD_LOCK_WAIT_SECONDS:-1800}"
if ! is_positive_integer "$XCODEBUILD_LOCK_WAIT_SECONDS"; then
  echo "error: xcodebuild lock wait timeout must be a positive integer" >&2
  exit 1
fi
# Xcode 26's SWBBuildService is a per-user singleton. Too many concurrent
# xcodebuild invocations can trample that daemon, so cap reload.sh builds at
# five per user while still allowing useful parallel tagged builds.
XCODEBUILD_STARTED=1
python3 -c '
import array
import fcntl
import os
import select
import signal
import socket
import sys

lock_dir = sys.argv[1]
concurrency = int(sys.argv[2])
wait_seconds = int(sys.argv[3])
command = sys.argv[4:]

try:
    os.makedirs(lock_dir, mode=0o700, exist_ok=True)
except OSError as exc:
    raise SystemExit(f"error: create lock dir: {exc}")

def open_slot(slot):
    lock_path = os.path.join(lock_dir, f"slot-{slot}.lock")
    try:
        fd = os.open(lock_path, os.O_CREAT | os.O_RDWR, 0o600)
    except OSError as exc:
        raise SystemExit(f"error: open lock slot: {exc}")

    try:
        os.set_inheritable(fd, True)
    except OSError as exc:
        os.close(fd)
        raise SystemExit(f"error: fcntl lock fd: {exc}")
    return fd, lock_path

def try_acquire_any_slot():
    for slot in range(1, concurrency + 1):
        fd, lock_path = open_slot(slot)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return fd, slot, lock_path
        except BlockingIOError:
            os.close(fd)
        except OSError as exc:
            os.close(fd)
            raise SystemExit(f"error: flock: {exc}")
    return None, None, None

def stop_waiters(children):
    for pid in children:
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except OSError:
            pass
    for pid in children:
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass
        except OSError:
            pass

def wait_for_any_slot():
    parent_sock, child_sock = socket.socketpair()
    children = []
    try:
        for slot in range(1, concurrency + 1):
            pid = os.fork()
            if pid == 0:
                try:
                    parent_sock.close()
                    fd, _ = open_slot(slot)
                    fcntl.flock(fd, fcntl.LOCK_EX)
                    payload = array.array("i", [fd])
                    child_sock.sendmsg(
                        [f"{slot}".encode()],
                        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, payload)],
                    )
                except BaseException:
                    os._exit(1)
                os._exit(0)
            children.append(pid)
        child_sock.close()

        ready, _, _ = select.select([parent_sock], [], [], wait_seconds)
        if not ready:
            raise SystemExit(
                f"error: timed out waiting for xcodebuild slot after {wait_seconds}s; "
                "check for stuck xcodebuild processes"
            )

        msg, ancdata, _, _ = parent_sock.recvmsg(
            16,
            socket.CMSG_LEN(array.array("i").itemsize),
        )
        received = array.array("i")
        for level, ctype, data in ancdata:
            if level == socket.SOL_SOCKET and ctype == socket.SCM_RIGHTS:
                received.frombytes(data[: array.array("i").itemsize])
        if not received:
            raise SystemExit("error: failed to receive xcodebuild lock slot")
        fd = received[0]
        os.set_inheritable(fd, True)
        try:
            slot = int(msg.decode())
        except ValueError:
            slot = 0
        lock_path = os.path.join(lock_dir, f"slot-{slot}.lock")
        return fd, slot, lock_path
    finally:
        stop_waiters(children)
        parent_sock.close()
        try:
            child_sock.close()
        except OSError:
            pass

fd, slot, lock_path = try_acquire_any_slot()
if fd is None:
    msg = (
        f"==> xcodebuild concurrency limit reached ({concurrency}); "
        "waiting for the next available slot...\n"
    )
    # reload.sh saves the original stderr on fd 4 before redirecting to the
    # log file. Surface the wait notice to the terminal so the user knows
    # they are queued, not hung. Fall back to stderr (the log) if fd 4 is
    # unavailable (e.g. when this script is run standalone).
    try:
        os.write(4, msg.encode())
    except OSError:
        sys.stderr.write(msg)
        sys.stderr.flush()
    fd, slot, lock_path = wait_for_any_slot()

try:
    os.execvp(command[0], command)
except OSError as exc:
    raise SystemExit(f"error: exec: {exc}")
' "$XCODEBUILD_LOCK_DIR" "$XCODEBUILD_LOCK_CONCURRENCY" "$XCODEBUILD_LOCK_WAIT_SECONDS" xcodebuild "${XCODEBUILD_ARGS[@]}"
sleep 0.2
if LC_ALL=C grep -q 'BUILD INTERRUPTED' "$RELOAD_LOG"; then
  echo "error: xcodebuild reported ** BUILD INTERRUPTED **; refusing to reuse DerivedData app artifacts" >&2
  exit 65
fi

FALLBACK_APP_NAME="$BASE_APP_NAME"
SEARCH_APP_NAME="$APP_NAME"
APP_EXECUTABLE_NAME="$SEARCH_APP_NAME"
if [[ -n "$TAG" ]]; then
  SEARCH_APP_NAME="$BASE_APP_NAME"
  APP_EXECUTABLE_NAME="$BASE_APP_NAME"
fi
if [[ -n "$DERIVED_DATA" ]]; then
  APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${SEARCH_APP_NAME}.app"
  if [[ ! -d "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_PATH="${DERIVED_DATA}/Build/Products/Debug/${FALLBACK_APP_NAME}.app"
    APP_EXECUTABLE_NAME="$FALLBACK_APP_NAME"
  fi
else
  APP_BINARY="$(
    find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${SEARCH_APP_NAME}.app/Contents/MacOS/${SEARCH_APP_NAME}" -print0 \
    | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
    | sort -nr \
    | head -n 1 \
    | cut -d' ' -f2-
  )"
  if [[ -n "${APP_BINARY}" ]]; then
    APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
  fi
  if [[ -z "${APP_PATH}" && "$SEARCH_APP_NAME" != "$FALLBACK_APP_NAME" ]]; then
    APP_BINARY="$(
      find "$HOME/Library/Developer/Xcode/DerivedData" -path "*/Build/Products/Debug/${FALLBACK_APP_NAME}.app/Contents/MacOS/${FALLBACK_APP_NAME}" -print0 \
      | xargs -0 /usr/bin/stat -f "%m %N" 2>/dev/null \
      | sort -nr \
      | head -n 1 \
      | cut -d' ' -f2-
    )"
    if [[ -n "${APP_BINARY}" ]]; then
      APP_PATH="$(dirname "$(dirname "$(dirname "$APP_BINARY")")")"
      APP_EXECUTABLE_NAME="$FALLBACK_APP_NAME"
    fi
  fi
fi
if [[ -z "${APP_PATH}" || ! -d "${APP_PATH}" ]]; then
  echo "${APP_NAME}.app not found in DerivedData" >&2
  exit 1
fi
validate_app_bundle "$APP_PATH" "$APP_EXECUTABLE_NAME"
XCODEBUILD_OUTPUT_VALID=1

if [[ "${SWIFT_INCREMENTAL_DIAGNOSTICS_EFFECTIVE:-0}" -eq 1 ]]; then
  incremental_receipt="${RELOAD_LOG}.incremental.json"
  if python3 "$SCRIPT_DIR/ci/swift_incremental_diagnostics.py" \
      --log "$RELOAD_LOG" --output "$incremental_receipt"; then
    echo "==> Swift incremental diagnostics: $incremental_receipt"
  else
    echo "==> Swift incremental diagnostics parser failed; raw evidence remains in $RELOAD_LOG" >&2
  fi
fi

if [[ "$BUILD_ONLY" -ne 1 && -n "${TAG_SLUG:-}" ]]; then
  TMP_COMPAT_DERIVED_LINK="/tmp/bree-${TAG_SLUG}"
  if [[ "$DERIVED_DATA" != "$TMP_COMPAT_DERIVED_LINK" ]]; then
    ABS_DERIVED_DATA="$(cd "$DERIVED_DATA" && pwd)"
    rm -rf "$TMP_COMPAT_DERIVED_LINK"
    ln -s "$ABS_DERIVED_DATA" "$TMP_COMPAT_DERIVED_LINK"
  fi
fi

if [[ -n "$TAG" && "$APP_NAME" != "$SEARCH_APP_NAME" ]]; then
  TAG_APP_FINAL_PATH="$(dirname "$APP_PATH")/${APP_NAME}.app"
  TAG_APP_STAGING_PATH="$(dirname "$APP_PATH")/.${APP_NAME}.reload-$$.app"
  rm -rf "$TAG_APP_STAGING_PATH"
  /bin/cp -cR "$APP_PATH" "$TAG_APP_STAGING_PATH"
  INFO_PLIST="$TAG_APP_STAGING_PATH/Contents/Info.plist"
  if [[ -f "$INFO_PLIST" ]]; then
    # Visible name only (menu bar, Hide/Quit items). The .app file name, executable and DerivedData
    # path keep "$APP_NAME" because scripts and tools find the app by them.
    if [[ "${TAG_SLUG:-}" == "bree" ]]; then
      VISIBLE_APP_NAME="Bree Dev"
    else
      VISIBLE_APP_NAME="Bree Dev ${TAG_SLUG:-}"
      VISIBLE_APP_NAME="${VISIBLE_APP_NAME% }"
    fi
    /usr/libexec/PlistBuddy -c "Set :CFBundleName $VISIBLE_APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $VISIBLE_APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $VISIBLE_APP_NAME" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $VISIBLE_APP_NAME" "$INFO_PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST" 2>/dev/null \
      || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $BUNDLE_ID" "$INFO_PLIST"
    if [[ -n "${TAG_SLUG:-}" ]]; then
      APP_SUPPORT_DIR="$HOME/Library/Application Support/bree"
      if [[ "${BUNDLE_ID:-}" == "com.bree.app.debug.bree" ]]; then
        APP_SUPPORT_DIR="$HOME/Library/Application Support/Bree Dev"
      fi
      BREED_SOCKET="${APP_SUPPORT_DIR}/breed-dev-${TAG_SLUG}.sock"
      BREE_SOCKET_PATH_VALUE="/tmp/bree-debug-${TAG_SLUG}.sock"
      BREE_DEBUG_LOG="/tmp/bree-debug-${TAG_SLUG}.log"
      BREE_AUTH_CALLBACK_SCHEME_VALUE="bree-dev-${TAG_SLUG}"
      if [[ "$BUILD_ONLY" -ne 1 ]]; then
        echo "$BREE_DEBUG_LOG" > /tmp/bree-last-debug-log-path || true
      fi
      /usr/libexec/PlistBuddy -c "Add :LSEnvironment dict" "$INFO_PLIST" 2>/dev/null || true
      set_plist_url_scheme "$INFO_PLIST" "$BREE_AUTH_CALLBACK_SCHEME_VALUE"
      set_plist_env "$INFO_PLIST" BREE_BUNDLE_ID "$BUNDLE_ID"
      set_plist_env "$INFO_PLIST" BREED_UNIX_PATH "$BREED_SOCKET"
      set_plist_env "$INFO_PLIST" BREE_SOCKET_PATH "$BREE_SOCKET_PATH_VALUE"
      set_plist_env "$INFO_PLIST" BREE_DEBUG_LOG "$BREE_DEBUG_LOG"
      set_plist_env "$INFO_PLIST" BREE_TAG "$TAG_SLUG"
      set_plist_env "$INFO_PLIST" BREE_AUTH_CALLBACK_SCHEME "$BREE_AUTH_CALLBACK_SCHEME_VALUE"
      set_plist_env "$INFO_PLIST" BREE_SOCKET_ENABLE "1"
      set_plist_env "$INFO_PLIST" BREE_SOCKET_MODE "allowAll"
      set_plist_env "$INFO_PLIST" BREE_REMOTE_DAEMON_ALLOW_LOCAL_BUILD "1"
      set_plist_env "$INFO_PLIST" BREE_REPO_ROOT "$PWD"
      BUNDLED_APP_PATH="$TAG_APP_FINAL_PATH"
      if [[ "$BUILD_ONLY" -eq 1 ]]; then
        BUNDLED_APP_PATH="$TAG_APP_STAGING_PATH"
      fi
      set_plist_env "$INFO_PLIST" BREE_BUNDLED_CLI_PATH "$BUNDLED_APP_PATH/Contents/Resources/bin/bree"
      set_plist_env "$INFO_PLIST" BREE_SHELL_INTEGRATION_DIR "$BUNDLED_APP_PATH/Contents/Resources/shell-integration"
      set_plist_env "$INFO_PLIST" BREE_PORT "$BREE_DEV_PORT"
      set_plist_env "$INFO_PLIST" BREE_PORT_END "$BREE_DEV_PORT_END"
      set_plist_env "$INFO_PLIST" BREE_PORT_RANGE "$BREE_DEV_PORT_RANGE"
      set_plist_env "$INFO_PLIST" PORT "$BREE_DEV_PORT"
      set_plist_env "$INFO_PLIST" BREE_AUTH_WWW_ORIGIN "$BREE_AUTH_WWW_ORIGIN_VALUE"
      set_plist_env "$INFO_PLIST" BREE_WWW_ORIGIN "$BREE_WWW_ORIGIN_VALUE"
      if [[ -n "${BREE_DEV_BACKEND_URL:-}" ]]; then
        set_plist_env "$INFO_PLIST" BREE_DEV_BACKEND_URL "$BREE_DEV_BACKEND_URL"
        set_plist_env "$INFO_PLIST" BREE_DEV_BACKEND_TRANSPORT direct
        set_plist_env "$INFO_PLIST" BREE_DEV_BACKEND_TAILSCALE_HOST bree-dev-backend-1.tail137216.ts.net
      fi
      set_plist_env "$INFO_PLIST" BREE_API_BASE_URL "$BREE_DEV_API_BASE_URL_VALUE"
      set_plist_env "$INFO_PLIST" BREE_VM_API_BASE_URL "$BREE_DEV_API_BASE_URL_VALUE"
      if [[ "$PROD_AUTH" -eq 1 ]]; then
        set_plist_env "$INFO_PLIST" BREE_AUTH_ENVIRONMENT production
      fi
      if [[ "$BUILD_ONLY" -ne 1 && -S "$BREED_SOCKET" ]]; then
        for PID in $(lsof -t "$BREED_SOCKET" 2>/dev/null); do
          kill "$PID" 2>/dev/null || true
        done
        rm -f "$BREED_SOCKET"
      fi
    fi
  fi
  APP_PATH="$TAG_APP_STAGING_PATH"
fi

CLI_PATH="$(dirname "$APP_PATH")/bree"

# Build breed and ensure helper binaries are present (needed for both launch and no-launch).
BREED_SRC="$PWD/breed/zig-out/bin/breed"
if [[ -d "$PWD/breed" ]]; then
  (cd "$PWD/breed" && zig build -Doptimize=ReleaseFast)
fi
if [[ -d "$PWD/ghostty" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  GHOSTTY_HELPER_DEST="$BIN_DIR/ghostty"
  if [[ -x "$GHOSTTY_HELPER_DEST" ]]; then
    echo "Preserving Xcode-built ghostty CLI helper at $GHOSTTY_HELPER_DEST"
  elif [[ "${BREE_SKIP_ZIG_BUILD:-}" == "1" ]]; then
    echo "Skipping direct ghostty CLI helper zig build (BREE_SKIP_ZIG_BUILD=1)"
  else
    mkdir -p "$BIN_DIR"
    "$PWD/scripts/build-ghostty-cli-helper.sh" --output "$GHOSTTY_HELPER_DEST"
  fi
fi
BIN_DIR="$APP_PATH/Contents/Resources/bin"
if [[ -x "$BREED_SRC" ]]; then
  BIN_DIR="$APP_PATH/Contents/Resources/bin"
  mkdir -p "$BIN_DIR"
  cp "$BREED_SRC" "$BIN_DIR/breed"
  chmod +x "$BIN_DIR/breed"
fi
if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_PATH" || true
fi
BREE_SIGN_IDENTITY="$("$PWD/scripts/bree-sign-identity.sh")"
if ! /usr/bin/codesign --force --sign "$BREE_SIGN_IDENTITY" --timestamp=none --generate-entitlement-der "$APP_PATH" >/dev/null 2>&1; then
  if [[ "${BREE_ALLOW_UNSIGNED_DEV_APP:-}" == "1" ]]; then
    echo "warning: codesign failed for $APP_PATH; continuing because BREE_ALLOW_UNSIGNED_DEV_APP=1" >&2
  else
    echo "error: codesign failed for $APP_PATH" >&2
    exit 1
  fi
fi

TAG_LAUNCHD_LABEL=""
TAG_LAUNCHD_DOMAIN=""
if [[ -n "${TAG_SLUG:-}" ]]; then
  TAG_LAUNCHD_LABEL="${BUNDLE_ID}.reload"
  TAG_LAUNCHD_DOMAIN="gui/$(id -u)"
fi

# Terminate the existing same-tag instance before replacing its bundle. The
# running process resolves SwiftPM resources through its app path; removing
# that path first can make Bundle.module trap during startup while the old
# process is still initializing.
if [[ -n "$TAG" && "$BUILD_ONLY" -ne 1 ]]; then
  /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  sleep 0.3
  TAG_PROCESS_PATTERN="${APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}"
  pkill -f "$TAG_PROCESS_PATTERN" || true
  for _ in {1..20}; do
    if ! pgrep -f "$TAG_PROCESS_PATTERN" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  # A startup process may not service its quit event yet. Do not replace the
  # resource-bearing bundle while it is still mapped; force only this tagged
  # executable after the bounded graceful window.
  pkill -KILL -f "$TAG_PROCESS_PATTERN" >/dev/null 2>&1 || true
  # Tagged --launch runs are handed off to launchd so they survive the terminal
  # or automation process that invoked reload.sh. Remove a still-registered
  # prior job before publishing the replacement bundle.
  /bin/launchctl bootout "$TAG_LAUNCHD_DOMAIN/$TAG_LAUNCHD_LABEL" >/dev/null 2>&1 || true
  /bin/launchctl remove "$TAG_LAUNCHD_LABEL" >/dev/null 2>&1 || true
fi

if [[ "$BUILD_ONLY" -eq 1 && -n "${TAG_APP_STAGING_PATH:-}" ]]; then
  # Keep the staged artifact separate from the running tagged app. This mode is
  # explicitly for compilation/validation and must not mutate the active bundle.
  APP_PATH="$TAG_APP_STAGING_PATH"
elif [[ -n "${TAG_APP_FINAL_PATH:-}" && -n "${TAG_APP_STAGING_PATH:-}" ]]; then
  rm -rf "$TAG_APP_FINAL_PATH"
  mv "$TAG_APP_STAGING_PATH" "$TAG_APP_FINAL_PATH"
  APP_PATH="$TAG_APP_FINAL_PATH"
fi
CLI_PATH="$APP_PATH/Contents/Resources/bin/bree"

if [[ "$BUILD_ONLY" -eq 1 ]]; then
  CAN_PUBLISH_RELOAD_STATE=0
  RELOAD_PUBLICATION_SKIP_REASON="build-only mode left the running tagged app and tag state unchanged"
elif [[ -n "$TAG" ]] && ! wait_for_tag_socket_lock_release "/tmp/bree-debug-${TAG_SLUG}.sock"; then
  CAN_PUBLISH_RELOAD_STATE=0
fi
if [[ "$CAN_PUBLISH_RELOAD_STATE" -eq 1 && -n "${TAG_SLUG:-}" ]]; then
  # A forced quit can release the flock without running the app's synchronous
  # cleanup hook. Re-run the liveness-gated cleanup after the process is gone,
  # and publish this reload's marker and pointer while the same tag lock is
  # still held. This closes the handoff window where a parallel reload could
  # publish state for a socket it does not own.
  RELOAD_PUBLISH_CLI_PATH=""
  if [[ "$NO_GLOBAL_CLI_LINKS" != "1" && -x "$CLI_PATH" ]]; then
    RELOAD_PUBLISH_CLI_PATH="$CLI_PATH"
  fi
  if ! cleanup_stale_tag_state \
      "$TAG_SLUG" \
      "/tmp/bree-debug-${TAG_SLUG}.sock" \
      "/tmp/bree-debug-${TAG_SLUG}.sock" \
      "$RELOAD_PUBLISH_CLI_PATH"; then
    # A replacement process may have reclaimed this tag while the old app was
    # terminating. Do not overwrite its discovery marker or ambient CLI pointer.
    CAN_PUBLISH_RELOAD_STATE=0
    RELOAD_PUBLICATION_SKIP_REASON="tag socket stayed live or its lock is owned by a replacement instance"
  fi
fi
if [[ "$CAN_PUBLISH_RELOAD_STATE" -eq 1 && "$NO_GLOBAL_CLI_LINKS" != "1" ]]; then
  # The pointer itself was published in the tag-lock transaction above. These
  # convenience links/shims do not participate in socket ownership and can be
  # updated after the transaction without changing discovery semantics.
  if ! publish_reload_cli_links "$CLI_PATH"; then
    CAN_PUBLISH_RELOAD_STATE=0
    RELOAD_PUBLICATION_SKIP_REASON="could not update the ambient CLI convenience links"
  fi
fi

if [[ "$LAUNCH" -eq 1 ]]; then
  if [[ -z "$TAG" ]]; then
    # Non-tag mode: kill any running instance (across any DerivedData path) to avoid socket conflicts.
    /usr/bin/osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
    sleep 0.3
    pkill -f "/${BASE_APP_NAME}.app/Contents/MacOS/${BASE_APP_NAME}" || true
    sleep 0.3
  fi

  # Avoid inheriting bree/ghostty environment variables from the terminal that
  # runs this script (often inside another bree instance), which can cause
  # socket and resource-path conflicts.
  OPEN_CLEAN_ENV=(
    env
    -u BREE_SOCKET
    -u BREE_SOCKET_PASSWORD
    -u BREE_SOCKET_PATH
    -u BREE_WORKSPACE_ID
    -u BREE_SURFACE_ID
    -u BREE_TAB_ID
    -u BREE_PANEL_ID
    -u BREED_UNIX_PATH
    -u BREE_TAG
    -u BREE_DEBUG_LOG
    -u BREE_BUNDLE_ID
    -u BREE_BUNDLED_CLI_PATH
    -u BREE_SHELL_INTEGRATION
    -u BREE_SHELL_INTEGRATION_DIR
    -u BREE_LOAD_GHOSTTY_ZSH_INTEGRATION
    -u BREE_AUTH_ENVIRONMENT
    -u BREE_STACK_PROJECT_ID
    -u BREE_STACK_PUBLISHABLE_CLIENT_KEY
    -u GHOSTTY_BIN_DIR
    -u GHOSTTY_RESOURCES_DIR
    -u GHOSTTY_SHELL_FEATURES
    -u GHOSTTY_SURFACE_ID
    # Dev shells (including CI/Codex) often force-disable paging by exporting these.
    # Don't leak that into bree, otherwise `git diff` won't page even with PAGER=less.
    -u GIT_PAGER
    -u GH_PAGER
    -u TERMINFO
    -u XDG_DATA_DIRS
  )

  LAUNCH_AUTH_CALLBACK_SCHEME="bree-dev"
  if [[ -n "${TAG_SLUG:-}" ]]; then
    LAUNCH_AUTH_CALLBACK_SCHEME="bree-dev-${TAG_SLUG}"
  fi
  TAG_LAUNCH_ENV=(
    BREE_TAG="${TAG_SLUG:-}"
    BREE_BUNDLE_ID="$BUNDLE_ID"
    BREE_AUTH_CALLBACK_SCHEME="$LAUNCH_AUTH_CALLBACK_SCHEME"
    BREE_SOCKET_ENABLE=1
    BREE_SOCKET_MODE=allowAll
    BREE_DEBUG_LOG="$BREE_DEBUG_LOG"
    BREE_REMOTE_DAEMON_ALLOW_LOCAL_BUILD=1
    BREE_REPO_ROOT="$PWD"
    BREE_BUNDLED_CLI_PATH="$CLI_PATH"
    BREE_SHELL_INTEGRATION_DIR="$APP_PATH/Contents/Resources/shell-integration"
    BREE_PORT="$BREE_DEV_PORT"
    BREE_PORT_END="$BREE_DEV_PORT_END"
    BREE_PORT_RANGE="$BREE_DEV_PORT_RANGE"
    PORT="$BREE_DEV_PORT"
    BREE_AUTH_WWW_ORIGIN="$BREE_AUTH_WWW_ORIGIN_VALUE"
    BREE_WWW_ORIGIN="$BREE_WWW_ORIGIN_VALUE"
    BREE_API_BASE_URL="$BREE_DEV_API_BASE_URL_VALUE"
    BREE_VM_API_BASE_URL="$BREE_DEV_API_BASE_URL_VALUE"
  )
  if [[ "$PROD_AUTH" -eq 1 ]]; then
    TAG_LAUNCH_ENV+=(BREE_AUTH_ENVIRONMENT=production)
  fi

  LAUNCH_CMD=()
  LAUNCH_RETRY_CMD=()
  if [[ -n "${TAG_SLUG:-}" ]]; then
    # Launch tagged apps through an explicit one-shot launchd job. `launchctl
    # submit` infers KeepAlive for app executables, which relaunches the app after
    # the user chooses Quit. A loaded plist with KeepAlive=false still survives
    # the invoking terminal/automation process, while a normal exit stays exited.
    # It also avoids LaunchServices reusing stale LSEnvironment values.
    APP_EXECUTABLE="$APP_PATH/Contents/MacOS/${BASE_APP_NAME}"
    if [[ ! -x "$APP_EXECUTABLE" ]]; then
      echo "error: tagged app executable not found: $APP_EXECUTABLE" >&2
      exit 1
    fi
    BREE_TAG_LAUNCH_LOG_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/bree-launch-${TAG_SLUG}.XXXXXX")"
    chmod 0700 "$BREE_TAG_LAUNCH_LOG_DIRECTORY"
    TAG_LAUNCH_LOG="$BREE_TAG_LAUNCH_LOG_DIRECTORY/launch.out"
    (umask 077 && : > "$TAG_LAUNCH_LOG")
    chmod 0600 "$TAG_LAUNCH_LOG"
    if [[ -n "${BREE_SOCKET_PATH_VALUE:-}" ]]; then
      TAG_LAUNCH_ENV+=(
        BREE_SOCKET_PATH="$BREE_SOCKET_PATH_VALUE"
        BREED_UNIX_PATH="$BREED_SOCKET"
      )
    fi
    TAG_LAUNCH_PLIST="$BREE_TAG_LAUNCH_LOG_DIRECTORY/$TAG_LAUNCHD_LABEL.plist"
    /usr/bin/plutil -create xml1 "$TAG_LAUNCH_PLIST"
    /usr/bin/plutil -insert Label -string "$TAG_LAUNCHD_LABEL" "$TAG_LAUNCH_PLIST"
    # A launchd job inherits the GUI domain environment even when the plist has
    # its own EnvironmentVariables dictionary. That domain can contain stale
    # test/socket overrides from another dev session. Run through `env -i` so
    # the app receives only the ordinary user context and this tag's explicit
    # values; `env` execs the app in place, so launchd still tracks its lifetime.
    TAG_LAUNCH_PROGRAM_ARGUMENTS=(
      /usr/bin/env
      -i
      HOME="${HOME:-/Users/$(id -un)}"
      USER="$(id -un)"
      LOGNAME="$(id -un)"
      SHELL="${SHELL:-/bin/zsh}"
      PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      TMPDIR="${TMPDIR:-/tmp}"
    )
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
      TAG_LAUNCH_PROGRAM_ARGUMENTS+=(SSH_AUTH_SOCK="$SSH_AUTH_SOCK")
    fi
    TAG_LAUNCH_PROGRAM_ARGUMENTS+=("${TAG_LAUNCH_ENV[@]}" "$APP_EXECUTABLE")
    /usr/bin/plutil -insert ProgramArguments -array "$TAG_LAUNCH_PLIST"
    for TAG_LAUNCH_ARGUMENT_INDEX in "${!TAG_LAUNCH_PROGRAM_ARGUMENTS[@]}"; do
      /usr/bin/plutil -insert "ProgramArguments.$TAG_LAUNCH_ARGUMENT_INDEX" \
        -string "${TAG_LAUNCH_PROGRAM_ARGUMENTS[$TAG_LAUNCH_ARGUMENT_INDEX]}" \
        "$TAG_LAUNCH_PLIST"
    done
    /usr/bin/plutil -insert RunAtLoad -bool true "$TAG_LAUNCH_PLIST"
    /usr/bin/plutil -insert KeepAlive -bool false "$TAG_LAUNCH_PLIST"
    /usr/bin/plutil -insert ProcessType -string Interactive "$TAG_LAUNCH_PLIST"
    /usr/bin/plutil -insert StandardOutPath -string "$TAG_LAUNCH_LOG" "$TAG_LAUNCH_PLIST"
    /usr/bin/plutil -insert StandardErrorPath -string "$TAG_LAUNCH_LOG" "$TAG_LAUNCH_PLIST"
    chmod 0600 "$TAG_LAUNCH_PLIST"
    if ! /bin/launchctl bootstrap "$TAG_LAUNCHD_DOMAIN" "$TAG_LAUNCH_PLIST"; then
      echo "error: failed to bootstrap one-shot tagged launch job: $TAG_LAUNCHD_LABEL" >&2
      exit 1
    fi
  else
    echo "/tmp/bree-debug.sock" > /tmp/bree-last-socket-path || true
    echo "/tmp/bree-debug.log" > /tmp/bree-last-debug-log-path || true
    if [[ -n "${BREE_SOCKET_PATH_VALUE:-}" ]]; then
      # Ensure explicit socket paths win even if the caller has BREE_* overrides.
      LAUNCH_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" BREE_SOCKET_PATH="$BREE_SOCKET_PATH_VALUE" BREED_UNIX_PATH="$BREED_SOCKET" open -g "$APP_PATH")
      LAUNCH_RETRY_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" BREE_SOCKET_PATH="$BREE_SOCKET_PATH_VALUE" BREED_UNIX_PATH="$BREED_SOCKET" open -n -g "$APP_PATH")
    else
      LAUNCH_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" open -g "$APP_PATH")
      LAUNCH_RETRY_CMD=("${OPEN_CLEAN_ENV[@]}" "${TAG_LAUNCH_ENV[@]}" open -n -g "$APP_PATH")
    fi
  fi

  # Crash watch: any DiagnosticReports .ips newer than this marker belongs to this launch.
  CRASH_WATCH_MARKER="$(mktemp -t bree-reload-crash-watch)"

  if [[ "${#LAUNCH_CMD[@]}" -gt 0 ]] && ! "${LAUNCH_CMD[@]}"; then
    echo "warning: open -g failed; retrying launch with open -n -g" >&2
    "${LAUNCH_RETRY_CMD[@]}"
  fi

  # Safety: ensure only one instance is running.
  sleep 0.2
  # macOS ships Bash 3.2 without mapfile/readarray; pgrep emits one PID per line.
  # shellcheck disable=SC2207
  PIDS=($(pgrep -f "${APP_PATH}/Contents/MacOS/" || true))
  if [[ -n "${TAG_SLUG:-}" && "${#PIDS[@]}" -eq 0 ]]; then
    echo "error: tagged app exited immediately after launch" >&2
    if [[ -n "${TAG_LAUNCH_LOG:-}" && -f "$TAG_LAUNCH_LOG" ]]; then
      echo "Launch log: $TAG_LAUNCH_LOG" >&2
      tail -n 80 "$TAG_LAUNCH_LOG" >&2 || true
    fi
    exit 1
  fi
  if [[ "${#PIDS[@]}" -gt 1 ]]; then
    NEWEST_PID=""
    NEWEST_AGE=999999
    for PID in "${PIDS[@]}"; do
      AGE="$(ps -o etimes= -p "$PID" | tr -d ' ')"
      if [[ -n "$AGE" && "$AGE" -lt "$NEWEST_AGE" ]]; then
        NEWEST_AGE="$AGE"
        NEWEST_PID="$PID"
      fi
    done
    for PID in "${PIDS[@]}"; do
      if [[ "$PID" != "$NEWEST_PID" ]]; then
        kill "$PID" 2>/dev/null || true
      fi
    done
  fi
  if [[ -n "${TAG_SLUG:-}" && -n "${BREE_SOCKET_PATH_VALUE:-}" ]]; then
    SOCKET_READY=0
    for _ in {1..80}; do
      if [[ -S "$BREE_SOCKET_PATH_VALUE" ]]; then
        SOCKET_READY=1
        break
      fi
      if ! pgrep -f "${APP_PATH}/Contents/MacOS/" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if [[ "$SOCKET_READY" -ne 1 ]]; then
      echo "error: tagged app did not create socket: $BREE_SOCKET_PATH_VALUE" >&2
      if [[ -n "${TAG_LAUNCH_LOG:-}" && -f "$TAG_LAUNCH_LOG" ]]; then
        echo "Launch log: $TAG_LAUNCH_LOG" >&2
        tail -n 80 "$TAG_LAUNCH_LOG" >&2 || true
      fi
      exit 1
    fi
  fi

  # Warn when the freshly launched app crashes shortly after launch, so a broken
  # build (for example stale incremental objects) is not mistaken for a source bug.
  # BREE_RELOAD_CRASH_WATCH_SECONDS=0 turns the watch off.
  CRASH_WATCH_SECONDS="${BREE_RELOAD_CRASH_WATCH_SECONDS:-20}"
  CRASH_REPORT_DIR="$HOME/Library/Logs/DiagnosticReports"
  CRASH_REPORT=""
  if [[ "$CRASH_WATCH_SECONDS" -gt 0 && -d "$CRASH_REPORT_DIR" ]]; then
    for (( CRASH_WATCH_TICK = 0; CRASH_WATCH_TICK < CRASH_WATCH_SECONDS * 2; CRASH_WATCH_TICK++ )); do
      CRASH_REPORT="$(find "$CRASH_REPORT_DIR" -maxdepth 1 -name 'Bree Dev*.ips' -newer "$CRASH_WATCH_MARKER" 2>/dev/null | head -n 1)"
      [[ -n "$CRASH_REPORT" ]] && break
      sleep 0.5
    done
  fi
  rm -f "$CRASH_WATCH_MARKER"
  if [[ -n "$CRASH_REPORT" ]]; then
    echo "warning: the launched app crashed; new crash report: $CRASH_REPORT" >&2
    echo "warning: if the crash makes no sense for the change, rebuild clean (stale incremental objects)" >&2
  fi
fi

# The user-facing summary (success line, App path, CLI path/helpers, rehash
# hint, "pass --launch") is printed by the reload_finalize EXIT trap. The
# tag-cleanup reminder still runs here, but its output goes to $RELOAD_LOG
# (visible by tail -f or by inspecting the log path printed in the summary).
if [[ -n "${TAG_SLUG:-}" ]]; then
  print_tag_cleanup_reminder "$TAG_SLUG" "$DERIVED_DATA"
fi
