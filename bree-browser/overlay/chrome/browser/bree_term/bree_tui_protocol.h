// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

#ifndef CHROME_BROWSER_BREE_TERM_BREE_TUI_PROTOCOL_H_
#define CHROME_BROWSER_BREE_TERM_BREE_TUI_PROTOCOL_H_

#include <cstddef>
#include <cstdint>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace bree {

// The browser and its packaged bree-tui helper are revision-pinned together.
// Recognize the additive protocol range needed to identify and safely hand off
// a stale pinned daemon, while rejecting unknown future wire contracts. A
// ready connection still requires the exact current version bundled with the
// browser.
inline constexpr uint64_t kMinBreeTuiProtocolVersion = 7;
inline constexpr uint64_t kBreeTuiProtocolVersion = 9;

enum class BreeTuiIdentityError {
  kNone,
  kInvalidEndpoint,
  kBuildCommitMissing,
  kBuildCommitMismatch,
  kGhosttyCommitMissing,
  kGhosttyCommitMismatch,
};

// A durable registry is identified by both its database identity and the
// daemon boot generation. Snapshots may replace state across either boundary,
// but responses from an older revision in the same epoch must never move a
// frontend cursor backwards.
enum class BreeTuiRegistryFenceDecision {
  kAccept,
  kIgnore,
  kRefetch,
  kInvalid,
};

BreeTuiRegistryFenceDecision FenceBreeTuiRegistrySnapshot(
    bool has_current,
    std::string_view current_registry_id,
    std::string_view current_generation,
    uint64_t current_revision,
    std::string_view incoming_registry_id,
    std::string_view incoming_generation,
    uint64_t incoming_revision);

// Validates the revision envelope returned by `terminal-events`. A successful
// batch contains every revision strictly after `after_revision`, in order,
// through `batch_revision`. This makes a missing/pruned event fail closed to a
// fresh list-terminals snapshot instead of partially mutating the GUI.
bool ValidateBreeTuiTerminalEventRevisions(
    uint64_t after_revision,
    uint64_t batch_revision,
    const std::vector<uint64_t>& event_revisions);

// Protocol-v7 and newer subscriptions can request detailed tree deltas. Every
// detailed workspace/screen/pane/tab event invalidates the active path just
// like the legacy `tree-changed` event, even when Chromium only applies
// workspace lifecycle deltas incrementally and refetches the rest.
bool IsBreeTuiTreeEventName(std::string_view event_name);

// Validates the stable protocol identity independently of Chromium JSON
// types, so packaged-build provenance is covered by the host test suite. An
// empty required commits keep source-tree development compatible with
// unstamped binaries; production packaging supplies exact bree and Ghostty
// commits.
BreeTuiIdentityError ValidateBreeTuiIdentity(
    std::string_view app,
    uint64_t protocol,
    uint64_t pid,
    std::optional<std::string_view> build_commit,
    std::string_view required_build_commit,
    std::optional<std::string_view> ghostty_commit,
    std::string_view required_ghostty_commit);

// Only a valid bree-tui protocol endpoint with stale/missing build stamps is
// eligible for an in-place daemon handoff. An arbitrary socket endpoint must
// never gain the ability to make the browser signal a process.
bool IsReplaceableBreeTuiIdentityError(BreeTuiIdentityError error);

// Selects the preferred runtime socket path when it fits the native Unix
// sockaddr buffer (including its trailing NUL), otherwise the short private
// fallback. Keeping this byte-level rule shared with the host test prevents
// the browser launcher and bree-tui daemon from silently choosing different
// endpoints on macOS, where sun_path is only 104 bytes.
std::string SelectBreeTuiSocketPath(std::string_view preferred,
                                    std::string_view fallback,
                                    size_t native_path_capacity);

// Removes OSC 4 palette definitions from a state replay before it reaches a
// configured Ghostty frontend. bree-tui reports the PTY-authored overrides
// separately; replaying its complete parser palette would otherwise replace
// every frontend theme color with the headless parser's compiled defaults.
// Unterminated OSC strings are preserved byte-for-byte.
std::vector<uint8_t> StripBreeTuiReplayPalette(std::string_view replay);

// Bounded per-surface input queue. At most one batch may be in flight; bytes
// arriving behind it are coalesced up to the pending cap. A failed or canceled
// in-flight batch is never requeued because the server may have committed it
// before the response was lost.
class BreeTuiInputQueue {
 public:
  static constexpr size_t kDefaultMaxPendingBytes = 1024 * 1024;

  explicit BreeTuiInputQueue(
      size_t max_pending_bytes = kDefaultMaxPendingBytes);
  ~BreeTuiInputQueue();

  bool Push(std::string_view bytes);
  std::vector<uint8_t> BeginWrite();
  void FinishWrite();
  void CancelWrite();
  void Clear();

  size_t pending_bytes() const { return pending_.size(); }
  bool write_in_flight() const { return write_in_flight_; }

 private:
  const size_t max_pending_bytes_;
  std::vector<uint8_t> pending_;
  bool write_in_flight_ = false;
};

struct BreeTuiGridSize {
  uint16_t cols = 80;
  uint16_t rows = 24;

  bool operator==(const BreeTuiGridSize& other) const {
    return cols == other.cols && rows == other.rows;
  }
};

// Coalesces resize storms to the latest desired grid while one request is in
// flight. `current` is supplied by the backend because authoritative replay
// can change it independently (including from another attached client).
class BreeTuiResizeCoalescer {
 public:
  void SetDesired(uint16_t cols, uint16_t rows);
  std::optional<BreeTuiGridSize> BeginWrite(BreeTuiGridSize current);
  void FinishWrite();
  void CancelWrite();

  BreeTuiGridSize desired() const { return desired_; }
  bool write_in_flight() const { return write_in_flight_; }

 private:
  BreeTuiGridSize desired_;
  bool write_in_flight_ = false;
};

// Incrementally splits bree-tui's Unix JSON-lines transport. A single socket
// read can contain part of a JSON object, several objects, or both. The cap is
// deliberately above the server's 16 MiB attach queue: base64 expansion plus
// the JSON envelope can make a valid replay line a little over 21 MiB.
class BreeTuiLineFramer {
 public:
  static constexpr size_t kDefaultMaxLineBytes = 32 * 1024 * 1024;

  enum class Result {
    kOk,
    kLineTooLarge,
  };

  explicit BreeTuiLineFramer(size_t max_line_bytes = kDefaultMaxLineBytes);
  BreeTuiLineFramer(const BreeTuiLineFramer&) = delete;
  BreeTuiLineFramer& operator=(const BreeTuiLineFramer&) = delete;
  ~BreeTuiLineFramer();

  // Appends bytes and moves every complete, non-empty line into `lines`.
  // Accepts either LF or CRLF. On overflow, clears buffered state so callers
  // cannot accidentally resume parsing the tail of an oversized frame.
  Result Push(std::string_view bytes, std::vector<std::string>* lines);

  void Reset();
  size_t buffered_bytes() const { return pending_.size(); }

 private:
  const size_t max_line_bytes_;
  std::string pending_;
};

}  // namespace bree

#endif  // CHROME_BROWSER_BREE_TERM_BREE_TUI_PROTOCOL_H_
