#!/usr/bin/env python3
"""
Regression test: `bree --version` should print version text without requiring a socket.
"""

from __future__ import annotations

import glob
import os
import re
import shutil
import subprocess


def resolve_bree_cli() -> str:
    explicit = os.environ.get("BREE_CLI_BIN") or os.environ.get("BREE_CLI")
    if explicit and os.path.exists(explicit) and os.access(explicit, os.X_OK):
        return explicit

    candidates: list[str] = []
    candidates.extend(glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/bree")))
    candidates.extend(glob.glob("/tmp/bree-*/Build/Products/Debug/bree"))
    candidates = [p for p in candidates if os.path.exists(p) and os.access(p, os.X_OK)]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("bree")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find bree CLI binary. Set BREE_CLI_BIN.")


def run(cli_path: str, *args: str, timeout: float = 5.0) -> tuple[int, str, str]:
    try:
        proc = subprocess.run(
            [cli_path, *args],
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout:.1f}s"
    return proc.returncode, proc.stdout.strip(), proc.stderr.strip()


def main() -> int:
    try:
        cli_path = resolve_bree_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    code, out, err = run(cli_path, "--version")
    if code != 0:
        print("FAIL: `bree --version` exited non-zero")
        print(f"exit={code}")
        print(f"stdout={out}")
        print(f"stderr={err}")
        return 1

    if not out:
        print("FAIL: `bree --version` produced empty stdout")
        return 1

    if not re.search(r"\b\d+\.\d+\.\d+\b", out):
        print(f"FAIL: version output missing semantic version: {out!r}")
        return 1

    code2, out2, err2 = run(cli_path, "version")
    if code2 != 0:
        print("FAIL: `bree version` exited non-zero")
        print(f"exit={code2}")
        print(f"stdout={out2}")
        print(f"stderr={err2}")
        return 1

    if out2 != out:
        print("FAIL: `bree --version` and `bree version` differ")
        print(f"--version: {out!r}")
        print(f"version:   {out2!r}")
        return 1

    print(f"PASS: bree version command works ({out})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
