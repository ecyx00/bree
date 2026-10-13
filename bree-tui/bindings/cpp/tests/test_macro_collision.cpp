#ifndef unix
#define unix 0x434d5558
#endif

constexpr auto kUnixMacroBeforeBreeInclude = unix;

#include "bree/client.hpp"
#include "bree/raw/client.hpp"
#include "test.hpp"

#ifndef unix
#error "bree headers must preserve the caller's unix macro"
#endif

static_assert(unix == kUnixMacroBeforeBreeInclude);

TEST("public and generated enums survive caller macros and preserve wire values") {
    bree::ClientSnapshot snapshot;
    CHECK_EQ(snapshot.transport, bree::ClientTransport::unix_socket);

    auto wire = bree::raw::Json::parse(R"("unix")");
    CHECK(wire);

    auto decoded = bree::raw::decode_value<bree::raw::ClientTransport>(wire.value());
    CHECK(decoded);
    CHECK_EQ(decoded.value(), bree::raw::ClientTransport::unix_);

    auto encoded = bree::raw::encode_value(decoded.value());
    CHECK(encoded);
    CHECK_EQ(encoded.value().as_string().value(), std::string_view("unix"));
    CHECK_EQ(unix, kUnixMacroBeforeBreeInclude);
}
