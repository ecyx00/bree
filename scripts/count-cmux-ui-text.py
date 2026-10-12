#!/usr/bin/env python3
"""Count UI text that still says "cmux" (xcstrings en/tr values and Swift defaultValue literals).

Allowed leftovers are real paths/identifiers (cmux.json, ~/.config/cmux, .cmux/, .cmuxterm,
CMUX_* env vars, cmux_port, cmux-tui, cmux.com URLs, camel-case setting keys). Everything
else counts as "app name" text. cli.* keys belong to the CLI coder and are counted separately.
Usage: scripts/count-cmux-ui-text.py [--list]
"""
import json, os, re, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ALLOWED = re.compile(
    r'https?://[A-Za-z0-9._~:/?&=%#@+-]*cmux[A-Za-z0-9._~:/?&=%#@+-]*|~?/?\.config/cmux/dock\.json'
    r'|~?/?\.cmux/dock\.json|cmux\.sock|CMUX_\w+|\$CMUX\w*'
    r'|cmux_port\w*|cmux-tui|cmuxd-remote|\w*Cmux\w*|\.cmux\b|cmux\.com|co\.manaflow\.[\w.]+')
# Swift files owned by the CLI/binary coder; not counted here.
OTHER_CODER = {'CmuxCLIPathInstaller.swift', 'cmuxApp.swift', 'SocketCleanup.swift', 'CLIForwardingLaunchRouter.swift',
               'RemoteInteractiveShellBootstrapBuilder.swift', 'CmuxRemoteSession', 'AutomationSection.swift', 'CMUXAgentLaunch'}
SKIP_DIRS = {'node_modules', '.build', 'build', 'ghostty', 'web', '.git', 'Tests'}

def leftover(s):
    return bool(re.search('cmux', ALLOWED.sub('', s), re.I))

def unit_values(x):
    if isinstance(x, dict):
        if 'value' in x and isinstance(x['value'], str):
            yield x['value']
        for v in x.values():
            yield from unit_values(v)

def walk(*roots):
    for r in roots:
        for dp, dn, fn in os.walk(os.path.join(ROOT, r)):
            dn[:] = [d for d in dn if d not in SKIP_DIRS and not d.endswith('Tests')]
            for f in fn:
                yield os.path.join(dp, f)

def main():
    show = '--list' in sys.argv
    cat = {'en': 0, 'tr': 0}; cli = 0; allowed = 0; rows = []
    for p in walk('Resources', 'Packages', 'Examples', 'TunnelExtension'):
        if not p.endswith('.xcstrings'): continue
        d = json.load(open(p))
        for k, v in d['strings'].items():
            for loc, x in v.get('localizations', {}).items():
                if loc not in cat: continue
                for s in unit_values(x):
                    if not re.search('cmux', s, re.I): continue
                    if k.startswith('cli.'): cli += loc == 'en'; continue
                    if leftover(s): cat[loc] += 1; rows.append((os.path.relpath(p, ROOT), loc, k, s[:100]))
                    else: allowed += loc == 'en'
    lit = []; lit_allowed = 0
    rx = re.compile(r'defaultValue:\s*"((?:[^"\\]|\\.)*)"')
    for p in walk('Sources', 'Packages'):
        if not p.endswith('.swift') or any(o in p.split(os.sep) or os.path.basename(p) == o for o in OTHER_CODER): continue
        for i, line in enumerate(open(p, errors='ignore'), 1):
            for m in rx.finditer(line):
                if re.search('cmux', m.group(1), re.I):
                    if leftover(m.group(1)): lit.append((os.path.relpath(p, ROOT), i, m.group(1)[:100]))
                    else: lit_allowed += 1
    print(f"catalogs: en={cat['en']} tr={cat['tr']} leftover (non-cli); allowed path/identifier strings (en)={allowed}; cli.* en containing cmux (other coder)={cli}")
    print(f"defaultValue literals leftover={len(lit)} (allowed path/identifier literals={lit_allowed})")
    if show:
        for r in rows: print('CAT', *r)
        for r in lit: print('SWIFT', *r)

main()
