#!/usr/bin/env python3
"""Zero-trace lint: no tracked path or file content may carry the upstream product name.

Bree is a hard fork that must not reference, read or write anything of the app it
forked from. This scans every `git ls-files` path and every file's bytes,
case-insensitively, and fails on any hit outside the allowlist below.

The needle is assembled from pieces so this file passes its own check.

Allowlist (every entry has a reason; add nothing without one):
  * ghostty/                      vendored third-party tree, not ours to edit
  * LICENSE, THIRD_PARTY_LICENSES.md   legal notices (GPL section 5a, Appropriate Legal Notices)
  * README.md                     only the attribution line and the two attribution sections
  * docs/releases/0.1.0.md, 0.1.1.md   published history
  * docs/state/                   internal task logs
  * the legacy-name migration file    must spell the old names to copy them

Run against another tree with
  IDENTITY_LINT_ROOT=/path/to/tree python3 tests/test_identity_paths_lint.py
Exit 0 and "0 hits" when clean.
"""
from __future__ import annotations

import os
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ.get("IDENTITY_LINT_ROOT", REPO))
NEEDLE = re.compile(("cm" + "ux").encode(), re.IGNORECASE)

ALLOW_PREFIXES = ("ghostty/", "docs/state/")
ALLOW_FILES = frozenset({
    "LICENSE",
    "THIRD_PARTY_LICENSES.md",
    "docs/releases/0.1.0.md",
    "docs/releases/0.1.1.md",
    "Packages/macOS/BreeFoundation/Sources/BreeFoundation/Identity/LegacyNameMigration.swift",
    "tests/test_identity_paths_lint.py",
})
README = "README.md"
README_KEEP_LINE = re.compile(rb"hard fork of")
README_KEEP_HEADINGS = (b"## How Bree differs from", b"## License and attribution")


def tracked(root: Path) -> list[str]:
    out = subprocess.check_output(["git", "-C", str(root), "ls-files", "-z"])
    return [p for p in out.decode("utf-8", "surrogateescape").split("\0") if p]


def allowed(path: str) -> bool:
    return path in ALLOW_FILES or path.startswith(ALLOW_PREFIXES)


def readme_hits(data: bytes) -> int:
    hits, keep = 0, False
    for line in data.splitlines():
        if line.startswith(b"## "):
            keep = line.startswith(README_KEEP_HEADINGS)
        if keep or README_KEEP_LINE.search(line):
            continue
        hits += len(NEEDLE.findall(line))
    return hits


def lint(root: Path) -> tuple[int, list[str]]:
    total, report = 0, []
    for path in tracked(root):
        if allowed(path):
            continue
        n = len(NEEDLE.findall(path.encode("utf-8", "surrogateescape")))
        full = root / path
        if full.is_file() and not full.is_symlink():
            data = full.read_bytes()
            n += readme_hits(data) if path == README else len(NEEDLE.findall(data))
        elif full.is_symlink():
            n += len(NEEDLE.findall(os.readlink(full).encode("utf-8", "surrogateescape")))
        if n:
            total += n
            report.append(f"{path}: {n}")
    return total, report


def main() -> int:
    total, report = lint(ROOT)
    for line in report[:200]:
        print(line)
    if len(report) > 200:
        print(f"... {len(report) - 200} more files")
    print(f"{total} hits in {len(report)} files")
    return 1 if total else 0


if __name__ == "__main__":
    sys.exit(main())
