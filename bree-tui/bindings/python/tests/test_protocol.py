from __future__ import annotations

import inspect
import os
import sys
import unittest
from unittest.mock import patch

from bree.client_defaults import (
    _legacy_raw_socket_fallback_path,
    legacy_raw_socket_path,
    validate_session_name,
)
from bree.raw import (
    BreeClient,
    MISSING,
    MUX_PROTOCOL,
    UnknownEvent,
    default_socket_path,
    env_socket_path,
)
from bree.raw._generated import models
from bree.raw._generated._schema import SCHEMA
from bree.raw._generated.client import GeneratedClientMixin
from bree.raw._generated.codec import decode_event, encode_request
from bree.raw._generated.metadata import COMMANDS, EVENTS, IR_SHA256


class GeneratedProtocolTests(unittest.TestCase):
    def test_protocol_inventory_is_exhaustive(self) -> None:
        self.assertEqual(MUX_PROTOCOL, 12)
        self.assertEqual(len(COMMANDS), 118)
        self.assertEqual(set(COMMANDS), set(SCHEMA["commands"]))
        self.assertEqual(set(EVENTS), set(SCHEMA["events"]))
        self.assertEqual(len(IR_SHA256), 64)

        generated = {
            value.__bree_command__.wire_name
            for _name, value in inspect.getmembers(
                GeneratedClientMixin, inspect.isfunction
            )
            if hasattr(value, "__bree_command__")
        }
        self.assertEqual(generated, set(COMMANDS))

    def test_every_command_has_a_generated_request_dataclass(self) -> None:
        request_paths = {
            value.__bree_schema_path__
            for _name, value in vars(models).items()
            if inspect.isclass(value)
            and getattr(value, "__bree_schema_path__", "").startswith("commands/")
            and getattr(value, "__bree_schema_path__", "").endswith("/request")
        }
        self.assertEqual(
            request_paths,
            {f"commands/{command}/request" for command in COMMANDS},
        )

    def test_missing_and_explicit_null_have_distinct_wire_shapes(self) -> None:
        request_type = models.SetClientInfoRequest

        self.assertEqual(encode_request("set-client-info", request_type()), {})
        self.assertEqual(
            encode_request("set-client-info", request_type(name=None)),
            {"name": None},
        )
        self.assertIs(request_type().name, MISSING)

    def test_uint64_event_ids_remain_exact_python_ints(self) -> None:
        request = 2**63 + 9_007_199_254_740_993
        event = decode_event({"event": "pairing-resolved", "request": request})

        self.assertEqual(event.request, request)
        self.assertIsInstance(event.request, int)

    def test_unknown_events_survive_with_raw_payload(self) -> None:
        event = decode_event({"event": "protocol-11-added", "value": 42})

        self.assertIsInstance(event, UnknownEvent)
        self.assertEqual(event.event, "protocol-11-added")
        self.assertEqual(event.raw["value"], 42)

    def test_authority_and_version_metadata_cover_each_method(self) -> None:
        authorities = {metadata.authority for metadata in COMMANDS.values()}
        self.assertEqual(
            authorities,
            {"control", "frontend", "local-admin", "provider-authority"},
        )
        self.assertTrue(
            all(5 <= metadata.since <= MUX_PROTOCOL for metadata in COMMANDS.values())
        )
        self.assertEqual(
            COMMANDS["rename-provider-managed-workspace"].authority,
            "provider-authority",
        )

    def test_request_field_compatibility_metadata_matches_schema(self) -> None:
        for command_name, command in SCHEMA["commands"].items():
            expected = {
                field_name: (
                    field_spec.get("since"),
                    field_spec.get("capability"),
                )
                for field_name, field_spec in command["request"]["fields"].items()
            }
            actual = {
                field_name: (metadata.since, metadata.capability)
                for field_name, metadata in COMMANDS[command_name].fields.items()
            }
            self.assertEqual(actual, expected, command_name)

        self.assertEqual(COMMANDS["send"].fields["paste"].since, 7)
        self.assertEqual(COMMANDS["run"].fields["key"].since, 9)
        self.assertEqual(
            COMMANDS["set-default-colors"].fields["cursor_style"].since,
            9,
        )
        self.assertEqual(
            COMMANDS["subscribe"].fields["surface"].capability,
            "surface-subscribe-filter",
        )
        self.assertEqual(
            COMMANDS["close-workspace"].fields["key"].capability,
            "workspace-registry-v1",
        )

    def test_socket_discovery_precedence_matches_transport_spec(self) -> None:
        with patch.dict(
            os.environ,
            {
                "BREE_TUI_SOCKET": "/explicit/tui.sock",
                "BREE_MUX_SOCKET": "/legacy/mux.sock",
                "XDG_RUNTIME_DIR": "/runtime",
                "TMPDIR": "/temporary",
            },
            clear=True,
        ):
            self.assertEqual(env_socket_path(), "/explicit/tui.sock")
            self.assertEqual(
                default_socket_path("sdk"),
                f"/runtime/bree-tui-{os.getuid()}/sdk.sock",
            )

        with patch.dict(os.environ, {"TMPDIR": "/temporary"}, clear=True):
            self.assertEqual(
                default_socket_path("sdk"),
                f"/temporary/bree-tui-{os.getuid()}/sdk.sock",
            )

    def test_long_session_hash_prefers_runtime_base_and_falls_back_to_tmp(self) -> None:
        session = "legacy-" + "x" * 200
        digest = "e538a84493067947f7376110a6f695dd3db062b67eee939c3660c07f3f47dce2"
        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "/run/user/501", "TMPDIR": ""},
            clear=True,
        ):
            self.assertEqual(
                default_socket_path(session),
                f"/run/user/501/bree-tui-hashed-{os.getuid()}/{digest}.sock",
            )

        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "/tmp/" + "x" * 200},
            clear=True,
        ):
            self.assertEqual(
                default_socket_path(session),
                f"/tmp/bree-tui-hashed-{os.getuid()}/{digest}.sock",
            )

    def test_non_ascii_long_session_hash_uses_utf8_bytes(self) -> None:
        session = "名前" * 100
        digest = "0d3fd777d54547652e50e049becfce29b81513bc248da9d22bbd37593f0d52e3"
        with patch.dict(os.environ, {"XDG_RUNTIME_DIR": "/run/user/501"}, clear=True):
            self.assertEqual(
                default_socket_path(session),
                f"/run/user/501/bree-tui-hashed-{os.getuid()}/{digest}.sock",
            )

    def test_invalid_session_default_path_is_isolated_but_validation_is_strict(self) -> None:
        session = "../other"
        digest = "3f1d50ca1c828a718349a63c91f2b2792bfb62e1be836ec67f8b454b8501f2a7"
        with patch.dict(os.environ, {"XDG_RUNTIME_DIR": "/r"}, clear=True):
            self.assertEqual(
                default_socket_path(session),
                f"/r/bree-tui-invalid-{os.getuid()}/{digest}.sock",
            )

        with self.assertRaises(ValueError):
            validate_session_name(session)

    def test_invalid_session_default_path_uses_short_tmp_fallback(self) -> None:
        session = ""
        digest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "/tmp/" + "x" * 200},
            clear=True,
        ):
            self.assertEqual(
                default_socket_path(session),
                f"/tmp/bree-tui-invalid-{os.getuid()}/{digest}.sock",
            )

    def test_overlong_legacy_path_is_not_configured_as_fallback(self) -> None:
        session = "legacy-" + "x" * 200

        self.assertGreaterEqual(
            len(os.fsencode(legacy_raw_socket_path(session))),
            104 if sys.platform == "darwin" else 108,
        )
        self.assertIsNone(_legacy_raw_socket_fallback_path(session))
        self.assertEqual(
            _legacy_raw_socket_fallback_path("sdk"),
            legacy_raw_socket_path("sdk"),
        )
        with patch("bree.raw.client.JsonLineConnection") as connection:
            BreeClient(session=session)

        self.assertIsNone(connection.call_args.kwargs["fallback_path"])

    def test_empty_socket_environment_values_are_ignored(self) -> None:
        with patch.dict(
            os.environ,
            {
                "BREE_TUI_SOCKET": "",
                "BREE_MUX_SOCKET": "",
                "XDG_RUNTIME_DIR": "/runtime",
            },
            clear=True,
        ):
            self.assertIsNone(env_socket_path())
            self.assertEqual(
                default_socket_path("sdk"),
                f"/runtime/bree-tui-{os.getuid()}/sdk.sock",
            )

    def test_hashed_marker_in_runtime_directory_does_not_enable_legacy_fallback(self) -> None:
        with patch.dict(
            os.environ,
            {"XDG_RUNTIME_DIR": "/tmp/bree-tui-hashed-marker"},
            clear=True,
        ), patch("bree.raw.client.JsonLineConnection") as connection:
            BreeClient(session="sdk")

        self.assertIsNone(connection.call_args.kwargs["fallback_path"])


if __name__ == "__main__":
    unittest.main()
