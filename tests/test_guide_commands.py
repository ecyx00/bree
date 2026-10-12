#!/usr/bin/env python3
"""Every `bree ...` command and shortcut named by the agent guides must exist in the CLI/app source.

Reads Swift source only (no built binary). Override the guides dir with BREE_GUIDES_DIR or
`--guides DIR` (used by the negative control).

Scope: top-level command + first subcommand for commands whose subcommands are declared in a
checkable place (wiki, architecture, guide, docs). Other commands (browser, ...) are checked at the
top level only.
"""
import os
import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "CLI"
SHORTCUTS = ROOT / "Sources" / "KeyboardShortcutSettings.swift"


def guides_dir():
    return Path(os.environ.get("BREE_GUIDES_DIR") or ROOT / "Resources" / "guides")


def read(p):
    return Path(p).read_text(encoding="utf-8")


# bree <word> [<word>]; lowercase only, not part of a path/identifier (".bree/", ".bree-wiki.json").
INVOCATION = re.compile(r"(?<![\w./-])bree[ \t]+([a-z][\w-]*)(?:[ \t]+([a-z][\w-]*))?")
SWIFT_INTERPOLATION_TAIL = re.compile(r"\\\($")


def extract(text, source):
    found = []
    for lineno, line in enumerate(text.splitlines(), 1):
        for m in INVOCATION.finditer(line):
            found.append((source, lineno, m.group(1), m.group(2)))
    return found


def known_top_level():
    src = read(CLI / "cmux.swift")
    names = set()
    for m in re.finditer(r'^ {8}case ((?:"[^"]+"\s*,?\s*)+):', src, re.M):
        names.update(re.findall(r'"([^"]+)"', m.group(1)))
    # commands intercepted before the main switch: `command == "x"`
    for f in CLI.glob("*.swift"):
        names.update(re.findall(r'command == "([a-z][\w-]*)"', read(f)))
    return names


def known_subcommands():
    subs = {}
    wiki = read(CLI / "CMUXCLI+WikiCheck.swift")
    subs["wiki"] = set(re.findall(r'args\.first == "([\w-]+)"', wiki)) | {"help"}
    arch = read(CLI / "CMUXCLI+Architecture.swift")
    m = re.search(r'\[((?:"[\w-]+",?\s*)+)\]\.contains\(action\)', arch)
    subs["architecture"] = set(re.findall(r'"([\w-]+)"', m.group(1))) if m else set()
    guide = read(CLI / "CMUXCLI+Guide.swift")
    subs["guide"] = set(re.findall(r'^\s*\("([a-z]+)", CMUXDiffViewerLocalization', guide, re.M))
    docs = read(CLI / "CMUXCLI+DocsSettings.swift")
    topics = set(re.findall(r'topic: "([\w-]+)"', docs))
    for m in re.finditer(r'aliases: \[([^\]]*)\]', docs):
        topics.update(re.findall(r'"([\w-]+)"', m.group(1)))
    subs["docs"] = topics
    return subs


def collect_invocations(gdir):
    inv = []
    for md in sorted(gdir.glob("*.md")):
        inv += extract(read(md), md.name)
    inv += extract(read(CLI / "CMUXCLI+Guide.swift"), "CLI/CMUXCLI+Guide.swift")
    return inv


def command_errors(gdir):
    top, subs = known_top_level(), known_subcommands()
    errs = []
    for src, line, cmd, sub in collect_invocations(gdir):
        if cmd not in top:
            errs.append(f"{src}:{line}: `bree {cmd}` is not a CLI command")
        elif cmd in subs and sub and sub not in subs[cmd]:
            errs.append(f"{src}:{line}: `bree {cmd} {sub}` is not a {cmd} subcommand (known: {sorted(subs[cmd])})")
    return errs


GLYPHS = {"⌘": "command", "⌥": "option", "⌃": "control", "⇧": "shift"}
SHORTCUT = re.compile(r"([⌘⌥⌃⇧]+)([A-Za-z0-9])")


def default_shortcut(action):
    src = read(SHORTCUTS)
    m = re.search(r"case \.%s:\s*(?://[^\n]*\n\s*)?return StoredShortcut\(key: \"(.)\", command: (\w+), shift: (\w+), option: (\w+), control: (\w+)" % action, src)
    if not m:
        return None
    key, c, s, o, ctl = m.groups()
    return key, {"command": c == "true", "shift": s == "true", "option": o == "true", "control": ctl == "true"}


def shortcut_errors(gdir):
    errs = []
    for md in sorted(gdir.glob("*.md")):
        action = "toggle" + md.stem.capitalize()
        default = default_shortcut(action)
        for lineno, line in enumerate(read(md).splitlines(), 1):
            for mods, key in SHORTCUT.findall(line):
                want = {GLYPHS[g] for g in mods}
                if default is None:
                    errs.append(f"{md.name}:{lineno}: cites {mods}{key} but no default for {action}")
                    continue
                have = {k for k, v in default[1].items() if v}
                if (default[0].lower(), have) != (key.lower(), want):
                    errs.append(f"{md.name}:{lineno}: cites {mods}{key}, {action} default is {sorted(have)}+{default[0]}")
    return errs


class GuideCommands(unittest.TestCase):
    def test_guides_exist(self):
        self.assertTrue(list(guides_dir().glob("*.md")), f"no guides in {guides_dir()}")

    def test_commands_exist_in_cli(self):
        errs = command_errors(guides_dir())
        self.assertFalse(errs, "guide names commands the CLI does not have:\n" + "\n".join(errs))

    def test_extractor_sees_known_commands(self):
        # guards against the regexes silently matching nothing
        self.assertGreater(len(collect_invocations(guides_dir())), 5)
        self.assertIn("wiki", known_top_level())
        self.assertEqual(known_subcommands()["architecture"], {"check", "render"})

    def test_shortcuts_match_defaults(self):
        errs = shortcut_errors(guides_dir())
        self.assertFalse(errs, "guide cites shortcuts that differ from app defaults:\n" + "\n".join(errs))


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "--guides":
        os.environ["BREE_GUIDES_DIR"] = sys.argv[2]
        del sys.argv[1:3]
    unittest.main()
