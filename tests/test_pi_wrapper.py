#!/usr/bin/env python3
"""Behavioral checks for the per-surface Pi wrapper."""

from __future__ import annotations

import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "Resources/bin/bree-pi-wrapper"
MARKER = "bree-pi-session-extension-marker v4"


def executable(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


def run_case(
    root: Path,
    *,
    disabled: bool = False,
    managed_global: bool = False,
    stale_cached_extension: bool = False,
) -> dict[str, object]:
    bin_dir = root / "bin"
    bin_dir.mkdir(exist_ok=True)
    log = root / "pi-argv.json"
    fake_pi = bin_dir / "pi"
    executable(
        fake_pi,
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$@\" > {log!s}\n"
        "exit 0\n",
    )
    fake_bree = root / "bree"
    executable(
        fake_bree,
        "#!/bin/sh\n"
        "if [ \"$1 $2 $3\" = 'hooks pi extension-source' ]; then\n"
        f"  printf '%s\\n' '// {MARKER}'\n"
        "  exit 0\n"
        "fi\n"
        "exit 1\n",
    )
    agent_dir = root / "pi-agent"
    if managed_global:
        extension = agent_dir / "extensions/bree-session.ts"
        extension.parent.mkdir(parents=True)
        extension.write_text(f"// {MARKER}\n", encoding="utf-8")
    if stale_cached_extension:
        cached = root / "tmp/bree-pi-extensions/surface-test/bree-session.ts"
        cached.parent.mkdir(parents=True)
        cached.write_text("// bree-pi-session-extension-marker v3\n", encoding="utf-8")

    environment = {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "HOME": str(root / "home"),
        "TMPDIR": str(root / "tmp"),
        "PI_CODING_AGENT_DIR": str(agent_dir),
        "BREE_BUNDLED_CLI_PATH": str(fake_bree),
        "BREE_SURFACE_ID": "surface-test",
    }
    if disabled:
        environment["BREE_PI_HOOKS_DISABLED"] = "1"
    subprocess.run([str(WRAPPER), "--print", "hello"], env=environment, check=True)
    return {
        "args": log.read_text(encoding="utf-8").splitlines(),
        "extension_exists": (root / "tmp/bree-pi-extensions/surface-test/bree-session.ts").exists(),
        "global_exists": (agent_dir / "extensions/bree-session.ts").exists(),
    }


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="bree-pi-wrapper-") as directory:
        root = Path(directory)
        injected = run_case(root)
        if "-e" not in injected["args"] or not injected["extension_exists"]:
            raise AssertionError(f"missing bundled Pi extension injection: {injected}")

    with tempfile.TemporaryDirectory(prefix="bree-pi-wrapper-global-") as directory:
        root = Path(directory)
        managed = run_case(root, managed_global=True)
        if "-e" in managed["args"]:
            raise AssertionError(f"managed global Pi extension loaded twice: {managed}")

    with tempfile.TemporaryDirectory(prefix="bree-pi-wrapper-refresh-") as directory:
        root = Path(directory)
        refreshed = run_case(root, stale_cached_extension=True)
        cached = root / "tmp/bree-pi-extensions/surface-test/bree-session.ts"
        if "-e" not in refreshed["args"] or cached.read_text(encoding="utf-8").strip() != f"// {MARKER}":
            raise AssertionError(f"stale bundled Pi extension was not refreshed: {refreshed}")

    with tempfile.TemporaryDirectory(prefix="bree-pi-wrapper-disabled-") as directory:
        root = Path(directory)
        disabled = run_case(root, disabled=True)
        if "-e" in disabled["args"] or disabled["extension_exists"]:
            raise AssertionError(f"Pi hooks disabled still injected extension: {disabled}")

    with tempfile.TemporaryDirectory(prefix="bree-pi-wrapper-missing-") as directory:
        root = Path(directory)
        shim_dir = root / "shim-bin"
        shim_dir.mkdir()
        shim = shim_dir / "pi"
        shim.symlink_to(WRAPPER)
        result = subprocess.run(
            [str(shim), "--print", "hello"],
            env={
                "PATH": str(shim_dir),
                "HOME": str(root / "home"),
                "TMPDIR": str(root / "tmp"),
                "BREE_PI_HOOKS_DISABLED": "1",
            },
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode != 127 or "unavailable" not in result.stderr:
            raise AssertionError(
                f"missing Pi executable recursed or returned the wrong error: "
                f"status={result.returncode} stderr={result.stderr!r}"
            )

    print("PASS: Pi wrapper injects one bundled extension and honors global/disabled cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
