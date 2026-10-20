#!/usr/bin/env python3
"""Walk every help/guide text of the bundled CLI and count the legacy name.

Usage: scripts/check-cli-help-names.py [path-to-cli-binary] [--show]

Runs the binary sandboxed (empty HOME, no BREE_* env, dead socket path, per-command timeout) so a
subcommand that does not intercept --help cannot touch real configs or a running app.
Exit 1 when any help text still prints the word "bree" outside the kept path categories
(bree.json, ~/.config/bree, /tmp/bree*, github.com/ecyx00/bree URLs, github.com/.../bree).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEGACY = re.compile(r"bree")
# Path names that stay on purpose (shared with the real bree.app config dir). Socket and agent plugin file names are NOT kept.
KEPT = re.compile(
    r"(~?/?\.config/bree\S*|bree\.json|/tmp/bree\S*|"
    r"https?://\S*bree\S*|\.bree/\S*|\.bree\S*|bree\.xcodeproj|"
    r"\.cache/bree\S*|breed-remote|bree-hq|bree-json)"
)


def default_binary() -> str:
    env = os.environ.get("BREE_CLI_BIN")
    if env:
        return env
    for base in sorted((Path.home() / "Library/Developer/Xcode/DerivedData").glob("bree-bree/Build/Products/Debug/*bree.app")):
        for name in ("bree", "bree"):
            p = base / "Contents/Resources/bin" / name
            if p.exists():
                return str(p)
    sys.exit("pass the CLI binary path or set BREE_CLI_BIN")


def run(binary: str, args: list[str], home: str, lang: str) -> str:
    env = {
        "PATH": "/usr/bin:/bin",
        "HOME": home,
        "CODEX_HOME": home,
        "BREE_SOCKET_PATH": "/nonexistent/none.sock",
        "LANG": lang,
        "AppleLanguages": f"({lang})",
        "TERM": "dumb",
    }
    try:
        p = subprocess.run([binary, *args], env=env, capture_output=True, text=True, timeout=10, stdin=subprocess.DEVNULL)
        return p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return ""


def subcommands(text: str, parent: list[str]) -> set[tuple[str, ...]]:
    found = set()
    for line in text.splitlines():
        m = re.match(r"^\s{2,6}(?:(?:bree|bree)\s+)?([a-z][a-z0-9-]+)(?:\s+([a-z][a-z0-9-]+))?(?=\s|$|\|)", line)
        if not m:
            continue
        first = tuple(parent + [m.group(1)])
        found.add(first)
        if m.group(2) and not m.group(2).startswith("-"):
            found.add(tuple(parent + [m.group(1), m.group(2)]))
    return found


def main() -> int:
    home = tempfile.mkdtemp(prefix="cli-help-home-")
    try:
        return _main(home)
    finally:
        shutil.rmtree(home, ignore_errors=True)


def _main(home: str) -> int:
    argv = [a for a in sys.argv[1:] if not a.startswith("--")]
    show = "--show" in sys.argv
    binary = argv[0] if argv else default_binary()
    langs = ["en", "tr"]
    texts: dict[str, str] = {}
    for lang in langs:
        queue = [[], ["--help"]]
        top = run(binary, ["--help"], home, lang)
        texts[f"[{lang}] --help"] = top
        todo = [(c,) for (c,) in {t for t in subcommands(top, []) if len(t) == 1}]
        seen = set()
        for topic in ("start", "agents", "navigate", "inspect", "customize", "automation", "browser", "remote", "diagnostics"):
            texts[f"[{lang}] help {topic}"] = run(binary, ["help", topic], home, lang)
        for args in (["guide"], ["--skill"], ["guide", "wiki"], ["guide", "architecture"], ["guide", "overview"]):
            texts[f"[{lang}] {' '.join(args)}"] = run(binary, args, home, lang)
        while todo:
            cmd = todo.pop()
            if cmd in seen or len(cmd) > 3 or cmd[0] in ("open", "quit"):
                continue
            seen.add(cmd)
            out = run(binary, [*cmd, "--help"], home, lang)
            texts[f"[{lang}] {' '.join(cmd)} --help"] = out
            if len(cmd) < 3:
                todo.extend(subcommands(out, list(cmd))) if len(cmd) == 1 else None
    raw = 0
    kept = 0
    bad: list[str] = []
    seen_lines: set[str] = set()
    for name, text in texts.items():
        for line in text.splitlines():
            n = len(LEGACY.findall(line))
            if not n:
                continue
            raw += n
            rest = len(LEGACY.findall(KEPT.sub("", line)))
            kept += n - rest
            if rest and line.strip() not in seen_lines:
                seen_lines.add(line.strip())
                bad.append(f"{name}: {line.strip()[:160]}")
    print(f"texts walked: {len(texts)}  raw bree: {raw}  kept path names: {kept}  distinct offending lines: {len(bad)}")
    if show or bad:
        for b in bad[:200]:
            print("  " + b)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
