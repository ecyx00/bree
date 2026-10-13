#!/usr/bin/env python3
"""Run a pane's Claude command before and after simulated TMPDIR reaping."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
SURFACE_ID = "99999999-9999-4999-8999-999999999999"


def test_claude_shim_root_survives_tmpdir_reaping() -> None:
    integrations = {
        "bash": ("bree-bash-integration.bash", ["--norc", "--noprofile", "-c"]),
        "zsh": ("bree-zsh-integration.zsh", ["-f", "-c"]),
        "fish": ("fish/config.fish", ["--no-config", "-c"]),
    }
    for shell, (filename, arguments) in integrations.items():
        executable = shutil.which(shell)
        if executable is None:
            if shell != "fish" or os.environ.get("BREE_TEST_REQUIRE_FISH") == "1":
                raise AssertionError(f"required shell unavailable: {shell}")
            print("SKIP: fish unavailable; post-fish CI runs this case")
            continue
        for inherited in (False, True):
            with tempfile.TemporaryDirectory(prefix=f"bree-7028-{shell}-") as td:
                root = Path(td)
                home = root / 'home with spaces $cash "quoted"'
                tmpdir = root / "tmp"
                bundle_bin = root / "bin"
                user_bin = root / "user-bin"
                for directory in (home, tmpdir, bundle_bin, user_bin):
                    directory.mkdir()
                wrapper = bundle_bin / "bree-claude-wrapper"
                wrapper.write_text(
                    '#!/bin/sh\nprintf "wrapped:%s\\n" "$*"\n', encoding="utf-8"
                )
                wrapper.chmod(0o700)
                real_claude = user_bin / "claude"
                real_claude.write_text('#!/bin/sh\necho UNWRAPPED\n', encoding="utf-8")
                real_claude.chmod(0o700)
                expected_root = home / ".bree/bree-cli-shims" / SURFACE_ID
                legacy_root = tmpdir / "bree-cli-shims" / SURFACE_ID
                legacy_root.mkdir(parents=True)
                env = {
                    key: value for key, value in os.environ.items()
                    if not key.startswith("BREE")
                }
                env.update({
                    "HOME": str(home), "TMPDIR": str(tmpdir) + "/",
                    "PATH": f"{legacy_root}:{user_bin}:/usr/bin:/bin",
                    "BREE_TEST_INTEGRATION": str(REPO_ROOT / "Resources/shell-integration" / filename),
                    "BREE_TEST_WRAPPER": str(wrapper),
                    "BREE_SURFACE_ID": SURFACE_ID,
                    "BREE_SOCKET_PATH": "", "BREE_SHELL_INTEGRATION_DIR": "",
                    "BREE_LOAD_GHOSTTY_BASH_INTEGRATION": "0",
                    "BREE_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
                    "GHOSTTY_RESOURCES_DIR": "",
                })
                if inherited:
                    env["BREE_CLAUDE_WRAPPER_SHIM_ROOT"] = str(legacy_root) + "/"
                # Same shell and PATH before and after removal, with no prompt,
                # re-source or shim installation between the two invocations.
                driver = '\n'.join([
                    'source "$BREE_TEST_INTEGRATION"',
                    '_bree_install_cli_command_shim claude "$BREE_TEST_WRAPPER"',
                    'command claude before "two words"',
                    '/bin/rm -rf -- "$TMPDIR/bree-cli-shims"',
                    'command claude after "two words"',
                    'printf "%s\\n" "$BREE_CLAUDE_WRAPPER_SHIM_ROOT"',
                ])
                result = subprocess.run(
                    [executable, *arguments, driver], env=env,
                    capture_output=True, text=True, timeout=30, check=False,
                )
                debug = f"{shell}, inherited={inherited}: {result}"
                assert result.returncode == 0, debug
                assert result.stdout.splitlines() == [
                    "wrapped:before two words", "wrapped:after two words", str(expected_root)
                ], debug
                assert os.access(expected_root / "claude", os.X_OK), debug
                assert not legacy_root.exists(), debug
                print(f"PASS: {shell}, inherited={inherited}, survives TMPDIR reap")


if __name__ == "__main__":
    test_claude_shim_root_survives_tmpdir_reaping()
