// Copyright 2026 Manaflow, Inc.
// SPDX-License-Identifier: GPL-3.0-or-later

// Host-compilable tests for the bree terminal-host binary wire protocol. No
// Chromium or gtest dependencies.

#include "chrome/services/bree_terminal_renderer/public/cpp/bree_terminal_host_protocol.h"

#include <algorithm>
#include <cstdio>
#include <string>
#include <string_view>
#include <type_traits>
#include <utility>
#include <vector>

namespace {

int checks = 0;
int failures = 0;

constexpr uint16_t kRustTerminalHostProtocolVersion = 3;
constexpr size_t kRustTerminalHostMaxReplay = 15'692'632;
constexpr size_t kRustTerminalHostMaxKittyImageAliases = 4'096;
constexpr size_t kRustTerminalHostKittyReplayStateLength = 52;

void Check(bool condition, const char* message) {
  ++checks;
  if (!condition) {
    ++failures;
    std::fprintf(stderr, "FAIL: %s\n", message);
  }
}

std::string_view Bytes(const std::vector<uint8_t>& bytes) {
  return std::string_view(reinterpret_cast<const char*>(bytes.data()),
                          bytes.size());
}

template <size_t N>
std::array<uint8_t, N> Filled(uint8_t value) {
  std::array<uint8_t, N> result;
  result.fill(value);
  return result;
}

template <typename Payload, typename = void>
struct HasKittyImageAliases : std::false_type {};

template <typename Payload>
struct HasKittyImageAliases<
    Payload,
    std::void_t<
        decltype(std::declval<Payload&>().kitty_image_aliases)>>
    : std::true_type {};

template <typename Payload, typename = void>
struct HasCellPixels : std::false_type {};

template <typename Payload>
struct HasCellPixels<
    Payload,
    std::void_t<decltype(std::declval<Payload&>().cell_width),
                decltype(std::declval<Payload&>().cell_height)>>
    : std::true_type {};

template <typename Payload, typename = void>
struct HasKittyReplayState : std::false_type {};

template <typename Payload>
struct HasKittyReplayState<
    Payload,
    std::void_t<decltype(std::declval<Payload&>().kitty_state)>>
    : std::true_type {};

template <typename Grant, typename = void>
struct HasProtocolVersion : std::false_type {};

template <typename Grant>
struct HasProtocolVersion<
    Grant,
    std::void_t<decltype(std::declval<Grant&>().protocol_version)>>
    : std::true_type {};

template <typename Grant>
bool GrantProtocolVersionIs(const Grant& grant, uint16_t expected) {
  if constexpr (!HasProtocolVersion<Grant>::value) {
    return false;
  } else {
    return grant.protocol_version == expected;
  }
}

template <typename Payload>
constexpr size_t ReplayMetadataSuffixLength() {
  return (HasCellPixels<Payload>::value ? 4 : 0) +
         (HasKittyReplayState<Payload>::value
              ? kRustTerminalHostKittyReplayStateLength
              : 0);
}

template <typename Payload>
bool CellPixelsAre(const Payload& payload,
                   uint16_t expected_width,
                   uint16_t expected_height) {
  if constexpr (!HasCellPixels<Payload>::value) {
    return false;
  } else {
    return payload.cell_width == expected_width &&
           payload.cell_height == expected_height;
  }
}

template <typename Payload>
using PayloadEncoder = bree::TerminalHostProtocolError (*)(
    const Payload&,
    std::vector<uint8_t>*);

template <typename Payload>
using PayloadDecoder = bree::TerminalHostProtocolError (*)(
    std::string_view,
    Payload*);

template <typename Payload>
bool KittyAliasesRoundTrip(PayloadEncoder<Payload> encode,
                           PayloadDecoder<Payload> decode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}, Alias{42, 77}};
    std::vector<uint8_t> payload;
    Payload decoded;
    if (encode(value, &payload) != bree::TerminalHostProtocolError::kNone ||
        decode(Bytes(payload), &decoded) !=
            bree::TerminalHostProtocolError::kNone ||
        !(decoded == value)) {
      return false;
    }
    constexpr std::array<uint8_t, 18> kAliasSuffix = {
        2, 0, 41, 0, 0, 0, 77, 0, 0, 0, 42, 0, 0, 0, 77, 0, 0, 0,
    };
    const size_t trailing = ReplayMetadataSuffixLength<Payload>();
    return payload.size() >= kAliasSuffix.size() + trailing &&
           std::equal(kAliasSuffix.begin(), kAliasSuffix.end(),
                      payload.end() - trailing - kAliasSuffix.size());
  }
}

enum class InvalidKittyAlias {
  kZeroId,
  kZeroNumber,
  kDuplicateId,
};

template <typename Payload>
bool KittyAliasEncoderRejects(PayloadEncoder<Payload> encode,
                              InvalidKittyAlias invalid) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    switch (invalid) {
      case InvalidKittyAlias::kZeroId:
        value.kitty_image_aliases = {Alias{0, 77}};
        break;
      case InvalidKittyAlias::kZeroNumber:
        value.kitty_image_aliases = {Alias{41, 0}};
        break;
      case InvalidKittyAlias::kDuplicateId:
        value.kitty_image_aliases = {Alias{41, 77}, Alias{41, 78}};
        break;
    }
    std::vector<uint8_t> untouched = {0xa5};
    return encode(value, &untouched) ==
               bree::TerminalHostProtocolError::kMalformedPayload &&
           untouched == std::vector<uint8_t>({0xa5});
  }
}

template <typename Payload>
bool KittyAliasDecoderRejects(PayloadEncoder<Payload> encode,
                              PayloadDecoder<Payload> decode,
                              InvalidKittyAlias invalid) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}, Alias{42, 78}};
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != bree::TerminalHostProtocolError::kNone ||
        payload.size() < 18) {
      return false;
    }
    const size_t aliases =
        payload.size() - 18 - ReplayMetadataSuffixLength<Payload>();
    switch (invalid) {
      case InvalidKittyAlias::kZeroId:
        std::fill(payload.begin() + aliases + 2,
                  payload.begin() + aliases + 6, 0);
        break;
      case InvalidKittyAlias::kZeroNumber:
        std::fill(payload.begin() + aliases + 6,
                  payload.begin() + aliases + 10, 0);
        break;
      case InvalidKittyAlias::kDuplicateId:
        std::copy(payload.begin() + aliases + 2,
                  payload.begin() + aliases + 6,
                  payload.begin() + aliases + 10);
        break;
    }
    Payload decoded;
    return decode(Bytes(payload), &decoded) ==
           bree::TerminalHostProtocolError::kMalformedPayload;
  }
}

template <typename Payload>
bool KittyAliasDecoderRejectsBadFraming(PayloadEncoder<Payload> encode,
                                        PayloadDecoder<Payload> decode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases = {Alias{41, 77}};
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != bree::TerminalHostProtocolError::kNone) {
      return false;
    }
    Payload decoded;
    std::vector<uint8_t> truncated = payload;
    truncated.pop_back();
    std::vector<uint8_t> trailing = payload;
    trailing.push_back(0);
    return decode(Bytes(truncated), &decoded) ==
               bree::TerminalHostProtocolError::kMalformedPayload &&
           decode(Bytes(trailing), &decoded) ==
               bree::TerminalHostProtocolError::kMalformedPayload;
  }
}

template <typename Payload>
bool KittyAliasCountIsBounded(PayloadEncoder<Payload> encode) {
  if constexpr (!HasKittyImageAliases<Payload>::value) {
    return false;
  } else {
    using AliasVector =
        std::decay_t<decltype(std::declval<Payload&>().kitty_image_aliases)>;
    using Alias = typename AliasVector::value_type;
    Payload value;
    value.kitty_image_aliases.reserve(
        kRustTerminalHostMaxKittyImageAliases + 1);
    for (size_t index = 0;
         index < kRustTerminalHostMaxKittyImageAliases; ++index) {
      value.kitty_image_aliases.push_back(
          Alias{static_cast<uint32_t>(index + 1),
                static_cast<uint32_t>(index + 10'001)});
    }
    std::vector<uint8_t> payload;
    if (encode(value, &payload) != bree::TerminalHostProtocolError::kNone) {
      return false;
    }
    value.kitty_image_aliases.push_back(
        Alias{static_cast<uint32_t>(
                  kRustTerminalHostMaxKittyImageAliases + 1),
              static_cast<uint32_t>(
                  kRustTerminalHostMaxKittyImageAliases + 10'001)});
    payload = {0xa5};
    return encode(value, &payload) ==
               bree::TerminalHostProtocolError::kPayloadTooLarge &&
           payload == std::vector<uint8_t>({0xa5});
  }
}

bree::TerminalHostFrame SampleFrame() {
  bree::TerminalHostFrame frame;
  frame.kind = bree::TerminalHostMessageKind::kOutput;
  frame.flags = 0x11223344;
  frame.request_id = 0x0102030405060708ULL;
  frame.sequence = 0x1112131415161718ULL;
  frame.payload = {0xaa, 0xbb, 0xcc};
  return frame;
}

void TestFrameGoldenAndKinds() {
  using Error = bree::TerminalHostProtocolError;
  Check(bree::kTerminalHostProtocolVersion ==
            kRustTerminalHostProtocolVersion,
        "terminal-host default protocol version matches Rust v3");
  Check(bree::kTerminalHostFlagColorsFollow == 1u,
        "COLORS_FOLLOW is exactly header flag bit zero");
  Check(bree::kTerminalHostFlagViewerSizeAcks == 2u,
        "VIEWER_SIZE_ACKS is exactly header flag bit one");
  std::vector<uint8_t> encoded;
  Check(bree::EncodeTerminalHostFrame(SampleFrame(), &encoded) == Error::kNone,
        "sample frame encodes");
  Check(encoded == std::vector<uint8_t>({
                       'C',  'M',  'T',  'H',  0x03, 0x00, 0x06, 0x00, 0x44,
                       0x33, 0x22, 0x11, 0x03, 0x00, 0x00, 0x00, 0x08, 0x07,
                       0x06, 0x05, 0x04, 0x03, 0x02, 0x01, 0x18, 0x17, 0x16,
                       0x15, 0x14, 0x13, 0x12, 0x11, 0xaa, 0xbb, 0xcc,
                   }),
        "frame is the Rust golden byte sequence");

  bree::TerminalHostFrameDecoder decoder;
  std::vector<bree::TerminalHostFrame> frames;
  Check(decoder.Push(Bytes(encoded), &frames) == Error::kNone,
        "golden frame decodes");
  Check(frames == std::vector<bree::TerminalHostFrame>({SampleFrame()}),
        "golden frame fields round trip");
  Check(decoder.Finish() == Error::kNone, "complete decoder finishes cleanly");

  bree::TerminalHostFrameHeader header;
  Check(bree::DecodeTerminalHostFrameHeader(
            Bytes(encoded).substr(0, bree::kTerminalHostHeaderLength), 3,
            &header) == Error::kNone &&
            header.version == 3 &&
            header.kind == bree::TerminalHostMessageKind::kOutput &&
            header.flags == 0x11223344 && header.payload_length == 3 &&
            header.request_id == 0x0102030405060708ULL &&
            header.sequence == 0x1112131415161718ULL,
        "header-only decoder exposes every fixed little-endian field");
  Check(bree::DecodeTerminalHostFrameHeader(
            Bytes(encoded).substr(0, bree::kTerminalHostHeaderLength), 2,
            &header) == Error::kPayloadTooLarge,
        "header-only decoder enforces caller payload bound");

  const std::vector<std::pair<bree::TerminalHostMessageKind, uint16_t>> kinds =
      {
          {bree::TerminalHostMessageKind::kBootstrap, 1},
          {bree::TerminalHostMessageKind::kReady, 2},
          {bree::TerminalHostMessageKind::kClientHello, 3},
          {bree::TerminalHostMessageKind::kHostHello, 4},
          {bree::TerminalHostMessageKind::kSnapshot, 5},
          {bree::TerminalHostMessageKind::kOutput, 6},
          {bree::TerminalHostMessageKind::kResized, 7},
          {bree::TerminalHostMessageKind::kColors, 8},
          {bree::TerminalHostMessageKind::kTitle, 9},
          {bree::TerminalHostMessageKind::kPwd, 10},
          {bree::TerminalHostMessageKind::kBell, 11},
          {bree::TerminalHostMessageKind::kExit, 12},
          {bree::TerminalHostMessageKind::kResyncRequired, 13},
          {bree::TerminalHostMessageKind::kLaunch, 14},
          {bree::TerminalHostMessageKind::kCapability, 15},
          {bree::TerminalHostMessageKind::kResizeAck, 16},
          {bree::TerminalHostMessageKind::kClearHistoryAck, 17},
          {bree::TerminalHostMessageKind::kCellPixelSizeAck, 18},
          {bree::TerminalHostMessageKind::kKittyGraphicsLimitsAck, 19},
          {bree::TerminalHostMessageKind::kInput, 100},
          {bree::TerminalHostMessageKind::kPaste, 101},
          {bree::TerminalHostMessageKind::kViewerSize, 102},
          {bree::TerminalHostMessageKind::kReleaseViewer, 103},
          {bree::TerminalHostMessageKind::kTerminate, 104},
          {bree::TerminalHostMessageKind::kMintCapability, 105},
          {bree::TerminalHostMessageKind::kSetDefaults, 106},
          {bree::TerminalHostMessageKind::kClearHistory, 107},
          {bree::TerminalHostMessageKind::kSetCellPixelSize, 108},
          {bree::TerminalHostMessageKind::kSetKittyGraphicsLimits, 109},
      };
  std::vector<uint8_t> stream;
  for (const auto& [kind, wire_number] : kinds) {
    Check(static_cast<uint16_t>(kind) == wire_number,
          "message kind has the exact Rust wire number");
    bree::TerminalHostFrame frame;
    frame.kind = kind;
    std::vector<uint8_t> one;
    Check(bree::EncodeTerminalHostFrame(frame, &one) == Error::kNone,
          "known message kind encodes");
    stream.insert(stream.end(), one.begin(), one.end());
  }
  frames.clear();
  bree::TerminalHostFrameDecoder all_kinds_decoder;
  Check(all_kinds_decoder.Push(Bytes(stream), &frames) == Error::kNone,
        "all known coalesced message kinds decode");
  Check(frames.size() == kinds.size(), "every message kind produced a frame");
  for (size_t index = 0; index < std::min(frames.size(), kinds.size());
       ++index) {
    Check(frames[index].kind == kinds[index].first,
          "message kind number decodes exactly");
  }
}

std::string Hex(const std::vector<uint8_t>& bytes) {
  constexpr char kDigits[] = "0123456789abcdef";
  std::string result;
  result.resize(bytes.size() * 2);
  for (size_t index = 0; index < bytes.size(); ++index) {
    result[index * 2] = kDigits[bytes[index] >> 4];
    result[index * 2 + 1] = kDigits[bytes[index] & 0x0f];
  }
  return result;
}

void TestRendererGrantValidation() {
  using Error = bree::TerminalHostRendererGrantError;
  using Rights = bree::TerminalHostCapabilityRights;

  bree::TerminalHostId terminal = Filled<16>(0x11);
  terminal[6] = 0x41;
  terminal[8] = 0x81;
  bree::TerminalHostIncarnation incarnation = Filled<16>(0x22);
  incarnation[6] = 0x42;
  incarnation[8] = 0x82;
  const std::string terminal_hex = bree::EncodeTerminalHostId(terminal);
  const std::string incarnation_hex = bree::EncodeTerminalHostId(incarnation);
  const std::string token_hex = Hex(std::vector<uint8_t>(32, 0xa5));
  const std::string endpoint = "/tmp/bree-th-501/" + terminal_hex + ".sock";

  bree::TerminalHostId decoded_terminal{};
  Check(bree::DecodeTerminalHostUuidV4(terminal_hex, &decoded_terminal) &&
            decoded_terminal == terminal &&
            bree::IsValidTerminalHostUuidV4(decoded_terminal),
        "stable terminal UUID decodes for create/resolve responses");
  decoded_terminal = Filled<16>(0xee);
  Check(!bree::DecodeTerminalHostUuidV4(
            std::string("A") + terminal_hex.substr(1), &decoded_terminal) &&
            decoded_terminal == Filled<16>(0xee),
        "stable UUID decoder rejects noncanonical text atomically");
  Check(!bree::DecodeTerminalHostUuidV4(terminal_hex, nullptr),
        "stable UUID decoder requires an output destination");

  bree::TerminalHostRendererGrant grant;
  Check(bree::ValidateTerminalHostRendererGrant(
            endpoint, terminal_hex, incarnation_hex, token_hex,
            static_cast<uint32_t>(Rights::kRenderer),
            bree::kTerminalHostProtocolVersionV1, 30000, 30000,
            &grant) == Error::kNone,
        "canonical renderer grant validates");
  Check(grant.endpoint == endpoint && grant.terminal_id == terminal &&
            grant.incarnation == incarnation &&
            grant.token == Filled<32>(0xa5) &&
            grant.rights == Rights::kRenderer &&
            grant.protocol_version == bree::kTerminalHostProtocolVersionV1 &&
            grant.ttl_ms == 30000,
        "validated renderer grant contains typed binary identities and token");
  Check(HasProtocolVersion<bree::TerminalHostRendererGrant>::value &&
            GrantProtocolVersionIs(grant,
                                   bree::kTerminalHostProtocolVersionV1),
        "validated renderer grant carries the selected host protocol version");
  using Validator = decltype(&bree::ValidateTerminalHostRendererGrant);
  Check(
      (std::is_invocable_r_v<
          Error, Validator, std::string_view, std::string_view,
          std::string_view, std::string_view, uint64_t, uint64_t, uint64_t,
          uint64_t, bree::TerminalHostRendererGrant*>),
      "renderer grant validation requires the selected protocol version");
  const bree::TerminalHostClientHello renderer_hello =
      bree::TerminalHostClientHelloForRendererGrant(grant);
  Check(renderer_hello.min_version ==
                bree::kTerminalHostProtocolVersionV1 &&
            renderer_hello.max_version ==
                bree::kTerminalHostProtocolVersionV1 &&
            renderer_hello.role == bree::TerminalHostClientRole::kRenderer &&
            renderer_hello.requested_rights == Rights::kRenderer &&
            renderer_hello.terminal_id == terminal &&
            renderer_hello.token == Filled<32>(0xa5),
        "validated grant pins renderer Hello to the selected host version");
  Check(std::string(bree::TerminalHostRendererGrantErrorMessage(Error::kNone))
            .empty(),
        "successful grant validation has no error text");

  const auto Validate = [&](std::string_view candidate_endpoint,
                            std::string_view candidate_terminal,
                            std::string_view candidate_incarnation,
                            std::string_view candidate_token,
                            uint64_t candidate_rights, uint64_t candidate_ttl,
                            uint64_t expected_ttl) {
    bree::TerminalHostRendererGrant output;
    output.endpoint = "untouched";
    const Error error = bree::ValidateTerminalHostRendererGrant(
        candidate_endpoint, candidate_terminal, candidate_incarnation,
        candidate_token, candidate_rights,
        bree::kTerminalHostProtocolVersion, candidate_ttl, expected_ttl,
        &output);
    Check(error == Error::kNone || output.endpoint == "untouched",
          "invalid grant leaves typed destination untouched");
    return error;
  };

  for (const std::string& invalid :
       {std::string(), std::string("relative.sock"),
        std::string("/private/tmp/bree-th-501/") + terminal_hex + ".sock",
        std::string("/tmp/bree-th-/") + terminal_hex + ".sock",
        std::string("/tmp/bree-th-user/") + terminal_hex + ".sock",
        std::string("/tmp/bree-th-501/nested/") + terminal_hex + ".sock",
        std::string("/tmp/bree-th-501/") + terminal_hex,
        std::string("/tmp/bree-th-501/") + incarnation_hex + ".sock"}) {
    Check(Validate(invalid, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                   30000) == Error::kInvalidEndpoint,
          "noncanonical renderer endpoint is rejected");
  }
  std::string nul_endpoint = endpoint;
  nul_endpoint.insert(5, 1, '\0');
  Check(Validate(std::string_view(nul_endpoint.data(), nul_endpoint.size()),
                 terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidEndpoint,
        "renderer endpoint rejects embedded NUL");
  const std::string long_endpoint =
      "/tmp/bree-th-501/" + std::string(90, 'a') + ".sock";
  Check(Validate(long_endpoint, terminal_hex, incarnation_hex, token_hex, 7,
                 30000, 30000) == Error::kInvalidEndpoint,
        "renderer endpoint rejects paths beyond macOS sockaddr_un capacity");

  std::string bad_terminal = terminal_hex.substr(1);
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID has exact width");
  bad_terminal = terminal_hex;
  bad_terminal[0] = 'A';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID requires canonical lowercase hex");
  bad_terminal = terminal_hex;
  bad_terminal[12] = '3';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal identity must be UUIDv4");
  bad_terminal = terminal_hex;
  bad_terminal[16] = '4';
  Check(Validate(endpoint, bad_terminal, incarnation_hex, token_hex, 7, 30000,
                 30000) == Error::kInvalidTerminalId,
        "renderer terminal UUID requires the RFC variant");

  std::string bad_incarnation = incarnation_hex;
  bad_incarnation[0] = 'z';
  Check(Validate(endpoint, terminal_hex, bad_incarnation, token_hex, 7, 30000,
                 30000) == Error::kInvalidIncarnation,
        "renderer incarnation rejects non-hex text");
  bad_incarnation = incarnation_hex;
  bad_incarnation[12] = '5';
  Check(Validate(endpoint, terminal_hex, bad_incarnation, token_hex, 7, 30000,
                 30000) == Error::kInvalidIncarnation,
        "renderer incarnation must be UUIDv4");

  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex.substr(2),
                 7, 30000, 30000) == Error::kInvalidToken,
        "renderer capability token has exact 32-byte width");
  std::string bad_token = token_hex;
  bad_token[0] = 'A';
  Check(Validate(endpoint, terminal_hex, incarnation_hex, bad_token, 7, 30000,
                 30000) == Error::kInvalidToken,
        "renderer capability token requires canonical lowercase hex");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, std::string(64, '0'),
                 7, 30000, 30000) == Error::kInvalidToken,
        "renderer capability token cannot be all zero");

  for (const uint64_t invalid_rights :
       {0ULL, 1ULL, 3ULL, 15ULL, 0x1'0000'0007ULL}) {
    Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex,
                   invalid_rights, 30000, 30000) == Error::kInvalidRights,
          "renderer grant requires the exact read/input/resize rights set");
  }
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 0,
                 30000) == Error::kInvalidTtl,
        "renderer grant rejects zero response TTL");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 60001,
                 60001) == Error::kInvalidTtl,
        "renderer grant rejects response TTL above 60 seconds");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 0) == Error::kInvalidTtl,
        "renderer grant rejects invalid requested TTL");
  Check(Validate(endpoint, terminal_hex, incarnation_hex, token_hex, 7, 30000,
                 29999) == Error::kInvalidTtl,
        "renderer grant TTL must echo the exact request");
  for (const uint64_t invalid_version : {0ULL, 4ULL, 65537ULL}) {
    bree::TerminalHostRendererGrant output;
    output.endpoint = "untouched";
    Check(bree::ValidateTerminalHostRendererGrant(
              endpoint, terminal_hex, incarnation_hex, token_hex, 7,
              invalid_version, 30000, 30000,
              &output) == Error::kInvalidProtocolVersion &&
              output.endpoint == "untouched",
          "renderer grant rejects an unsupported host protocol version");
  }
  Check(bree::ValidateTerminalHostRendererGrant(
            endpoint, terminal_hex, incarnation_hex, token_hex, 7,
            bree::kTerminalHostProtocolVersion, 30000, 30000,
            nullptr) == Error::kInvalidEndpoint,
        "renderer grant requires an output destination");
}

void TestFragmentationAndCoalescing() {
  using Error = bree::TerminalHostProtocolError;
  bree::TerminalHostFrame second;
  second.kind = bree::TerminalHostMessageKind::kViewerSize;
  second.request_id = 9;
  second.payload = {80, 0, 24, 0};

  std::vector<uint8_t> stream;
  std::vector<uint8_t> encoded_second;
  Check(bree::EncodeTerminalHostFrame(SampleFrame(), &stream) == Error::kNone,
        "first fragmented frame encodes");
  Check(bree::EncodeTerminalHostFrame(second, &encoded_second) == Error::kNone,
        "second fragmented frame encodes");
  stream.insert(stream.end(), encoded_second.begin(), encoded_second.end());

  bree::TerminalHostFrameDecoder fragmented;
  std::vector<bree::TerminalHostFrame> frames;
  for (uint8_t byte : stream) {
    const char one = static_cast<char>(byte);
    Check(fragmented.Push(std::string_view(&one, 1), &frames) == Error::kNone,
          "one-byte fragment is accepted");
  }
  Check(frames == std::vector<bree::TerminalHostFrame>({SampleFrame(), second}),
        "one-byte fragments preserve frame boundaries");
  Check(fragmented.Finish() == Error::kNone,
        "fragmented decoder drains completely");

  frames.clear();
  bree::TerminalHostFrameDecoder coalesced;
  Check(coalesced.Push(Bytes(stream), &frames) == Error::kNone,
        "coalesced frames decode in one push");
  Check(frames == std::vector<bree::TerminalHostFrame>({SampleFrame(), second}),
        "coalesced frames preserve order");
}

void TestMalformedFrames() {
  using Error = bree::TerminalHostProtocolError;
  std::vector<uint8_t> encoded;
  Check(bree::EncodeTerminalHostFrame(SampleFrame(), &encoded) == Error::kNone,
        "malformed-frame fixture encodes");

  auto DecodeError = [](const std::vector<uint8_t>& bytes) {
    bree::TerminalHostFrameDecoder decoder;
    std::vector<bree::TerminalHostFrame> frames;
    return decoder.Push(Bytes(bytes), &frames);
  };

  std::vector<uint8_t> bad = encoded;
  bad[0] = 'X';
  Check(DecodeError(bad) == Error::kInvalidMagic, "bad magic is rejected");
  bad = encoded;
  bad[4] = 0;
  bad[5] = 0;
  Check(DecodeError(bad) == Error::kInvalidVersion,
        "zero header version is rejected");
  bad = encoded;
  bad[4] = 3;
  bree::TerminalHostFrameDecoder future_version;
  std::vector<bree::TerminalHostFrame> frames;
  Check(future_version.Push(Bytes(bad), &frames) == Error::kNone &&
            frames.size() == 1 && frames[0].version == 3,
        "nonzero frame versions remain parseable before hello negotiation");
  bad = encoded;
  bad[6] = 0xe7;
  bad[7] = 0x03;
  Check(DecodeError(bad) == Error::kUnknownMessageKind,
        "unknown message kind is rejected");

  bad = encoded;
  bad.resize(bree::kTerminalHostHeaderLength);
  bad[12] = 65;
  bad[13] = bad[14] = bad[15] = 0;
  bree::TerminalHostFrameDecoder bounded(64);
  Check(bounded.Push(Bytes(bad), &frames) == Error::kPayloadTooLarge,
        "advertised payload over the caller cap is rejected at the header");
  Check(bounded.buffered_bytes() == bree::kTerminalHostHeaderLength,
        "oversize header does not allocate or retain advertised payload");
  Check(bounded.failed(), "malformed stream poisons decoder");
  Check(bounded.Push({}, &frames) == Error::kDecoderFailed,
        "poisoned decoder cannot resume at an attacker-selected offset");
  Check(bounded.Finish() == Error::kDecoderFailed,
        "poisoned decoder cannot finish successfully");

  bree::TerminalHostFrameDecoder short_header;
  Check(short_header.Push(Bytes(encoded).substr(0, 8), &frames) == Error::kNone,
        "partial header buffers");
  Check(short_header.buffered_bytes() == 8,
        "partial header byte count is exact");
  Check(short_header.Finish() == Error::kTruncated,
        "partial header is truncated at EOF");

  bree::TerminalHostFrameDecoder short_payload;
  Check(short_payload.Push(
            Bytes(encoded).substr(0, bree::kTerminalHostHeaderLength + 1),
            &frames) == Error::kNone,
        "partial payload buffers");
  Check(short_payload.Finish() == Error::kTruncated,
        "partial payload is truncated at EOF");

  bree::TerminalHostFrame too_large;
  too_large.kind = bree::TerminalHostMessageKind::kInput;
  too_large.payload.resize(bree::kTerminalHostMaxFramePayload + 1);
  std::vector<uint8_t> untouched = {7, 8, 9};
  Check(bree::EncodeTerminalHostFrame(too_large, &untouched) ==
            Error::kPayloadTooLarge,
        "encoder enforces the global frame cap");
  Check(untouched == std::vector<uint8_t>({7, 8, 9}),
        "failed frame encode leaves destination untouched");
  bree::TerminalHostFrame unknown;
  unknown.kind = static_cast<bree::TerminalHostMessageKind>(999);
  Check(bree::EncodeTerminalHostFrame(unknown, &untouched) ==
            Error::kUnknownMessageKind,
        "encoder rejects forged enum values");
}

void TestHelloPayloads() {
  using Error = bree::TerminalHostProtocolError;
  using Rights = bree::TerminalHostCapabilityRights;

  bree::TerminalHostClientHello client;
  client.min_version = 1;
  client.max_version = 0x0203;
  client.role = bree::TerminalHostClientRole::kRenderer;
  client.requested_rights = Rights::kRead | Rights::kInput;
  client.terminal_id = Filled<16>(0x44);
  client.token = Filled<32>(0xa5);
  std::vector<uint8_t> payload;
  Check(bree::EncodeTerminalHostClientHello(client, &payload) == Error::kNone,
        "client hello encodes");
  Check(payload.size() == 60, "client hello has the Rust fixed width");
  Check(std::equal(
            payload.begin(), payload.begin() + 12,
            std::vector<uint8_t>({1, 0, 3, 2, 2, 0, 0, 0, 3, 0, 0, 0}).begin()),
        "client hello prefix and reserved bytes are little-endian");
  bree::TerminalHostClientHello decoded_client;
  Check(bree::DecodeTerminalHostClientHello(Bytes(payload), &decoded_client) ==
                Error::kNone &&
            decoded_client == client,
        "client hello round trips exactly");

  std::vector<uint8_t> malformed = payload;
  malformed[5] = 1;
  Check(bree::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects nonzero reserved bytes");
  malformed = payload;
  malformed[4] = 99;
  Check(bree::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects unknown roles");
  malformed = payload;
  malformed[11] = 0x80;
  Check(bree::DecodeTerminalHostClientHello(
            Bytes(malformed), &decoded_client) == Error::kMalformedPayload,
        "client hello rejects unknown capability bits");
  Check(bree::DecodeTerminalHostClientHello(Bytes(payload).substr(1),
                                            &decoded_client) ==
            Error::kMalformedPayload,
        "client hello rejects wrong fixed width");

  bree::TerminalHostHostHello host;
  host.selected_version = 2;
  host.granted_rights = Rights::kRead;
  host.terminal_id = client.terminal_id;
  host.incarnation = Filled<16>(7);
  Check(bree::EncodeTerminalHostHostHello(host, &payload) == Error::kNone,
        "host hello encodes");
  Check(payload.size() == 40 && payload[0] == 2 && payload[1] == 0 &&
            payload[2] == 0 && payload[3] == 0 && payload[4] == 1,
        "host hello has fixed width and little-endian reserved prefix");
  bree::TerminalHostHostHello decoded_host;
  Check(bree::DecodeTerminalHostHostHello(Bytes(payload), &decoded_host) ==
                Error::kNone &&
            decoded_host == host,
        "host hello round trips exactly");
  malformed = payload;
  malformed[2] = 1;
  Check(bree::DecodeTerminalHostHostHello(Bytes(malformed), &decoded_host) ==
            Error::kMalformedPayload,
        "host hello rejects nonzero reserved bytes");
  malformed = payload;
  malformed[7] = 0x40;
  Check(bree::DecodeTerminalHostHostHello(Bytes(malformed), &decoded_host) ==
            Error::kMalformedPayload,
        "host hello rejects unknown capability bits");

  Check(bree::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kRead, bree::TerminalHostClientRole::kDaemonMirror),
        "daemon mirror may read");
  Check(!bree::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kInput, bree::TerminalHostClientRole::kDaemonMirror),
        "daemon mirror may not write input");
  Check(bree::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kRead | Rights::kInput | Rights::kResize,
            bree::TerminalHostClientRole::kRenderer),
        "renderer may read, input, and resize");
  Check(!bree::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kTerminate, bree::TerminalHostClientRole::kRenderer),
        "renderer may not terminate");
  Check(bree::AreTerminalHostCapabilityRightsAllowedForRole(
            Rights::kAdmin, bree::TerminalHostClientRole::kAdmin),
        "admin role may request every known right");
}

void TestSnapshotPayload() {
  using Error = bree::TerminalHostProtocolError;
  bree::TerminalHostSnapshot snapshot;
  snapshot.cols = 120;
  snapshot.rows = 41;
  snapshot.cell_width = 9;
  snapshot.cell_height = 18;
  snapshot.pid = 0x01020304;
  snapshot.replay = {0, 0xff, 'A'};
  snapshot.cwd = "/tmp/\xe2\x98\x83";
  snapshot.command = {"/bin/zsh", "-l"};

  std::vector<uint8_t> payload;
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) == Error::kNone,
        "snapshot payload encodes");
  Check(payload.size() > 15 && payload[0] == 120 && payload[1] == 0 &&
            payload[2] == 41 && payload[3] == 0 && payload[4] == 4 &&
            payload[5] == 3 && payload[6] == 2 && payload[7] == 1 &&
            payload[8] == 3 && payload[9] == 0 && payload[10] == 0 &&
            payload[11] == 0 && payload[12] == 0 && payload[13] == 0xff &&
            payload[14] == 'A' && payload[15] == 1,
        "snapshot scalar and replay fields match Rust layout");
  bree::TerminalHostSnapshot decoded;
  Check(bree::DecodeTerminalHostSnapshot(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == snapshot,
        "snapshot round trips replay, metadata, cell pixels, and Kitty state");
  Check(payload.size() >= 4 + kRustTerminalHostKittyReplayStateLength &&
            std::equal(
                payload.end() - kRustTerminalHostKittyReplayStateLength - 4,
                payload.end() - kRustTerminalHostKittyReplayStateLength,
                       std::array<uint8_t, 4>{9, 0, 18, 0}.begin()),
        "snapshot cell pixels match the Rust v2 suffix");

  bree::TerminalHostSnapshot golden;
  golden.cols = 1;
  golden.rows = 2;
  golden.cell_width = 9;
  golden.cell_height = 18;
  golden.kitty_state.limits = {1, 2, 3, 4};
  golden.kitty_state.replay_next_image_ids = {5, 7};
  golden.kitty_state.next_image_ids = {6, 8};
  Check(bree::EncodeTerminalHostSnapshot(golden, &payload) == Error::kNone &&
            payload == std::vector<uint8_t>({
                           1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0,
                           0, 0, 0, 0, 0, 0, 9, 0, 18, 0, 1, 0,
                           0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0,
                           0, 0, 3, 0, 0, 0, 0, 0, 0, 0, 4, 0,
                           0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5, 0,
                           0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0,
                           0, 0,
                       }),
        "snapshot exact bytes match the Rust v3 golden payload");

  bree::TerminalHostSnapshot empty;
  empty.cols = 0;
  empty.rows = 0;
  empty.cell_width = 0;
  empty.cell_height = 0;
  Check(bree::EncodeTerminalHostSnapshot(empty, &payload) == Error::kNone,
        "empty snapshot encodes");
  Check(bree::DecodeTerminalHostSnapshot(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded.cols == 1 && decoded.rows == 1 && !decoded.pid &&
            decoded.cell_width == 1 && decoded.cell_height == 1 &&
            !decoded.cwd && decoded.command.empty(),
        "snapshot decode matches Rust geometry clamps and zero-pid sentinel");

  std::vector<uint8_t> malformed = payload;
  malformed.push_back(0);
  Check(bree::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects trailing bytes");
  malformed = payload;
  // cols(2), rows(2), pid(4), replay length(4), empty replay, cwd tag.
  malformed[12] = 2;
  Check(bree::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects unknown optional-string tags");
  malformed = payload;
  malformed.resize(12);
  malformed[8] = 1;
  Check(bree::DecodeTerminalHostSnapshot(Bytes(malformed), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects truncated replay");

  std::vector<uint8_t> oversized_blob(12);
  oversized_blob[0] = 80;
  oversized_blob[2] = 24;
  const uint32_t oversized_replay =
      static_cast<uint32_t>(bree::kTerminalHostMaxSnapshotReplay + 1);
  for (size_t index = 0; index < sizeof(oversized_replay); ++index) {
    oversized_blob[8 + index] =
        static_cast<uint8_t>(oversized_replay >> (index * 8));
  }
  Check(bree::DecodeTerminalHostSnapshot(Bytes(oversized_blob), &decoded) ==
            Error::kMalformedPayload,
        "snapshot rejects replay length above the exact Rust bound before "
        "allocation");

  bree::TerminalHostSnapshot invalid_utf8;
  invalid_utf8.command = {std::string("\xc0\x80", 2)};
  std::vector<uint8_t> untouched = {1, 2, 3};
  Check(bree::EncodeTerminalHostSnapshot(invalid_utf8, &untouched) ==
            Error::kMalformedPayload,
        "snapshot encoder rejects strings Rust cannot represent");
  Check(untouched == std::vector<uint8_t>({1, 2, 3}),
        "failed snapshot encode leaves destination untouched");

  bree::TerminalHostSnapshot too_many_args;
  too_many_args.command.resize(bree::kTerminalHostMaxCommandArguments + 1);
  Check(bree::EncodeTerminalHostSnapshot(too_many_args, &untouched) ==
            Error::kPayloadTooLarge,
        "snapshot encoder bounds argv count");
}

void TestProtocolV1SnapshotAndResizeCompatibility() {
  using Error = bree::TerminalHostProtocolError;
  bree::TerminalHostSnapshot snapshot;
  snapshot.cols = 91;
  snapshot.rows = 27;
  snapshot.replay = {'v', '1'};
  snapshot.command = {"/bin/sh"};
  std::vector<uint8_t> snapshot_payload;
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &snapshot_payload) ==
            Error::kNone &&
            snapshot_payload.size() >= 2,
        "v3 snapshot fixture encodes");
  bree::TerminalHostSnapshot decoded_snapshot;
  std::vector<uint8_t> snapshot_v2 = snapshot_payload;
  snapshot_v2.resize(snapshot_v2.size() -
                     kRustTerminalHostKittyReplayStateLength);
  Check(bree::DecodeTerminalHostSnapshotForVersion(
            Bytes(snapshot_v2), bree::kTerminalHostProtocolVersionV2,
            &decoded_snapshot) == Error::kNone &&
            decoded_snapshot == snapshot,
        "protocol-v2 snapshot decodes aliases and cell pixels without Kitty "
        "state");
  snapshot_payload.resize(
      snapshot_payload.size() - kRustTerminalHostKittyReplayStateLength - 2 -
      4);

  Check(bree::DecodeTerminalHostSnapshotForVersion(
            Bytes(snapshot_payload), bree::kTerminalHostProtocolVersionV1,
            &decoded_snapshot) == Error::kNone &&
            decoded_snapshot == snapshot,
        "protocol-v1 snapshot decodes without Kitty aliases or cell pixels");
  Check(bree::DecodeTerminalHostSnapshotForVersion(
            Bytes(snapshot_payload), bree::kTerminalHostProtocolVersion,
            &decoded_snapshot) == Error::kMalformedPayload,
        "protocol-v3 snapshot requires Kitty aliases, cell pixels, and state");

  bree::TerminalHostResize resize;
  resize.cols = 101;
  resize.rows = 33;
  resize.replay = {'o', 'l', 'd'};
  std::vector<uint8_t> resize_payload;
  Check(bree::EncodeTerminalHostResize(resize, &resize_payload) ==
            Error::kNone &&
            resize_payload.size() >= 2,
        "v3 resize fixture encodes");
  bree::TerminalHostResize decoded_resize;
  std::vector<uint8_t> resize_v2 = resize_payload;
  resize_v2.resize(resize_v2.size() -
                   kRustTerminalHostKittyReplayStateLength);
  Check(bree::DecodeTerminalHostResizeForVersion(
            Bytes(resize_v2), bree::kTerminalHostProtocolVersionV2,
            &decoded_resize) == Error::kNone &&
            decoded_resize == resize,
        "protocol-v2 resize decodes aliases and cell pixels without Kitty "
        "state");
  resize_payload.resize(
      resize_payload.size() - kRustTerminalHostKittyReplayStateLength - 2 -
      4);

  Check(bree::DecodeTerminalHostResizeForVersion(
            Bytes(resize_payload), bree::kTerminalHostProtocolVersionV1,
            &decoded_resize) == Error::kNone &&
            decoded_resize == resize,
        "protocol-v1 resize decodes without a Kitty alias suffix");
  Check(bree::DecodeTerminalHostResizeForVersion(
            Bytes(resize_payload), bree::kTerminalHostProtocolVersion,
            &decoded_resize) == Error::kMalformedPayload,
        "protocol-v3 resize requires aliases, cell pixels, and Kitty state");
}

void TestProtocolV2KittyAliasesAndBounds() {
  using Error = bree::TerminalHostProtocolError;
  Check(bree::kTerminalHostMaxSnapshotReplay ==
            kRustTerminalHostMaxReplay,
        "snapshot and resized replay limit matches Rust exactly");
  Check(bree::kTerminalHostMaxFramePayload == 16 * 1024 * 1024,
        "terminal-host frame payload limit remains exactly 16 MiB");

  Check(KittyAliasesRoundTrip<bree::TerminalHostSnapshot>(
            bree::EncodeTerminalHostSnapshot,
            bree::DecodeTerminalHostSnapshot),
        "snapshot Kitty aliases round trip after existing metadata");
  Check(KittyAliasesRoundTrip<bree::TerminalHostResize>(
            bree::EncodeTerminalHostResize, bree::DecodeTerminalHostResize),
        "resized Kitty aliases round trip after replay");
  Check(HasCellPixels<bree::TerminalHostResize>::value,
        "resized payload exposes the v2 cell-pixel suffix");
  const std::vector<uint8_t> rust_v2_resize = {
      101, 0, 33, 0, 3, 0, 0, 0, 'r', 's', 'z',
      0,   0, 13, 0, 29, 0,
  };
  bree::TerminalHostResize decoded_rust_v2_resize;
  Check(bree::DecodeTerminalHostResizeForVersion(
            Bytes(rust_v2_resize), bree::kTerminalHostProtocolVersionV2,
            &decoded_rust_v2_resize) == Error::kNone &&
            decoded_rust_v2_resize.cols == 101 &&
            decoded_rust_v2_resize.rows == 33 &&
            decoded_rust_v2_resize.replay ==
                std::vector<uint8_t>({'r', 's', 'z'}) &&
            CellPixelsAre(decoded_rust_v2_resize, 13, 29),
        "C++ decodes the exact Rust v2 resized payload including cell pixels");

  for (InvalidKittyAlias invalid :
       {InvalidKittyAlias::kZeroId, InvalidKittyAlias::kZeroNumber,
        InvalidKittyAlias::kDuplicateId}) {
    Check(KittyAliasEncoderRejects<bree::TerminalHostSnapshot>(
              bree::EncodeTerminalHostSnapshot, invalid),
          "snapshot encoder rejects invalid Kitty alias identity");
    Check(KittyAliasDecoderRejects<bree::TerminalHostSnapshot>(
              bree::EncodeTerminalHostSnapshot,
              bree::DecodeTerminalHostSnapshot, invalid),
          "snapshot decoder rejects invalid Kitty alias identity");
    Check(KittyAliasEncoderRejects<bree::TerminalHostResize>(
              bree::EncodeTerminalHostResize, invalid),
          "resized encoder rejects invalid Kitty alias identity");
    Check(KittyAliasDecoderRejects<bree::TerminalHostResize>(
              bree::EncodeTerminalHostResize,
              bree::DecodeTerminalHostResize, invalid),
          "resized decoder rejects invalid Kitty alias identity");
  }
  Check(KittyAliasDecoderRejectsBadFraming<bree::TerminalHostSnapshot>(
            bree::EncodeTerminalHostSnapshot,
            bree::DecodeTerminalHostSnapshot),
        "snapshot rejects truncated and trailing alias bytes");
  Check(KittyAliasDecoderRejectsBadFraming<bree::TerminalHostResize>(
            bree::EncodeTerminalHostResize, bree::DecodeTerminalHostResize),
        "resized rejects truncated and trailing alias bytes");
  Check(KittyAliasCountIsBounded<bree::TerminalHostSnapshot>(
            bree::EncodeTerminalHostSnapshot),
        "snapshot admits 4096 aliases and rejects 4097");
  Check(KittyAliasCountIsBounded<bree::TerminalHostResize>(
            bree::EncodeTerminalHostResize),
        "resized admits 4096 aliases and rejects 4097");

  bree::TerminalHostResize resize;
  resize.replay.resize(kRustTerminalHostMaxReplay);
  std::vector<uint8_t> payload;
  Check(bree::EncodeTerminalHostResize(resize, &payload) == Error::kNone &&
            payload.size() == 8 + kRustTerminalHostMaxReplay + 2 + 4 +
                                  kRustTerminalHostKittyReplayStateLength,
        "resized admits the exact Rust replay ceiling plus v3 suffix");
  resize.replay.push_back(0);
  payload = {0xa5};
  Check(bree::EncodeTerminalHostResize(resize, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "resized rejects one byte beyond the exact Rust replay ceiling");

  resize.replay.pop_back();
  bree::TerminalHostSnapshot snapshot;
  snapshot.replay = std::move(resize.replay);
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) == Error::kNone,
        "snapshot admits the exact Rust replay ceiling");
  snapshot.replay.push_back(0);
  payload = {0xa5};
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "snapshot rejects one byte beyond the exact Rust replay ceiling");

  bree::TerminalHostSnapshot oversized_frame;
  oversized_frame.replay.resize(8 * 1024 * 1024);
  oversized_frame.command.assign(
      32, std::string(bree::kTerminalHostMaxString, 'x'));
  payload = {0xa5};
  Check(bree::EncodeTerminalHostSnapshot(oversized_frame, &payload) ==
                Error::kPayloadTooLarge &&
            payload == std::vector<uint8_t>({0xa5}),
        "snapshot total payload cannot exceed the exact frame cap");
}

void TestProtocolV3KittyReplayState() {
  using Error = bree::TerminalHostProtocolError;
  bree::TerminalHostSnapshot snapshot;
  snapshot.replay = {'x'};
  snapshot.kitty_state.limits = {10'000'000, 13'595'480, 4'096, 16'384};
  snapshot.kitty_state.replay_cursor_offset = 1;
  snapshot.kitty_state.replay_next_image_ids = {41, 43};
  snapshot.kitty_state.next_image_ids = {42, 44};
  std::vector<uint8_t> payload;
  bree::TerminalHostSnapshot decoded;
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) == Error::kNone &&
            bree::DecodeTerminalHostSnapshot(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == snapshot,
        "protocol-v3 snapshot preserves bounded per-screen Kitty cursors");

  snapshot.kitty_state.limits.image_bytes += 1;
  payload = {0xa5};
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) ==
                Error::kMalformedPayload &&
            payload == std::vector<uint8_t>({0xa5}),
        "Kitty replay state rejects a resource limit above Rust's bound");
  snapshot.kitty_state.limits.image_bytes = 10'000'000;
  snapshot.kitty_state.replay_next_image_ids.alternate = 0;
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) ==
            Error::kMalformedPayload,
        "Kitty replay state rejects a zero automatic image-ID cursor");
  snapshot.kitty_state.replay_next_image_ids.alternate = 43;
  snapshot.kitty_state.replay_cursor_offset = 2;
  Check(bree::EncodeTerminalHostSnapshot(snapshot, &payload) ==
            Error::kMalformedPayload,
        "Kitty replay state rejects a cursor offset beyond replay bytes");
}

void TestCapabilityPayloads() {
  using Error = bree::TerminalHostProtocolError;
  using Rights = bree::TerminalHostCapabilityRights;

  bree::TerminalHostMintCapability request;
  request.rights = Rights::kRenderer;
  request.ttl_ms = bree::kTerminalHostMaxRendererCapabilityTtlMs;
  std::vector<uint8_t> payload;
  Check(
      bree::EncodeTerminalHostMintCapability(request, &payload) == Error::kNone,
      "mint-capability request encodes");
  Check(payload == std::vector<uint8_t>({7, 0, 0, 0, 0x60, 0xea, 0x00, 0x00}),
        "mint-capability request is exact rights:u32 + ttl-ms:u32 LE");
  bree::TerminalHostMintCapability decoded;
  Check(bree::DecodeTerminalHostMintCapability(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == request,
        "mint-capability request round trips");

  request.ttl_ms = 0;
  Check(bree::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects zero TTL");
  request.ttl_ms = bree::kTerminalHostMaxRendererCapabilityTtlMs + 1;
  Check(bree::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects TTL above Rust's 60-second bound");
  request.ttl_ms = 1;
  request.rights = Rights::kInput;
  Check(bree::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability requires read access");
  request.rights = Rights::kRead | Rights::kTerminate;
  Check(bree::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects non-renderer rights");
  request.rights = static_cast<Rights>(1u << 31);
  Check(bree::EncodeTerminalHostMintCapability(request, &payload) ==
            Error::kMalformedPayload,
        "mint-capability rejects unknown rights");
  Check(bree::DecodeTerminalHostMintCapability("short", &decoded) ==
            Error::kMalformedPayload,
        "mint-capability request has exact eight-byte width");

  const bree::TerminalHostCapabilityToken token = Filled<32>(0xa5);
  Check(bree::EncodeTerminalHostCapability(token, &payload) == Error::kNone,
        "capability response encodes");
  Check(payload.size() == 32 &&
            std::all_of(payload.begin(), payload.end(),
                        [](uint8_t byte) { return byte == 0xa5; }),
        "capability response is exactly the raw 32-byte one-use token");
  bree::TerminalHostCapabilityToken decoded_token{};
  Check(bree::DecodeTerminalHostCapability(Bytes(payload), &decoded_token) ==
                Error::kNone &&
            decoded_token == token,
        "capability response round trips");
  payload.pop_back();
  Check(bree::DecodeTerminalHostCapability(Bytes(payload), &decoded_token) ==
            Error::kMalformedPayload,
        "capability response rejects any non-32-byte payload");
}

void TestResizeAndViewerSizePayloads() {
  using Error = bree::TerminalHostProtocolError;
  bree::TerminalHostResize resize;
  resize.cols = 0x0123;
  resize.rows = 0x4567;
  resize.replay = {0xaa, 0xbb, 0xcc};
  resize.kitty_state.limits = {1, 2, 3, 4};
  resize.kitty_state.replay_next_image_ids = {5, 7};
  resize.kitty_state.next_image_ids = {6, 8};
  std::vector<uint8_t> payload;
  Check(bree::EncodeTerminalHostResize(resize, &payload) == Error::kNone,
        "resized payload encodes");
  Check(payload == std::vector<uint8_t>({
                       0x23, 0x01, 0x67, 0x45, 3, 0, 0, 0, 0xaa, 0xbb,
                       0xcc, 0, 0, 8, 0, 16, 0, 1, 0, 0, 0, 0, 0, 0,
                       0, 2, 0, 0, 0, 0, 0, 0, 0, 3, 0, 0, 0, 0, 0,
                       0, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                       5, 0, 0, 0, 6, 0, 0, 0, 7, 0, 0, 0, 8, 0,
                       0, 0,
                   }),
        "resized payload matches Rust v3 replay and Kitty-state layout");
  bree::TerminalHostResize decoded;
  Check(bree::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
                Error::kNone &&
            decoded == resize,
        "resized payload round trips");
  payload.push_back(0);
  Check(bree::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
            Error::kMalformedPayload,
        "resized payload rejects trailing bytes");
  payload.resize(8);
  payload[4] = 4;
  Check(bree::DecodeTerminalHostResize(Bytes(payload), &decoded) ==
            Error::kMalformedPayload,
        "resized payload rejects truncated replay");

  Check(bree::EncodeTerminalHostViewerSize(0, 0, &payload) == Error::kNone &&
            payload == std::vector<uint8_t>({1, 0, 1, 0}),
        "viewer-size encoder matches Rust minimum clamp");
  uint16_t cols = 0;
  uint16_t rows = 0;
  Check(bree::DecodeTerminalHostViewerSize(Bytes(payload), &cols, &rows) ==
                Error::kNone &&
            cols == 1 && rows == 1,
        "viewer-size payload decodes");
  payload.push_back(0);
  Check(bree::DecodeTerminalHostViewerSize(Bytes(payload), &cols, &rows) ==
            Error::kMalformedPayload,
        "viewer-size payload has exact four-byte width");

  bree::TerminalHostResizeAck ack;
  ack.cols = 80;
  ack.rows = 24;
  ack.result_flags = bree::kTerminalHostResizeAckCanonicalChanged;
  Check(bree::EncodeTerminalHostResizeAck(ack, &payload) == Error::kNone &&
            payload == std::vector<uint8_t>({80, 0, 24, 0, 1, 0, 0, 0}),
        "resize acknowledgement has exact canonical-grid/result layout");
  bree::TerminalHostResizeAck decoded_ack;
  Check(bree::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
                Error::kNone &&
            decoded_ack == ack,
        "resize acknowledgement round trips");
  payload.push_back(0);
  Check(bree::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
            Error::kMalformedPayload,
        "resize acknowledgement rejects trailing bytes");
  payload.resize(8);
  payload[4] = 2;
  Check(bree::DecodeTerminalHostResizeAck(Bytes(payload), &decoded_ack) ==
            Error::kMalformedPayload,
        "resize acknowledgement rejects unknown result flags");
  ack.result_flags = 2;
  Check(bree::EncodeTerminalHostResizeAck(ack, &payload) ==
            Error::kMalformedPayload,
        "resize acknowledgement encoder rejects unknown result flags");
}

void TestColorMetadataSetThenReset() {
  bree::TerminalHostColors colors;
  colors.foreground = bree::TerminalHostRgb{1, 2, 3};
  colors.cursor = bree::TerminalHostRgb{0xaa, 0xbb, 0xcc};
  colors.cursor_visual = bree::TerminalHostCursorVisual{
      bree::TerminalHostCursorStyle::kUnderline, false};
  colors.palette.push_back(
      bree::TerminalHostPaletteEntry{4, {0x10, 0x20, 0x30}});
  std::vector<uint8_t> metadata = {'x'};
  bree::AppendTerminalHostColorMetadata(colors, &metadata);
  Check(Bytes(metadata) ==
            "x\x1b]104\a\x1b]4;4;rgb:10/20/30\a"
            "\x1b]10;rgb:01/02/03\a\x1b]111\a"
            "\x1b]12;rgb:aa/bb/cc\a\x1b[0 q\x1b[4 q",
        "full color metadata resets palette, sets sparse entries, and resets "
        "an absent background before applying the authoritative cursor");

  metadata.clear();
  bree::AppendTerminalHostColorMetadata(bree::TerminalHostColors(), &metadata);
  Check(Bytes(metadata) ==
            "\x1b]104\a\x1b]110\a\x1b]111\a\x1b]112\a",
        "legacy sparse state resets every prior color without inventing a "
        "cursor reset");

  struct CursorCase {
    bree::TerminalHostCursorStyle style;
    bool blinking;
    char decscusr;
  };
  constexpr std::array<CursorCase, 6> kCursorCases = {{
      {bree::TerminalHostCursorStyle::kBlock, true, '1'},
      {bree::TerminalHostCursorStyle::kBlock, false, '2'},
      {bree::TerminalHostCursorStyle::kUnderline, true, '3'},
      {bree::TerminalHostCursorStyle::kUnderline, false, '4'},
      {bree::TerminalHostCursorStyle::kBar, true, '5'},
      {bree::TerminalHostCursorStyle::kBar, false, '6'},
  }};
  for (const CursorCase& cursor_case : kCursorCases) {
    bree::TerminalHostColors cursor_colors;
    cursor_colors.cursor_visual = bree::TerminalHostCursorVisual{
        cursor_case.style, cursor_case.blinking};
    metadata.clear();
    bree::AppendTerminalHostColorMetadata(cursor_colors, &metadata);
    std::string expected =
        "\x1b]104\a\x1b]110\a\x1b]111\a\x1b]112\a\x1b[0 q\x1b[";
    expected.push_back(cursor_case.decscusr);
    expected.append(" q");
    Check(Bytes(metadata) == expected,
          "cursor metadata maps shape and blink to exact DECSCUSR");
  }

  bree::AppendTerminalHostColorMetadata(colors, nullptr);
  Check(true, "null color metadata destination is ignored safely");
}

void TestAuthoritativeCursorMetadataFollowsReplay() {
  bree::TerminalHostColors mode12_colors;
  mode12_colors.cursor_visual = bree::TerminalHostCursorVisual{
      bree::TerminalHostCursorStyle::kBar, false};
  std::vector<uint8_t> replacement = {'\x1b', 'c'};
  constexpr std::string_view kBlinkingReplay = "\x1b[?12h";
  replacement.insert(replacement.end(), kBlinkingReplay.begin(),
                     kBlinkingReplay.end());
  bree::AppendTerminalHostColorMetadata(mode12_colors, &replacement);
  Check(Bytes(replacement) ==
            "\x1b\x63\x1b[?12h\x1b]104\a\x1b]110\a\x1b]111\a"
            "\x1b]112\a\x1b[0 q\x1b[6 q",
        "resolved mode-12 state wins after authoritative replay reset");

  bree::TerminalHostColors primary_colors;
  primary_colors.cursor_visual = bree::TerminalHostCursorVisual{
      bree::TerminalHostCursorStyle::kBlock, true};
  replacement = {'\x1b', 'c'};
  constexpr std::string_view kAlternateReplay =
      "\x1b[?1049h\x1b[4 q\x1b[?12l\x1b[?1049l";
  replacement.insert(replacement.end(), kAlternateReplay.begin(),
                     kAlternateReplay.end());
  bree::AppendTerminalHostColorMetadata(primary_colors, &replacement);
  constexpr std::string_view kResolvedPrimary = "\x1b[0 q\x1b[1 q";
  const std::string_view replacement_bytes = Bytes(replacement);
  Check(
      replacement_bytes.size() >= kResolvedPrimary.size() &&
          replacement_bytes.substr(replacement_bytes.size() -
                                   kResolvedPrimary.size()) == kResolvedPrimary,
      "resolved primary-screen cursor pair wins after alternate replay");
}

void TestLegacyCursorAbsencePreservesOutputAndReplay() {
  // Decode the exact v1 shape a rolling upgrade receives. Cursor metadata did
  // not exist in v1, so its absence is unknown rather than a reset request.
  constexpr std::array<uint8_t, 11> kLegacyColorsPayload = {
      1, 0,  // Colors schema v1.
      1, 0,  // Foreground only; no cursor-visual flag.
      0, 0,  // No palette entries.
      0, 0,  // Reserved.
      1, 2, 3,
  };
  bree::TerminalHostColors legacy_colors;
  Check(bree::DecodeTerminalHostColors(
            std::string_view(
                reinterpret_cast<const char*>(kLegacyColorsPayload.data()),
                kLegacyColorsPayload.size()),
            &legacy_colors) == bree::TerminalHostProtocolError::kNone &&
            !legacy_colors.cursor_visual,
        "legacy Colors fixture decodes without cursor authority");

  std::vector<uint8_t> live;
  constexpr std::string_view kLiveOutput =
      "\x1b[5 q\x1b[?12l\x1b]10;rgb:01/02/03\a";
  live.insert(live.end(), kLiveOutput.begin(), kLiveOutput.end());
  bree::AppendTerminalHostColorMetadata(legacy_colors, &live);
  Check(Bytes(live) ==
            "\x1b[5 q\x1b[?12l\x1b]10;rgb:01/02/03\a"
            "\x1b]104\a\x1b]10;rgb:01/02/03\a\x1b]111\a\x1b]112\a",
        "live v1 color metadata preserves preceding DECSCUSR and mode 12");

  std::vector<uint8_t> replay = {'\x1b', 'c'};
  constexpr std::string_view kReplayCursor = "\x1b[3 q\x1b[?12l";
  replay.insert(replay.end(), kReplayCursor.begin(), kReplayCursor.end());
  bree::AppendTerminalHostColorMetadata(legacy_colors, &replay);
  Check(Bytes(replay) ==
            "\x1b\x63\x1b[3 q\x1b[?12l"
            "\x1b]104\a\x1b]10;rgb:01/02/03\a\x1b]111\a\x1b]112\a",
        "v1 replay keeps its post-RIS cursor state when metadata is absent");
}

}  // namespace

int main() {
  TestFrameGoldenAndKinds();
  TestRendererGrantValidation();
  TestFragmentationAndCoalescing();
  TestMalformedFrames();
  TestHelloPayloads();
  TestCapabilityPayloads();
  TestSnapshotPayload();
  TestProtocolV1SnapshotAndResizeCompatibility();
  TestProtocolV2KittyAliasesAndBounds();
  TestProtocolV3KittyReplayState();
  TestResizeAndViewerSizePayloads();
  TestColorMetadataSetThenReset();
  TestAuthoritativeCursorMetadataFollowsReplay();
  TestLegacyCursorAbsencePreservesOutputAndReplay();
  std::printf("bree-terminal-host-protocol: %d checks, %d failures\n", checks,
              failures);
  return failures == 0 ? 0 : 1;
}
