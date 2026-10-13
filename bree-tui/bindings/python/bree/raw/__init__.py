"""Legacy generated protocol API.

This namespace is the only public location for numeric mux identities,
generated wire models, and the pre-resource client.
"""

from ._generated import *
from ._generated import __all__ as _generated_all
from ..errors import (
    AuthorityError,
    BreeConnectionError,
    BreeError,
    CommandError,
    ProtocolError,
    TimeoutError,
)
from .client import (
    AttachStream,
    BreeClient,
    EventStream,
    MISSING,
    MissingType,
    default_socket_path,
    env_socket_path,
)
from .convenience import (
    SurfaceContext,
    active_live_pty,
    find_surface,
    render_row_text,
)

Client = BreeClient

__all__ = list(
    dict.fromkeys(
        (
            "AttachStream",
            "AuthorityError",
            "Client",
            "BreeConnectionError",
            "BreeClient",
            "BreeError",
            "CommandError",
            "EventStream",
            "MISSING",
            "MissingType",
            "ProtocolError",
            "SurfaceContext",
            "TimeoutError",
            "active_live_pty",
            "default_socket_path",
            "env_socket_path",
            "find_surface",
            "render_row_text",
            *_generated_all,
        )
    )
)
