#!/usr/bin/env python3
"""Agent plugin installers write bree-* files and never touch pre-existing cmux-* files.

Runs the bundled CLI (CMUX_CLI_BIN) with a temp HOME; the real agent folders are never read.
Usage: CMUX_CLI_BIN=<bin/bree> python3 tests/test_bree_plugin_names.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from claude_teams_test_utils import resolve_cmux_cli

# agent -> (folder under HOME, old cmux-owned names, expected bree names)
CASES = {
    "opencode": (".config/opencode/plugins", ["cmux-session.js", "cmux-feed.js"], ["bree-session.js", "bree-feed.js"]),
    "pi": (".pi/agent/extensions", ["cmux-session.ts"], ["bree-session.ts"]),
    "omp": (".omp/agent/extensions", ["cmux-omp-session.ts"], ["bree-omp-session.ts"]),
    "campfire": (".campfire/agent/extensions", ["cmux-campfire-session.ts"], ["bree-campfire-session.ts"]),
    "amp": (".config/amp/plugins", ["cmux-session.ts"], ["bree-session.ts"]),
}
# Looks like what the real cmux.app would have written, including its old marker.
OLD_CONTENT = "// cmux-session-extension-marker v1\n// owned by cmux.app, Bree must not touch this\n"


def run(cli: str, home: Path, *args: str) -> subprocess.CompletedProcess:
    env = {"PATH": "/usr/bin:/bin", "HOME": str(home), "CODEX_HOME": str(home), "CMUX_SOCKET_PATH": "/nonexistent/none.sock"}
    return subprocess.run([cli, "hooks", *args], env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)


def main() -> int:
    cli = resolve_cmux_cli()
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
            leftovers = [p.name for p in directory.iterdir() if p.name.startswith(("cmux", ".cmux")) and p.name not in old]
            if leftovers:
                failures.append(f"{agent}: stray cmux-named files {leftovers}")
    for f in failures:
        print("FAIL:", f)
    print("PASS" if not failures else f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
