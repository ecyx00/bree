#!/usr/bin/env python3
"""Behavior coverage for the fake-socket CLI environment helpers."""

from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from fake_socket_env import INHERITED_SOCKET_KEYS, cli_environment, unwrap_capability


LAUNCHED_BY_BREE = {
    "BREE_SOCKET_PATH": "/Users/me/.local/state/bree/bree.sock",
    "BREE_SOCKET": "/Users/me/.local/state/bree/bree.sock",
    "BREE_SOCKET_CAPABILITY": "v1.token.signature",
    "BREE_SOCKET_PASSWORD": "hunter2",
    "BREE_SOCKET_PASSWORD_FILE": "/Users/me/.local/state/bree/password",
    "BREE_WORKSPACE_ID": "workspace:9",
    "BREE_SURFACE_ID": "surface:9",
    "BREE_TAB_ID": "tab:9",
    "BREE_PANEL_ID": "panel:9",
    "BREE_PANE_ID": "pane:9",
    "BREE_RELAY_ID": "relay",
    "BREE_RELAY_TOKEN": "11" * 32,
    "HOME": "/Users/me",
    "PATH": "/usr/bin:/bin",
}


class CliEnvironmentTests(unittest.TestCase):
    def test_a_bree_launched_shell_leaves_no_socket_state_behind(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            env = cli_environment()
        for key in INHERITED_SOCKET_KEYS:
            self.assertNotIn(key, env)
        self.assertEqual(env["HOME"], "/Users/me")
        self.assertEqual(env["PATH"], "/usr/bin:/bin")
        self.assertEqual(env["BREE_CLI_SENTRY_DISABLED"], "1")
        self.assertNotIn("BREE_PANEL_ID", env)
        self.assertNotIn("BREE_PANE_ID", env)

    def test_the_fake_socket_is_set_under_both_names_the_cli_reads(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            env = cli_environment("/tmp/fake.sock")
        self.assertEqual(env["BREE_SOCKET_PATH"], "/tmp/fake.sock")
        self.assertEqual(env["BREE_SOCKET"], "/tmp/fake.sock")
        self.assertNotIn("BREE_SOCKET_CAPABILITY", env)

    def test_overrides_win_over_the_scrub_so_a_test_can_pin_its_own_target(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            env = cli_environment("/tmp/fake.sock", BREE_WORKSPACE_ID="workspace:1", BREE_SURFACE_ID="surface:1")
        self.assertEqual(env["BREE_WORKSPACE_ID"], "workspace:1")
        self.assertEqual(env["BREE_SURFACE_ID"], "surface:1")
        self.assertNotIn("BREE_TAB_ID", env)

    def test_a_test_owned_home_moves_the_shell_and_foundation_homes_together(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            env = cli_environment("/tmp/fake.sock", home="/tmp/fake-home")
        self.assertEqual(env["HOME"], "/tmp/fake-home")
        self.assertEqual(env["CFFIXED_USER_HOME"], "/tmp/fake-home")

    def test_without_a_test_owned_home_foundation_still_gets_an_empty_one(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            env = cli_environment("/tmp/fake.sock")
        self.assertEqual(env["HOME"], "/Users/me")
        self.assertTrue(os.path.isdir(env["CFFIXED_USER_HOME"]))
        self.assertEqual(os.listdir(env["CFFIXED_USER_HOME"]), [])

    def test_a_foundation_home_the_test_runner_set_is_kept(self) -> None:
        with patch.dict(os.environ, {**LAUNCHED_BY_BREE, "CFFIXED_USER_HOME": "/tmp/lane.home"}, clear=True):
            env = cli_environment("/tmp/fake.sock")
        self.assertEqual(env["CFFIXED_USER_HOME"], "/tmp/lane.home")

    def test_the_caller_environment_is_not_mutated(self) -> None:
        with patch.dict(os.environ, LAUNCHED_BY_BREE, clear=True):
            cli_environment("/tmp/fake.sock")
            self.assertEqual(os.environ["BREE_SOCKET_CAPABILITY"], "v1.token.signature")


class UnwrapCapabilityTests(unittest.TestCase):
    def test_an_enveloped_request_yields_the_bare_request(self) -> None:
        request = '{"method":"workspace.list","params":{},"id":"1"}'
        self.assertEqual(unwrap_capability(f"_bree_capability_v1 v1.token.sig {request}"), request)

    def test_a_bare_line_passes_through(self) -> None:
        for line in ('{"method":"ping"}', "auth secret", "ping", ""):
            with self.subTest(line=line):
                self.assertEqual(unwrap_capability(line), line)

    def test_a_malformed_envelope_is_left_for_the_server_to_reject(self) -> None:
        for line in ("_bree_capability_v1 ", "_bree_capability_v1 token-only", "_bree_capability_v1  {}"):
            with self.subTest(line=line):
                self.assertEqual(unwrap_capability(line), line)


if __name__ == "__main__":
    unittest.main()
