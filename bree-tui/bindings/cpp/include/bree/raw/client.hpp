#pragma once

// Low-level protocol-v12 compatibility layer. Prefer <bree/client.hpp>.
#include "bree/raw/attachment.hpp"
#include "bree/raw/generated/commands.hpp"

namespace bree::raw {

using ::bree::Error;
using ::bree::ErrorCode;
using ::bree::Json;
using ::bree::JsonLimits;
using ::bree::Timeout;
using ::bree::Transport;
using ::bree::TransportFactory;
using ::bree::TransportLimits;
using ::bree::UnixTransport;
using ::bree::default_socket_path;
using ::bree::make_error;
using ::bree::socket_path_from_environment;
using ::bree::unix_transport_factory;

template <typename T>
using result = ::bree::Result<T>;
template <typename T>
using Result = ::bree::Result<T>;

}  // namespace bree::raw
