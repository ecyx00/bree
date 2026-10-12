#!/usr/bin/env python3
"""Identity lint: app-linked Swift must not hard-code cmux's local state paths.

Bree is a hard fork that must never read or write cmux's local state. Every
path root comes from `CmuxIdentity` (CmuxFoundation): `dotDirectoryName`,
`dotDirectory(homeDirectory:)`, `dotDirectoryTildePath`, the socket name, and
the Application Support folder. A literal `~/.cmux`, `Application Support/cmux`,
`.cmuxterm` or `cmux.sock` makes Bree and cmux.app overwrite each other.

Exceptions
  * Comment-only lines are ignored.
  * Remote-host paths are no exception: they use `CmuxIdentity.remoteDotDirectoryName`
    (`.bree`), because two apps on one host would overwrite each other's files.
  * Test directories (any path component containing "Tests") are skipped, and
    so is the identity definition itself (CmuxFoundation/.../Identity/).
  * Anything else needs `// identity-lint: allow <reason>` on the same line or
    the line before. An allow with no reason is itself a failure.
  * Inside a multi-line string literal (triple quotes) the allow goes on the
    line of, or before, the opening triple quote.
  * `// identity-lint: allow-file <reason>` anywhere in a file exempts the whole
    file (for remote shell scripts embedded in multi-line string literals,
    where a per-line comment would become part of the string).

Run against another tree (negative control) with
  IDENTITY_LINT_ROOT=/path/to/tree python3 tests/test_identity_paths_lint.py
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("IDENTITY_LINT_ROOT", REPO))
SCAN_DIRS = ("Sources", "CLI", "Packages", "TunnelExtension")

# (name, regex). Keep these narrow: a hit must mean "a local cmux state path".
PATTERNS = [
    ("home .cmux dir", re.compile(r'(~|\$HOME|\$\{HOME\}|\\\(\w+\))/\.cmux(?![\w-])')),
    ("appendingPathComponent .cmux", re.compile(r'appendingPathComponent\("\.cmux"')),
    ("absolute /.cmux/ segment", re.compile(r'"[^"]*/\.cmux/')),
    ("Application Support/cmux", re.compile(r'Application Support/cmux')),
    ("cmux Application Support dir", re.compile(r'appendingPathComponent\("cmux"(, isDirectory: true)?\)')),
    (".cmuxterm path", re.compile(r'(?<![\w.])\.cmuxterm')),
    ("cmux.sock literal", re.compile(r'cmux\.sock"')),
    ("cmux last-socket marker", re.compile(r'cmux-last-socket')),
    ("config/cmux dir", re.compile(r'(\.config/cmux|appendingPathComponent\("\.config"[^)]*\)\s*\.appendingPathComponent\("cmux")')),
    ("cmux defaults suite", re.compile(r'suiteName:\s*"com\.cmuxterm')),
]
ALLOW = re.compile(r'//\s*identity-lint:\s*allow(-file)?\b(.*)$')
IDENTITY_DEFINITION = "CmuxFoundation/Identity/"


def swift_files(root: Path):
    for d in SCAN_DIRS:
        for p in sorted((root / d).rglob("*.swift")) if (root / d).is_dir() else []:
            rel = p.relative_to(root).parts
            if any("Tests" in part for part in rel) or IDENTITY_DEFINITION in p.as_posix():
                continue
            yield p


def lint(root: Path) -> list[str]:
    problems: list[str] = []
    for path in swift_files(root):
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
        rel = path.relative_to(root)
        file_allowed = False
        allows: dict[int, str] = {}
        for i, line in enumerate(lines):
            m = ALLOW.search(line)
            if not m:
                continue
            reason = m.group(2).strip()
            if len(reason) < 8:
                problems.append(f"{rel}:{i+1}: identity-lint allow without a reason")
                continue
            if m.group(1):
                file_allowed = True
            allows[i] = reason
        if file_allowed:
            continue
        anchor, in_block = 0, False
        for i, line in enumerate(lines):
            starts_block = line.count('"""') % 2 == 1
            if starts_block and not in_block:
                in_block, anchor = True, i
            elif starts_block:
                in_block = False
            at = anchor if in_block or (starts_block and not in_block and anchor == i) else i
            if line.lstrip().startswith("//"):
                continue
            code = ALLOW.sub("", line)
            for name, rx in PATTERNS:
                if rx.search(code):
                    if at in allows or (at - 1) in allows:
                        break
                    problems.append(f"{rel}:{i+1}: {name}: {line.strip()[:110]}")
                    break
    return problems


def test_no_hardcoded_cmux_state_paths() -> None:
    problems = lint(ROOT)
    assert not problems, (
        "Hard-coded cmux local state. Derive the root from CmuxIdentity, or add "
        "`// identity-lint: allow <reason>`:\n" + "\n".join(problems)
    )


def test_allow_comments_need_a_reason(tmp_path: Path) -> None:
    src = tmp_path / "Sources"
    src.mkdir()
    (src / "A.swift").write_text('let a = "~/.cmux/x" // identity-lint: allow\n')
    (src / "B.swift").write_text('// identity-lint: allow remote host path deployed by app\nlet b = "~/.cmux/x"\n')
    (src / "C.swift").write_text('let c = "~/.cmux/bin/cmux"\nlet d = "~/.cmux/hooks"\n')
    out = lint(tmp_path)
    assert any("A.swift:1: identity-lint allow without a reason" in p for p in out)
    assert any("A.swift:1: home .cmux dir" in p for p in out)
    assert not any("B.swift" in p for p in out)
    # Remote-host `.bree/bin` is flagged like any other cmux path.
    assert len([p for p in out if "C.swift" in p]) == 2


GO_PATTERN = re.compile(r'"\.cmux(term)?"')


def test_remote_daemon_uses_bree_root() -> None:
    """The Go daemon runs on the remote host and must use `$HOME/.bree`, never `.cmux`/`.cmuxterm`."""
    problems = []
    for path in sorted((ROOT / "daemon" / "remote").rglob("*.go")):
        if path.name.endswith("_test.go"):
            continue
        for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
            if GO_PATTERN.search(line) and not line.lstrip().startswith("//"):
                problems.append(f"{path.relative_to(ROOT)}:{i+1}: {line.strip()[:110]}")
    assert not problems, "\n".join(problems)


if __name__ == "__main__":
    found = lint(ROOT)
    for path in sorted((ROOT / "daemon" / "remote").rglob("*.go")):
        if path.name.endswith("_test.go"):
            continue
        for i, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines()):
            if GO_PATTERN.search(line) and not line.lstrip().startswith("//"):
                found.append(f"{path.relative_to(ROOT)}:{i+1}: remote daemon cmux root: {line.strip()[:90]}")
    print("\n".join(found) if found else "identity lint: clean")
    print(f"{len(found)} problem(s) in {ROOT}")
    sys.exit(1 if found else 0)
