"""Isolated HOME for tests that run the CLI (or anything that writes dot files).

Why: Bree must never write into cmux's or the user's real local state. Twice,
tests ran the CLI with the real HOME and leaked files into ~/.cmux/hooks.

    with isolated_home("cmux-foo-", subdir="home") as iso:
        subprocess.run([cli, ...], env=iso.env(CMUX_SOCKET_PATH="..."))
        iso.root / "scratch"        # temp dir for fixtures
        iso.home / ".bree-dev"      # HOME seen by the child

`isolated_home` creates a temp root with HOME, XDG_CONFIG_HOME, XDG_STATE_HOME,
XDG_DATA_HOME, XDG_CACHE_HOME, CODEX_HOME and CLAUDE_CONFIG_DIR inside it, and
by default wraps the block in `leak_guard()`: it records stat-only facts of the
real ~/.cmux, ~/.bree, ~/.codex/hooks.json and ~/.claude/settings.json before
and after, and raises AssertionError if they changed.

The guard never opens a file: only existence, size, mtime and directory
listings. It must not be pointed at ~/.codex/auth.json or ~/.secrets, and
nothing here reads them. If cmux.app or Bree is running it may legitimately
touch ~/.cmux or ~/.bree during the block; rerun with the apps idle to tell a
leak from background activity.
"""
from __future__ import annotations

import contextlib
import os
import pwd
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

# Real-home targets watched by the leak guard (relative to the real home).
GUARDED_PATHS = (".cmux", ".bree", ".codex/hooks.json", ".claude/settings.json")


HOME_VARS = ("HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "CFFIXED_USER_HOME")


def real_home() -> Path:
    """The login user's home, ignoring any HOME override in this process."""
    return Path(pwd.getpwuid(os.getuid()).pw_dir)


def _stat_facts(path: Path) -> tuple:
    try:
        st = path.lstat()
    except FileNotFoundError:
        return ("missing",)
    return ("present", st.st_mode, st.st_size, st.st_mtime_ns)


def snapshot(paths: tuple[str, ...] = GUARDED_PATHS, home: Path | None = None) -> dict[str, tuple]:
    """Stat-only facts for each guarded path; directories are walked without following symlinks."""
    base = home or real_home()
    facts: dict[str, tuple] = {}
    for rel in paths:
        root = base / rel
        facts[rel] = _stat_facts(root)
        if root.is_dir() and not root.is_symlink():
            for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
                for name in sorted(dirnames + filenames):
                    child = Path(dirpath) / name
                    facts[str(child.relative_to(base))] = _stat_facts(child)
    return facts


def diff_snapshots(before: dict[str, tuple], after: dict[str, tuple]) -> list[str]:
    lines = []
    for key in sorted(before.keys() | after.keys()):
        if key not in before:
            lines.append(f"  created  {key}")
        elif key not in after:
            lines.append(f"  removed  {key}")
        elif before[key] != after[key]:
            lines.append(f"  changed  {key}")
    return lines


@contextlib.contextmanager
def leak_guard(paths: tuple[str, ...] = GUARDED_PATHS, home: Path | None = None) -> Iterator[None]:
    """Fail if the real local state dirs/files changed inside the block (stat-only)."""
    before = snapshot(paths, home)
    yield
    changes = diff_snapshots(before, snapshot(paths, home))
    if changes:
        raise AssertionError(
            "test leaked into the real home (stat-only check):\n" + "\n".join(changes[:40])
        )


def home_env(home: Path, base: dict[str, str] | None = None, **overrides: str) -> dict[str, str]:
    """`base` (default: empty) plus every home-like variable pointing inside `home`.

    CFFIXED_USER_HOME matters: Foundation (the Swift CLI) resolves the home
    through getpwuid unless it is set, so HOME alone does not move the CLI.
    """
    env = {} if base is None else base
    env.update(
        HOME=str(home),
        CFFIXED_USER_HOME=str(home),
        XDG_CONFIG_HOME=str(home / ".config"),
        XDG_STATE_HOME=str(home / ".local" / "state"),
        XDG_DATA_HOME=str(home / ".local" / "share"),
        XDG_CACHE_HOME=str(home / ".cache"),
        CODEX_HOME=str(home / ".codex"),
        CLAUDE_CONFIG_DIR=str(home / ".claude"),
    )
    env.update(overrides)
    return env


@dataclass(frozen=True)
class IsolatedHome:
    root: Path
    home: Path

    @property
    def codex_home(self) -> Path:
        return self.home / ".codex"

    def env(self, **overrides: str) -> dict[str, str]:
        """os.environ copy with every home-like variable pointing inside the temp home."""
        return home_env(self.home, os.environ.copy(), **overrides)


@contextlib.contextmanager
def isolated_home(
    prefix: str = "isolated-home-",
    *,
    subdir: str | None = None,
    base_dir: str | None = None,
    set_process_env: bool = False,
    guard: bool = True,
) -> Iterator[IsolatedHome]:
    """Temp HOME (the temp root itself, or `root/subdir`) plus XDG/CODEX/CLAUDE dirs inside it.

    `set_process_env=True` also points this process's os.environ at it for the
    block (for tests that call the CLI via helpers that read os.environ), and
    restores the previous values after.
    """
    guard_cm = leak_guard() if guard else contextlib.nullcontext()
    with guard_cm, tempfile.TemporaryDirectory(prefix=prefix, dir=base_dir) as td:
        root = Path(td).resolve()
        home = root / subdir if subdir else root
        home.mkdir(parents=True, exist_ok=True)
        iso = IsolatedHome(root=root, home=home)
        for d in (".config", ".local/state", ".local/share", ".cache", ".codex", ".claude"):
            (home / d).mkdir(parents=True, exist_ok=True)
        saved = {k: os.environ.get(k) for k in HOME_VARS}
        if set_process_env:
            os.environ.update({k: v for k, v in iso.env().items() if k in HOME_VARS})
        try:
            yield iso
        finally:
            if set_process_env:
                for k, v in saved.items():
                    if v is None:
                        os.environ.pop(k, None)
                    else:
                        os.environ[k] = v
