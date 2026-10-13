#include "test.hpp"

#include <cstdint>
#include <limits>
#include <string>

#include "bree/json.hpp"

TEST("JSON preserves the entire uint64 and int64 domains") {
    const std::string wire =
        R"({"max":18446744073709551615,"min":-9223372036854775808,"safe":9007199254740993})";
    auto parsed = bree::Json::parse(wire);
    CHECK(parsed);
    CHECK_EQ(
        parsed.value().find("max")->as_uint64().value(),
        std::numeric_limits<std::uint64_t>::max());
    CHECK_EQ(
        parsed.value().find("min")->as_int64().value(),
        std::numeric_limits<std::int64_t>::min());
    CHECK_EQ(parsed.value().find("safe")->as_uint64().value(), 9007199254740993ULL);
    auto encoded = parsed.value().encode();
    CHECK(encoded);
    auto round_trip = bree::Json::parse(encoded.value());
    CHECK(round_trip);
    CHECK_EQ(round_trip.value(), parsed.value());
}

TEST("JSON decodes Unicode surrogate pairs and rejects malformed input") {
    auto parsed = bree::Json::parse(R"("\ud83d\ude80")");
    CHECK(parsed);
    CHECK_EQ(parsed.value().as_string().value(), std::string_view("\xF0\x9F\x9A\x80"));
    CHECK(!bree::Json::parse(R"("\ud83d")"));
    CHECK(!bree::Json::parse(R"({"x":1,"x":2})"));
    CHECK(!bree::Json::parse("01"));
    CHECK(!bree::Json::parse("NaN"));
}

TEST("JSON parser enforces configured input, string, depth, and node bounds") {
    bree::JsonLimits limits;
    limits.max_input_bytes = 8;
    CHECK(!bree::Json::parse(R"({"long":1})", limits));

    limits = {};
    limits.max_string_bytes = 3;
    CHECK(!bree::Json::parse(R"("four")", limits));

    limits = {};
    limits.max_depth = 1;
    CHECK(!bree::Json::parse("[[0]]", limits));

    limits = {};
    limits.max_nodes = 2;
    CHECK(!bree::Json::parse("[1,2]", limits));
}

TEST("JSON encoder rejects non-finite numbers and invalid UTF-8") {
    bree::Json infinite(std::numeric_limits<double>::infinity());
    CHECK(!infinite.encode());
    bree::Json invalid(std::string("\xff", 1));
    CHECK(!invalid.encode());
}
