#!/usr/bin/env python3
"""Delete catalog keys listed in a file from Localizable.xcstrings as pure text hunks.

The file is never re-dumped: each top-level entry (`    "key": {` .. `    },`) is dropped
as whole lines. If the final entry would be deleted the new last entry would lose its
comma, so the script refuses (exit 1) to keep the diff deletion-only.
Usage: remove_unused.py UNUSED.txt [catalog]
"""
import json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
keys = {l.strip() for l in open(sys.argv[1], encoding="utf-8") if l.strip()}
path = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "Resources/Localizable.xcstrings"
lines = path.read_text(encoding="utf-8").split("\n")

start = lines.index('  "strings": {') + 1
end = lines.index("  },", start)  # closing brace of "strings" ("version" follows)
starts = [i for i in range(start, end) if lines[i].startswith('    "') and lines[i].endswith(": {")]
bounds = list(zip(starts, starts[1:] + [end]))
drop, found = [], set()
for s, e in bounds:
    key = json.loads(lines[s][4:-3])
    if key in keys:
        found.add(key)
        drop.append((s, e))
missing = keys - found
if missing:
    sys.exit(f"keys not in catalog: {sorted(missing)[:5]} ({len(missing)})")
if drop and drop[-1][1] == end:
    sys.exit("refusing: last entry would be deleted (comma fix needed)")
dead = set()
for s, e in drop:
    dead.update(range(s, e))
path.write_text("\n".join(l for i, l in enumerate(lines) if i not in dead), encoding="utf-8")
print(f"deleted {len(drop)} keys, {len(dead)} lines")
