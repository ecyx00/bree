#!/usr/bin/env python3
"""Behavior coverage for preserving bree's app-installed command-shim root."""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SURFACE_ID = "99999999-9999-4999-8999-999999999999"


def make_executable(path: Path) -> None:
    path.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    path.chmod(0o755)


def run_integration(
    shell: str,
    argv: list[str],
    driver: str,
    integration: Path,
    environment: dict[str, str],
) -> subprocess.CompletedProcess[str]:
    executable = shutil.which(shell)
    if executable is None:
        raise RuntimeError(f"required shell is unavailable: {shell}")
    env = environment.copy()
    env["BREE_TEST_INTEGRATION"] = str(integration)
    return subprocess.run(
        [executable, *argv, driver],
        capture_output=True,
        text=True,
        check=False,
        env=env,
        timeout=30,
    )


def main() -> int:
    integrations = {
        "bash": (
            ["--noprofile", "--norc", "-c"],
            'source "$BREE_TEST_INTEGRATION"\n'
            '_bree_install_cli_command_shim claude "$BREE_TEST_WRAPPER"\n'
            'printf "%s\\n" "$BREE_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/bree-bash-integration.bash",
        ),
        "zsh": (
            ["-f", "-c"],
            'source "$BREE_TEST_INTEGRATION"\n'
            '_bree_install_cli_command_shim claude "$BREE_TEST_WRAPPER"\n'
            'printf "%s\\n" "$BREE_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/bree-zsh-integration.zsh",
        ),
    }
    fish = shutil.which("fish")
    if fish is not None:
        integrations["fish"] = (
            ["--no-config", "-c"],
            'source "$BREE_TEST_INTEGRATION"\n'
            '_bree_install_cli_command_shim claude "$BREE_TEST_WRAPPER"\n'
            'printf "%s\\n" "$BREE_CLAUDE_WRAPPER_SHIM_ROOT"',
            REPO_ROOT / "Resources/shell-integration/fish/config.fish",
        )

    with tempfile.TemporaryDirectory(prefix="bree-shim-root-") as td:
        root = Path(td)
        managed_root = root / "app installed" / "bree-cli-shims" / SURFACE_ID
        changed_tmpdir = root / "profile tmp"
        wrapper = root / "bree-claude-wrapper"
        managed_root.mkdir(parents=True)
        changed_tmpdir.mkdir()
        make_executable(wrapper)

        env = {
            key: value for key, value in os.environ.items() if not key.startswith("BREE_")
        }
        env.update(
            {
                "BREE_CLAUDE_WRAPPER_SHIM_ROOT": str(managed_root),
                "BREE_LOAD_GHOSTTY_ZSH_INTEGRATION": "0",
                "BREE_SHELL_INTEGRATION_DIR": "",
                "BREE_SOCKET_PATH": "",
                "BREE_SURFACE_ID": SURFACE_ID,
                "BREE_TEST_WRAPPER": str(wrapper),
                "GHOSTTY_RESOURCES_DIR": "",
                "TMPDIR": str(changed_tmpdir),
            }
        )

        for shell, (argv, driver, integration) in integrations.items():
            proc = run_integration(shell, argv, driver, integration, env)
            if proc.returncode != 0:
                print(f"FAIL: {shell} integration failed after TMPDIR changed")
                print(f"stdout={proc.stdout!r}")
                print(f"stderr={proc.stderr!r}")
                return 1
            if proc.stdout.strip().splitlines()[-1:] != [str(managed_root)]:
                print(f"FAIL: {shell} replaced the app-installed shim root")
                print(f"stdout={proc.stdout!r}")
                return 1
            if not (managed_root / "claude").is_file():
                print(f"FAIL: {shell} did not write into the app-installed shim root")
                return 1
            fallback = changed_tmpdir / "bree-cli-shims" / SURFACE_ID / "claude"
            if fallback.exists():
                print(f"FAIL: {shell} re-derived the shim root from changed TMPDIR")
                return 1
            (managed_root / "claude").unlink()

    print("PASS: shell integrations preserve the app-installed shim root after TMPDIR changes")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
