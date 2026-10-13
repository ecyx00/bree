// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

// Host-compilable tests for bree-tui JSON-lines framing. No Chromium or gtest.

#include "chrome/browser/bree_term/bree_tui_protocol.h"

#include <cstdio>
#include <limits>
#include <string>
#include <vector>

namespace {

int checks = 0;
int failures = 0;

void Check(bool condition, const char* message) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
}

void CheckLines(const std::vector<std::string>& actual,
                const std::vector<std::string>& expected,
                const char* message) {
  Check(actual == expected, message);
}

}  // namespace

int main() {
  using bree::BreeTuiIdentityError;
  using bree::BreeTuiLineFramer;
  using bree::BreeTuiRegistryFenceDecision;

  {
    for (const std::string_view event : {
             "tree-changed", "workspace-added", "workspace-closed",
             "workspace-renamed", "workspace-moved", "screen-added",
             "screen-closed", "screen-renamed", "pane-added", "pane-closed",
             "tab-added", "tab-closed", "tab-renamed"}) {
      Check(bree::IsBreeTuiTreeEventName(event),
            "every supported tree delta invalidates the active path");
    }
    Check(!bree::IsBreeTuiTreeEventName("terminal-registry-changed"),
          "terminal registry events remain on their independent stream");
    Check(!bree::IsBreeTuiTreeEventName("title-changed"),
          "surface metadata does not force a tree snapshot");
  }

  {
    Check(bree::SelectBreeTuiSocketPath("/run/u/bree.sock",
                                        "/tmp/bree-tui-501/bree.sock", 104) ==
              "/run/u/bree.sock",
          "socket selector preserves a fitting runtime path");
    Check(bree::SelectBreeTuiSocketPath(std::string(103, 'p'),
                                        "/tmp/bree-tui-501/bree.sock", 104) ==
              std::string(103, 'p'),
          "socket selector reserves exactly one byte for the terminator");
    Check(bree::SelectBreeTuiSocketPath(std::string(104, 'p'),
                                        "/tmp/bree-tui-501/bree.sock", 104) ==
              "/tmp/bree-tui-501/bree.sock",
          "socket selector falls back at the native capacity boundary");
  }

  {
    Check(bree::FenceBreeTuiRegistrySnapshot(false, "", "", 0, "registry-a",
                                             "generation-a", 4) ==
              BreeTuiRegistryFenceDecision::kAccept,
          "first terminal snapshot establishes the cursor");
    Check(bree::FenceBreeTuiRegistrySnapshot(
              true, "registry-a", "generation-a", 4, "registry-a",
              "generation-a", 5) == BreeTuiRegistryFenceDecision::kAccept,
          "newer terminal snapshot in one epoch advances the cursor");
    Check(bree::FenceBreeTuiRegistrySnapshot(
              true, "registry-a", "generation-a", 5, "registry-a",
              "generation-a", 5) == BreeTuiRegistryFenceDecision::kIgnore,
          "equal terminal snapshot is idempotent");
    Check(bree::FenceBreeTuiRegistrySnapshot(
              true, "registry-a", "generation-a", 5, "registry-a",
              "generation-a", 4) == BreeTuiRegistryFenceDecision::kRefetch,
          "older same-epoch response cannot time-travel the GUI");
    Check(bree::FenceBreeTuiRegistrySnapshot(
              true, "registry-a", "generation-a", 9, "registry-a",
              "generation-b", 9) == BreeTuiRegistryFenceDecision::kAccept,
          "new daemon generation is an authoritative epoch boundary");
    Check(bree::FenceBreeTuiRegistrySnapshot(
              true, "registry-a", "generation-a", 9, "registry-b",
              "generation-c", 0) == BreeTuiRegistryFenceDecision::kAccept,
          "new durable registry replaces the old namespace");
    Check(bree::FenceBreeTuiRegistrySnapshot(true, "registry-a", "generation-a",
                                             9, "", "generation-c", 10) ==
              BreeTuiRegistryFenceDecision::kInvalid,
          "snapshot without durable registry identity is invalid");
  }

  {
    Check(bree::ValidateBreeTuiTerminalEventRevisions(7, 7, {}),
          "empty event batch is valid only at the requested cursor");
    Check(bree::ValidateBreeTuiTerminalEventRevisions(7, 10, {8, 9, 10}),
          "contiguous event batch reaches its advertised barrier");
    Check(!bree::ValidateBreeTuiTerminalEventRevisions(7, 10, {8, 10}),
          "event gap fails closed to a snapshot");
    Check(!bree::ValidateBreeTuiTerminalEventRevisions(7, 9, {8, 9, 10}),
          "event beyond the advertised barrier is rejected");
    Check(!bree::ValidateBreeTuiTerminalEventRevisions(7, 6, {}),
          "event response cannot move its cursor backwards");
    Check(!bree::ValidateBreeTuiTerminalEventRevisions(
              std::numeric_limits<uint64_t>::max(),
              std::numeric_limits<uint64_t>::max(),
              {std::numeric_limits<uint64_t>::max()}),
          "event revision overflow is rejected");
  }

  {
    constexpr std::string_view kCommit =
        "0123456789abcdef0123456789abcdef01234567";
    constexpr std::string_view kGhosttyCommit =
        "89abcdef0123456789abcdef0123456789abcdef";
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kMinBreeTuiProtocolVersion, 42, kCommit,
              "ffffffffffffffffffffffffffffffffffffffff", kGhosttyCommit,
              kGhosttyCommit) == BreeTuiIdentityError::kBuildCommitMismatch,
          "a stale protocol-v7 build remains eligible for safe replacement");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kMinBreeTuiProtocolVersion, 42, kCommit,
              kCommit, kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "a legacy protocol cannot become ready with a matching stamp");
    Check(bree::ValidateBreeTuiIdentity("bree-tui", 8, 42, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "an intermediate protocol cannot become ready");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kNone,
          "exact stamped identity succeeds");
    Check(bree::ValidateBreeTuiIdentity(
              "not-bree", bree::kBreeTuiProtocolVersion, 42, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "wrong application is rejected");
    Check(bree::ValidateBreeTuiIdentity("bree-tui", 6, 42, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "older incompatible protocol is rejected");
    Check(bree::ValidateBreeTuiIdentity("bree-tui", 10, 42, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "unknown future protocol is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 0, kCommit, kCommit,
                                        kGhosttyCommit, kGhosttyCommit) ==
              BreeTuiIdentityError::kInvalidEndpoint,
          "zero server pid is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42, std::nullopt,
              kCommit, kGhosttyCommit,
              kGhosttyCommit) == BreeTuiIdentityError::kBuildCommitMissing,
          "unstamped production server is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42,
              "ffffffffffffffffffffffffffffffffffffffff",
              kCommit, kGhosttyCommit,
              kGhosttyCommit) == BreeTuiIdentityError::kBuildCommitMismatch,
          "different stamped build is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42, kCommit, kCommit,
              std::nullopt, kGhosttyCommit) ==
              BreeTuiIdentityError::kGhosttyCommitMissing,
          "server without a Ghostty stamp is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42, kCommit, kCommit,
              "ffffffffffffffffffffffffffffffffffffffff",
              kGhosttyCommit) == BreeTuiIdentityError::kGhosttyCommitMismatch,
          "server built from a different Ghostty commit is rejected");
    Check(bree::ValidateBreeTuiIdentity(
              "bree-tui", bree::kBreeTuiProtocolVersion, 42, std::nullopt, "",
              std::nullopt, "") == BreeTuiIdentityError::kNone,
          "source-tree development can omit a build pin");
    Check(!bree::IsReplaceableBreeTuiIdentityError(
              BreeTuiIdentityError::kNone),
          "an exact server does not need replacement");
    Check(!bree::IsReplaceableBreeTuiIdentityError(
              BreeTuiIdentityError::kInvalidEndpoint),
          "an arbitrary endpoint cannot trigger process replacement");
    Check(bree::IsReplaceableBreeTuiIdentityError(
              BreeTuiIdentityError::kBuildCommitMissing) &&
              bree::IsReplaceableBreeTuiIdentityError(
                  BreeTuiIdentityError::kBuildCommitMismatch) &&
              bree::IsReplaceableBreeTuiIdentityError(
                  BreeTuiIdentityError::kGhosttyCommitMissing) &&
              bree::IsReplaceableBreeTuiIdentityError(
                  BreeTuiIdentityError::kGhosttyCommitMismatch),
          "only stale or unstamped bree-tui builds are replaceable");
    Check(!bree::IsReplaceableBreeTuiIdentityError(
              static_cast<BreeTuiIdentityError>(255)),
          "an unclassified identity error fails closed");
  }

  {
    const std::string replay =
        "before\x1b]4;0;rgb:01/02/03\x1b\\middle"
        "\x1b]10;#abcdef\x07"
        "\x1b]4;15;#fefefe\x07"
        "after";
    const std::vector<uint8_t> filtered =
        bree::StripBreeTuiReplayPalette(replay);
    Check(std::string(filtered.begin(), filtered.end()) ==
              "beforemiddle\x1b]10;#abcdef\x07"
              "after",
          "state replay drops only terminated OSC 4 palette definitions");

    const std::string c1 = std::string("a") + static_cast<char>(0x9d) +
                           "4;1;#010203" + static_cast<char>(0x9c) + "b";
    const std::vector<uint8_t> c1_filtered =
        bree::StripBreeTuiReplayPalette(c1);
    Check(std::string(c1_filtered.begin(), c1_filtered.end()) == "ab",
          "state replay drops C1 OSC 4 palette definitions");

    const std::string unterminated = "keep\x1b]4;2;#112233";
    const std::vector<uint8_t> unchanged =
        bree::StripBreeTuiReplayPalette(unterminated);
    Check(std::string(unchanged.begin(), unchanged.end()) == unterminated,
          "unterminated OSC 4 is preserved");

    std::string full_palette = "prefix";
    for (int index = 0; index < 256; ++index) {
      full_palette.append("\x1b]4;");
      full_palette.append(std::to_string(index));
      full_palette.append(";#010203\x1b\\");
    }
    full_palette.append("\x1b]10;#abcdef\x1b\\suffix");
    const std::vector<uint8_t> full_filtered =
        bree::StripBreeTuiReplayPalette(full_palette);
    Check(std::string(full_filtered.begin(), full_filtered.end()) ==
              "prefix\x1b]10;#abcdef\x1b\\suffix",
          "all 256 replay palette slots are removed without touching OSC 10");
  }

  {
    bree::BreeTuiInputQueue input(5);
    Check(input.Push(std::string_view("a\0b", 3)),
          "binary input is queued within the cap");
    Check(input.pending_bytes() == 3, "pending input counts embedded NUL");
    Check(input.BeginWrite() == std::vector<uint8_t>({'a', 0, 'b'}),
          "first input batch preserves exact bytes");
    Check(input.write_in_flight(), "input batch becomes in flight");
    Check(input.Push("cd"), "input coalesces behind an in-flight batch");
    Check(!input.Push("efgh"), "pending input cap rejects the whole new chunk");
    Check(input.BeginWrite().empty(),
          "second input write waits for completion");
    input.FinishWrite();
    Check(input.BeginWrite() == std::vector<uint8_t>({'c', 'd'}),
          "coalesced input starts after completion");
    input.CancelWrite();
    Check(!input.write_in_flight(), "cancel releases input backpressure");
    Check(input.Push("xy"), "queue accepts input after cancellation");
    input.Clear();
    Check(input.pending_bytes() == 0 && !input.write_in_flight(),
          "clear drops pending input and in-flight state");
  }

  {
    bree::BreeTuiResizeCoalescer resizes;
    Check(!resizes.BeginWrite({80, 24}),
          "default desired grid does not emit a redundant resize");
    resizes.SetDesired(0, 0);
    Check(resizes.desired() == bree::BreeTuiGridSize{1, 1},
          "desired resize clamps to a valid grid");
    const std::optional<bree::BreeTuiGridSize> first =
        resizes.BeginWrite({80, 24});
    Check(first && *first == bree::BreeTuiGridSize{1, 1},
          "first changed grid starts a resize");
    resizes.SetDesired(120, 41);
    Check(!resizes.BeginWrite({1, 1}),
          "new resize is held while one is in flight");
    resizes.FinishWrite();
    const std::optional<bree::BreeTuiGridSize> latest =
        resizes.BeginWrite({1, 1});
    Check(latest && *latest == bree::BreeTuiGridSize{120, 41},
          "resize completion releases only the latest desired grid");
    resizes.CancelWrite();
    Check(!resizes.write_in_flight(), "resize cancellation releases the gate");
  }

  {
    BreeTuiLineFramer framer;
    std::vector<std::string> lines;
    Check(framer.Push("{\"id\":1", &lines) == BreeTuiLineFramer::Result::kOk,
          "partial first read succeeds");
    Check(lines.empty(), "partial line is buffered");
    Check(framer.buffered_bytes() == 7, "partial byte count is exact");
    Check(framer.Push(",\"ok\":true}\n", &lines) ==
              BreeTuiLineFramer::Result::kOk,
          "partial second read succeeds");
    CheckLines(lines, {"{\"id\":1,\"ok\":true}"},
               "partial reads join into one frame");
    Check(framer.buffered_bytes() == 0, "complete frame drains buffer");
  }

  {
    BreeTuiLineFramer framer;
    std::vector<std::string> lines;
    Check(framer.Push("\n{\"event\":\"output\"}\r\n\n{\"id\":2}\ntrail",
                      &lines) == BreeTuiLineFramer::Result::kOk,
          "mixed frames succeed");
    CheckLines(lines, {"{\"event\":\"output\"}", "{\"id\":2}"},
               "blank lines are ignored and CRLF is stripped");
    Check(framer.buffered_bytes() == 5, "trailing partial line remains");
    lines.clear();
    Check(framer.Push("ing\n", &lines) == BreeTuiLineFramer::Result::kOk,
          "trailing frame completes");
    CheckLines(lines, {"trailing"}, "trailing pieces preserve order");
  }

  {
    BreeTuiLineFramer framer(8);
    std::vector<std::string> lines;
    Check(framer.Push("12345678\n", &lines) == BreeTuiLineFramer::Result::kOk,
          "line exactly at cap succeeds");
    CheckLines(lines, {"12345678"}, "capped line is emitted");
    lines.clear();
    Check(framer.Push("12345", &lines) == BreeTuiLineFramer::Result::kOk,
          "oversize prefix buffers");
    Check(
        framer.Push("6789", &lines) == BreeTuiLineFramer::Result::kLineTooLarge,
        "oversize frame is rejected across reads");
    Check(framer.buffered_bytes() == 0, "overflow clears buffered tail");
    Check(framer.Push("ok\n", &lines) == BreeTuiLineFramer::Result::kOk,
          "framer can restart after overflow");
    CheckLines(lines, {"ok"}, "restart does not retain oversized bytes");
  }

  std::printf("bree-tui-protocol: %d checks, %d failures\n", checks, failures);
  return failures == 0 ? 0 : 1;
}
