// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

#include "chrome/browser/bree_term/bree_tui_protocol.h"

#include <algorithm>
#include <array>
#include <limits>
#include <utility>

namespace bree {

BreeTuiRegistryFenceDecision FenceBreeTuiRegistrySnapshot(
    bool has_current,
    std::string_view current_registry_id,
    std::string_view current_generation,
    uint64_t current_revision,
    std::string_view incoming_registry_id,
    std::string_view incoming_generation,
    uint64_t incoming_revision) {
  if (incoming_registry_id.empty() || incoming_generation.empty()) {
    return BreeTuiRegistryFenceDecision::kInvalid;
  }
  if (!has_current || current_registry_id != incoming_registry_id ||
      current_generation != incoming_generation) {
    return BreeTuiRegistryFenceDecision::kAccept;
  }
  if (incoming_revision < current_revision) {
    return BreeTuiRegistryFenceDecision::kRefetch;
  }
  if (incoming_revision == current_revision) {
    return BreeTuiRegistryFenceDecision::kIgnore;
  }
  return BreeTuiRegistryFenceDecision::kAccept;
}

bool ValidateBreeTuiTerminalEventRevisions(
    uint64_t after_revision,
    uint64_t batch_revision,
    const std::vector<uint64_t>& event_revisions) {
  if (batch_revision < after_revision) {
    return false;
  }
  uint64_t expected = after_revision;
  for (const uint64_t revision : event_revisions) {
    if (expected == std::numeric_limits<uint64_t>::max() ||
        revision != expected + 1) {
      return false;
    }
    expected = revision;
  }
  return expected == batch_revision;
}

bool IsBreeTuiTreeEventName(std::string_view event_name) {
  constexpr std::array<std::string_view, 13> kTreeEvents = {
      "tree-changed",      "workspace-added", "workspace-closed",
      "workspace-renamed", "workspace-moved", "screen-added",
      "screen-closed",     "screen-renamed",  "pane-added",
      "pane-closed",       "tab-added",       "tab-closed",
      "tab-renamed",
  };
  return std::find(kTreeEvents.begin(), kTreeEvents.end(), event_name) !=
         kTreeEvents.end();
}

BreeTuiIdentityError ValidateBreeTuiIdentity(
    std::string_view app,
    uint64_t protocol,
    uint64_t pid,
    std::optional<std::string_view> build_commit,
    std::string_view required_build_commit,
    std::optional<std::string_view> ghostty_commit,
    std::string_view required_ghostty_commit) {
  if (app != "bree-tui" || protocol < kMinBreeTuiProtocolVersion ||
      protocol > kBreeTuiProtocolVersion || pid == 0) {
    return BreeTuiIdentityError::kInvalidEndpoint;
  }
  if (!required_build_commit.empty()) {
    if (!build_commit || build_commit->empty()) {
      return BreeTuiIdentityError::kBuildCommitMissing;
    }
    if (*build_commit != required_build_commit) {
      return BreeTuiIdentityError::kBuildCommitMismatch;
    }
  }
  // A recognizable older daemon must reach the stamped-build checks above so
  // the browser can replace it safely. It must never become ready, even in an
  // unpinned source-tree build.
  if (protocol != kBreeTuiProtocolVersion) {
    return BreeTuiIdentityError::kInvalidEndpoint;
  }
  if (required_ghostty_commit.empty()) {
    return BreeTuiIdentityError::kNone;
  }
  if (!ghostty_commit || ghostty_commit->empty()) {
    return BreeTuiIdentityError::kGhosttyCommitMissing;
  }
  if (*ghostty_commit != required_ghostty_commit) {
    return BreeTuiIdentityError::kGhosttyCommitMismatch;
  }
  return BreeTuiIdentityError::kNone;
}

bool IsReplaceableBreeTuiIdentityError(BreeTuiIdentityError error) {
  switch (error) {
    case BreeTuiIdentityError::kBuildCommitMissing:
    case BreeTuiIdentityError::kBuildCommitMismatch:
    case BreeTuiIdentityError::kGhosttyCommitMissing:
    case BreeTuiIdentityError::kGhosttyCommitMismatch:
      return true;
    case BreeTuiIdentityError::kNone:
    case BreeTuiIdentityError::kInvalidEndpoint:
      return false;
  }
  // Fail closed for an unrecognized value. Besides keeping GCC's control-flow
  // analysis honest, this prevents a future protocol error from silently
  // becoming permission to replace a process until it is classified above.
  return false;
}

std::string SelectBreeTuiSocketPath(std::string_view preferred,
                                    std::string_view fallback,
                                    size_t native_path_capacity) {
  return preferred.size() < native_path_capacity ? std::string(preferred)
                                                  : std::string(fallback);
}

std::vector<uint8_t> StripBreeTuiReplayPalette(std::string_view replay) {
  std::vector<uint8_t> filtered;
  filtered.reserve(replay.size());
  size_t cursor = 0;
  while (cursor < replay.size()) {
    const bool seven_bit_osc4 =
        cursor + 3 < replay.size() && replay[cursor] == '\x1b' &&
        replay[cursor + 1] == ']' && replay[cursor + 2] == '4' &&
        replay[cursor + 3] == ';';
    const bool eight_bit_osc4 = cursor + 2 < replay.size() &&
                                static_cast<uint8_t>(replay[cursor]) == 0x9d &&
                                replay[cursor + 1] == '4' &&
                                replay[cursor + 2] == ';';
    if (!seven_bit_osc4 && !eight_bit_osc4) {
      filtered.push_back(static_cast<uint8_t>(replay[cursor++]));
      continue;
    }

    size_t end = cursor + (seven_bit_osc4 ? 4 : 3);
    bool terminated = false;
    while (end < replay.size()) {
      const uint8_t byte = static_cast<uint8_t>(replay[end]);
      if (byte == 0x07 || byte == 0x9c) {
        ++end;
        terminated = true;
        break;
      }
      if (byte == 0x1b && end + 1 < replay.size() && replay[end + 1] == '\\') {
        end += 2;
        terminated = true;
        break;
      }
      ++end;
    }
    if (!terminated) {
      filtered.insert(filtered.end(), replay.begin() + cursor, replay.end());
      break;
    }
    cursor = end;
  }
  return filtered;
}

BreeTuiInputQueue::BreeTuiInputQueue(size_t max_pending_bytes)
    : max_pending_bytes_(max_pending_bytes) {}

BreeTuiInputQueue::~BreeTuiInputQueue() = default;

bool BreeTuiInputQueue::Push(std::string_view bytes) {
  if (bytes.empty()) {
    return true;
  }
  if (pending_.size() > max_pending_bytes_ ||
      bytes.size() > max_pending_bytes_ - pending_.size()) {
    return false;
  }
  pending_.insert(pending_.end(), bytes.begin(), bytes.end());
  return true;
}

std::vector<uint8_t> BreeTuiInputQueue::BeginWrite() {
  if (write_in_flight_ || pending_.empty()) {
    return {};
  }
  write_in_flight_ = true;
  std::vector<uint8_t> result;
  result.swap(pending_);
  return result;
}

void BreeTuiInputQueue::FinishWrite() {
  write_in_flight_ = false;
}

void BreeTuiInputQueue::CancelWrite() {
  write_in_flight_ = false;
}

void BreeTuiInputQueue::Clear() {
  pending_.clear();
  write_in_flight_ = false;
}

void BreeTuiResizeCoalescer::SetDesired(uint16_t cols, uint16_t rows) {
  desired_ = {std::max<uint16_t>(cols, 1), std::max<uint16_t>(rows, 1)};
}

std::optional<BreeTuiGridSize> BreeTuiResizeCoalescer::BeginWrite(
    BreeTuiGridSize current) {
  if (write_in_flight_ || desired_ == current) {
    return std::nullopt;
  }
  write_in_flight_ = true;
  return desired_;
}

void BreeTuiResizeCoalescer::FinishWrite() {
  write_in_flight_ = false;
}

void BreeTuiResizeCoalescer::CancelWrite() {
  write_in_flight_ = false;
}

BreeTuiLineFramer::BreeTuiLineFramer(size_t max_line_bytes)
    : max_line_bytes_(max_line_bytes) {}

BreeTuiLineFramer::~BreeTuiLineFramer() = default;

BreeTuiLineFramer::Result BreeTuiLineFramer::Push(
    std::string_view bytes,
    std::vector<std::string>* lines) {
  if (!lines) {
    Reset();
    return Result::kLineTooLarge;
  }

  while (!bytes.empty()) {
    const size_t newline = bytes.find('\n');
    const std::string_view piece =
        newline == std::string_view::npos ? bytes : bytes.substr(0, newline);
    if (piece.size() > max_line_bytes_ - pending_.size()) {
      Reset();
      return Result::kLineTooLarge;
    }
    pending_.append(piece);

    if (newline == std::string_view::npos) {
      return Result::kOk;
    }

    if (!pending_.empty() && pending_.back() == '\r') {
      pending_.pop_back();
    }
    if (!pending_.empty()) {
      lines->push_back(std::move(pending_));
      pending_.clear();
    }
    bytes.remove_prefix(newline + 1);
  }

  return Result::kOk;
}

void BreeTuiLineFramer::Reset() {
  pending_.clear();
}

}  // namespace bree
