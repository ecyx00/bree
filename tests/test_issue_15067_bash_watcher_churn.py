#!/usr/bin/env python3
"""Measure bash watcher launches separately from the normal prompt lifecycle.

The normal prompt lifecycle must not launch recurring external sleeps.
All shells, sockets, and logs belong to this test, not to a running bree app.
"""

from __future__ import annotations

from contextlib import ExitStack
import os
from pathlib import Path
import select
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
INTEGRATION = ROOT / "Resources/shell-integration/bree-bash-integration.bash"


def stop_shell(shell: subprocess.Popen) -> str:
    if shell.poll() is None:
        try:
            _, error = shell.communicate("stop\n", timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(shell.pid, signal.SIGKILL)
            _, error = shell.communicate(timeout=5)
        return error
    return ""


class BashWatcherChurnTests(unittest.TestCase):
    def measure(self, *, panes: int) -> tuple[list[int], list[str]]:
        with tempfile.TemporaryDirectory(prefix="bree15067-", dir="/tmp") as directory, ExitStack() as stack:
            root = Path(directory)
            bindir = root / "bin"
            bindir.mkdir()
            # Count each actual external sleep invocation; retain its real delay.
            (bindir / "sleep").write_text(
                '#!/bin/bash\nprintf "%s\\n" "$*" >> "$BREE_TEST_SLEEP_LOG"\nexec /bin/sleep "$@"\n'
            )
            (bindir / "sleep").chmod(0o755)
            server = stack.enter_context(socket.socket(socket.AF_UNIX, socket.SOCK_STREAM))
            server.bind(str(root / "socket"))
            shells = []
            for pane in range(panes):
                home = root / str(pane)
                home.mkdir()
                (home / ".git").mkdir()
                (home / ".git/HEAD").write_text("ref: refs/heads/feature/old\n")
                env = {
                    "PATH": f"{bindir}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME": str(home), "TMPDIR": str(home), "TERM": "dumb", "LC_ALL": "C",
                    "BREE_SOCKET_PATH": str(root / "socket"),
                    "BREE_TAB_ID": f"tab-15067-{os.getpid()}",
                    "BREE_PANEL_ID": f"panel-15067-{os.getpid()}-{pane}",
                    "BREE_TEST_INTEGRATION": str(INTEGRATION),
                    "BREE_TEST_SLEEP_LOG": str(home / "sleeps"),
                    "BREE_TEST_SEND_LOG": str(home / "send"),
                }
                script = (
                    'set -m\ncd "$HOME"\nsource "$BREE_TEST_INTEGRATION"\n'
                    '_bree_send() { printf "%s\\n" "$1" >> "$BREE_TEST_SEND_LOG"; }\n'
                    '_BREE_TTY_NAME=test; _BREE_TTY_REPORTED=1\n'
                    '_bree_prompt_command\n'
                )
                script += (
                    'printf "ref: refs/heads/feature/new\\n" > .git/HEAD\n'
                    '_bree_prompt_command\n'
                    ':; _bree_prompt_command\n'
                )
                script += 'printf "READY\\n"\nIFS= read -r stop\n'
                shell = subprocess.Popen(
                    ["/bin/bash", "--noprofile", "--norc", "-c", script], env=env,
                    stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                    text=True, start_new_session=True,
                )
                stack.callback(stop_shell, shell)
                shells.append((shell, home))
                ready, _, _ = select.select([shell.stdout], [], [], 15)
                self.assertTrue(ready, "bash did not finish the prompt lifecycle")
                # Prompt hooks may write terminal protocol escapes before READY.
                self.assertIn("READY", shell.stdout.readline())

            # Observation window, not synchronization: measure recurring work
            # while Python waits, so the driver adds no shell sleep launches.
            time.sleep(2.2)
            for shell, _ in shells:
                error = stop_shell(shell)
                self.assertEqual(shell.returncode, 0)
                self.assertNotIn("command not found", error)
            counts = []
            sends = []
            for _, home in shells:
                path = home / "sleeps"
                counts.append(len(path.read_text().splitlines()) if path.exists() else 0)
                sends.append((home / "send").read_text())
            print(f"prompt: panes={panes}, sleeps={counts}", flush=True)
            return counts, sends

    def test_prompt_branch_reports_without_watcher_launches(self) -> None:
        counts, sends = self.measure(panes=2)
        self.assertEqual(counts, [0, 0])
        for send in sends:
            self.assertIn("report_git_branch feature/new ", send)


if __name__ == "__main__":
    unittest.main()
