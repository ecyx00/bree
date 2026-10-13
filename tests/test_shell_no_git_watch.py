#!/usr/bin/env python3
"""Executable contract for the supported zsh/bash BREE_NO_GIT_WATCH opt-out.

Uses the shipped integrations with an isolated HOME and socket. Only message
delivery and watcher parent-identity capture are replaced: no app, or long-lived watcher is needed to check the public shell behavior.
"""

from __future__ import annotations

import os
from pathlib import Path
import socket
import subprocess
import tempfile
import unittest
import uuid


INTEGRATION_DIR = Path(__file__).resolve().parents[1] / "Resources/shell-integration"
SHELLS = ("zsh", "bash")


class NoGitWatchContract(unittest.TestCase):
    def run_shell(self, shell: str, body: str, value: str | None = "1") -> str:
        with tempfile.TemporaryDirectory(prefix="bree-no-git-", dir="/tmp") as tmp:
            directory = Path(tmp)
            repo = directory / "repo"
            (repo / ".git").mkdir(parents=True)
            (repo / ".git/HEAD").write_text("ref: refs/heads/contract-before\n")
            panel = str(uuid.uuid4())
            env = {
                "HOME": tmp,
                "TMPDIR": tmp,
                "PATH": "/usr/bin:/bin",
                "TERM": "xterm-256color",
                "BREE_SOCKET_PATH": str(directory / "socket"),
                "BREE_TAB_ID": str(uuid.uuid4()),
                "BREE_PANEL_ID": panel,
                "BREE_TEST_SCRIPT": str(INTEGRATION_DIR / f"bree-{shell}-integration.{shell if shell == 'zsh' else 'bash'}"),
                "BREE_TEST_LOG": str(directory / "messages"),
                "BREE_TEST_FORCE_KEYBOARD_RESET": "1",
            }
            if value is not None:
                env["BREE_NO_GIT_WATCH"] = value
            prompt = "_bree_precmd" if shell == "zsh" else "_bree_prompt_command"
            preexec = "_bree_preexec" if shell == "zsh" else "_bree_preexec_command"
            script = r'''
source "$BREE_TEST_SCRIPT"
_bree_send() { printf '%s\n' "$@" >> "$BREE_TEST_LOG"; }
_bree_send_bg() { _bree_send "$@"; }
# Stop at the process-creation boundary even if a startup guard regresses.
_bree_capture_shell_start_time() { _bree_send WATCHER_START; return 1; }
_BREE_TTY_NAME=ttys-contract
_BREE_PORTS_LAST_RUN=-100
'''
            script += f'_test_prompt() {{ {prompt}; }}\n'
            script += f'_test_preexec() {{ {preexec} "$1"; }}\n'
            script += body
            # The marker is emitted before shell-exit cleanup, so an exit hook
            # cannot make a broken prompt-time cleanup assertion pass.
            script += '\nprintf "CONTRACT_FINISHED\\n"\n'
            args = ["-f", "-c"] if shell == "zsh" else ["--noprofile", "--norc", "-c"]
            try:
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                    listener.bind(env["BREE_SOCKET_PATH"])
                    result = subprocess.run(
                        [f"/bin/{shell}", *args, script], cwd=repo, env=env,
                        capture_output=True, text=True, timeout=15,
                    )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("CONTRACT_FINISHED", result.stdout)
                messages = Path(env["BREE_TEST_LOG"])
                return result.stdout + (messages.read_text() if messages.exists() else "")
            finally:
                pass

    def test_disabled_prompt_command_and_head_change(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
_test_prompt
_test_preexec 'sleep 1'
printf 'ref: refs/heads/contract-after\n' > .git/HEAD
_test_prompt
_bree_report_git_branch_for_path "$PWD"
cd "$HOME"
_test_prompt
_bree_report_git_branch_for_path "$PWD"
[[ -n "$_BREE_GIT_ACTIVE_PWD_FILE" ]] && _bree_send ACTIVE_PWD_CREATED
[[ -n "$_BREE_GIT_JOB_PID" ]] && _bree_send GIT_JOB_STARTED
[[ -n "$_BREE_GIT_HEAD_PATH$_BREE_GIT_HEAD_SIGNATURE" ]] && _bree_send HEAD_TRACKED
''')
                for forbidden in (
                    "report_git_branch", "clear_git_branch", "WATCHER_START",
                    "ACTIVE_PWD_CREATED", "GIT_JOB_STARTED", "HEAD_TRACKED",
                ):
                    self.assertNotIn(forbidden, output)
                for preserved in (
                    "report_tty ttys-contract", "report_shell_state prompt",
                    "report_shell_state running", "report_pwd ",
                    "--reason=command", "--reason=refresh", "\x1b[>m\x1b[<8u",
                ):
                    self.assertIn(preserved, output)
                self.assertGreaterEqual(output.count("report_pwd "), 2)

    def test_watcher_startup_is_blocked(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
# Retained legacy helpers may be removed by #2924. When present, they must
# honor the opt-out even if a future caller reintroduces them.
if typeset -f _bree_start_git_head_watch >/dev/null; then
    _bree_start_git_head_watch
fi
''')
                self.assertNotIn("WATCHER_START", output)

    def test_only_literal_one_disables_branch_reports(self):
        for shell in SHELLS:
            for value in (None, "", "0", "true"):
                with self.subTest(shell=shell, value=value):
                    output = self.run_shell(shell, r'''
_bree_report_git_branch_for_path "$PWD"
cd "$HOME"
_bree_report_git_branch_for_path "$PWD"
''', value=value)
                    self.assertIn("report_git_branch contract-before --status=unknown", output)
                    self.assertIn("clear_git_branch ", output)

    def test_unsetting_restores_reports(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                output = self.run_shell(shell, r'''
_test_prompt
unset BREE_NO_GIT_WATCH
_test_prompt
_bree_report_git_branch_for_path "$PWD"
''')
                self.assertIn("report_git_branch contract-before", output)

    def test_next_prompt_stops_tracked_jobs(self):
        for shell in SHELLS:
            with self.subTest(shell=shell):
                # These are only our own disposable processes, each in a new
                # group so a group kill cannot touch the test runner.
                jobs = {}
                try:
                    names = ["_BREE_GIT_JOB_PID"]
                    if shell == "zsh":
                        # Bash has no HEAD watcher.
                        names += ["_BREE_GIT_HEAD_WATCH_PID"]
                    for name in names:
                        jobs[name] = subprocess.Popen(["/bin/sleep", "60"], start_new_session=True)
                    # Observe only prompt-time shutdown. zsh's normal exit hook
                    # could otherwise stop these jobs after a broken prompt.
                    body = "add-zsh-hook -d zshexit _bree_zshexit\n" if shell == "zsh" else ""
                    body += "\n".join(f"{name}={job.pid}" for name, job in jobs.items())
                    body += "\nexport BREE_NO_GIT_WATCH=1\n_test_prompt\n"
                    self.run_shell(shell, body, value=None)
                    for name, job in jobs.items():
                        self.assertLess(job.wait(timeout=3), 0, f"{shell}: {name} was not stopped")
                finally:
                    for job in jobs.values():
                        if job.poll() is None:
                            job.kill()
                        job.wait()


if __name__ == "__main__":
    unittest.main()
