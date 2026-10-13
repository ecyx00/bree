#!/usr/bin/env python3
"""Agent plugin installers write bree-* files and never touch pre-existing bree-* files.

Runs the bundled CLI (BREE_CLI_BIN) with a temp HOME; the real agent folders are never read.
Usage: BREE_CLI_BIN=<bin/bree> python3 tests/test_bree_plugin_names.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from claude_teams_test_utils import resolve_bree_cli

# agent -> (folder under HOME, old bree-owned names, expected bree names)
CASES = {
    "opencode": (".config/opencode/plugins", ["bree-session.js", "bree-feed.js"], ["bree-session.js", "bree-feed.js"]),
    "pi": (".pi/agent/extensions", ["bree-session.ts"], ["bree-session.ts"]),
    "omp": (".omp/agent/extensions", ["bree-omp-session.ts"], ["bree-omp-session.ts"]),
    "campfire": (".campfire/agent/extensions", ["bree-campfire-session.ts"], ["bree-campfire-session.ts"]),
    "amp": (".config/amp/plugins", ["bree-session.ts"], ["bree-session.ts"]),
}
# Looks like what the real bree.app would have written, including its old marker.
OLD_CONTENT = "// bree-session-extension-marker v1\n// owned by bree.app, Bree must not touch this\n"


def run(cli: str, home: Path, *args: str) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "CODEX_HOME": str(home), "BREE_SOCKET_PATH": "/nonexistent/none.sock"}
    return subprocess.run([cli, "hooks", *args], env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)


def main() -> int:
    cli = resolve_bree_cli()
    failures: list[str] = []
    for agent, (folder, old_names, new_names) in CASES.items():
        with tempfile.TemporaryDirectory(prefix="bree-plugin-names-") as tmp:
            home = Path(tmp)
            directory = home / folder
            directory.mkdir(parents=True)
            old = {n: OLD_CONTENT.encode() for n in old_names}
            for n, data in old.items():
                (directory / n).write_bytes(data)
            r = run(cli, home, agent, "install", "--yes")
            if r.returncode != 0:
                failures.append(f"{agent} install exit {r.returncode}: {(r.stdout + r.stderr)[-200:]}")
            for n in new_names:
                if not (directory / n).exists():
                    failures.append(f"{agent}: {n} was not written (found {sorted(p.name for p in directory.iterdir())})")
            for n, data in old.items():
                if (directory / n).read_bytes() != data:
                    failures.append(f"{agent}: pre-existing {n} changed by install")
            r = run(cli, home, agent, "uninstall", "--yes")
            for n in new_names:
                if (directory / n).exists():
                    failures.append(f"{agent}: {n} survived uninstall")
            for n, data in old.items():
                if not (directory / n).exists() or (directory / n).read_bytes() != data:
                    failures.append(f"{agent}: pre-existing {n} changed or removed by uninstall")
            leftovers = [p.name for p in directory.iterdir() if p.name.startswith(("bree", ".bree")) and p.name not in old]
            if leftovers:
                failures.append(f"{agent}: stray bree-named files {leftovers}")
    for f in failures:
        print("FAIL:", f)
    print("PASS" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
