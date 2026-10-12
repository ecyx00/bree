#!/usr/bin/env python3
"""Run every gate over the rendered page and every board in it.   gates.py <repo root> [--dir DIR]   (DIR default ROOT/.architecture)

A board added to views/__init__.py REGISTRY is picked up with no edit here: check_svg and zoom_check read the boards from the page itself.
Gates: check_svg at 560 and 1400 px, stable_check (26-char names), zoom_check (open view, nav, card, zoom, network), and the byte-identical
re-render (current.html re-rendered under three PYTHONHASHSEED values must equal the file and each other). Exit 1 on any FAIL.
"""
import hashlib, os, re, shutil, subprocess, sys, tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = "/opt/anaconda3/bin/python"  # has playwright
fails = []


def run(cmd, env=None):
    r = subprocess.run(cmd, capture_output=True, text=True, env=env, timeout=600)
    return r.returncode, r.stdout + r.stderr


def gate(name, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + name + (f"  [{detail}]" if detail else ""))
    if not ok:
        fails.append(name)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    root = os.path.abspath(args[0])
    d = os.path.abspath(sys.argv[sys.argv.index("--dir") + 1]) if "--dir" in sys.argv else os.path.join(root, ".architecture")
    html = os.path.join(d, "current.html")
    # 1. byte-identical re-render
    sums = {}
    for seed in ("0", "1", "777"):
        with tempfile.TemporaryDirectory() as td:
            for f in ("current.architecture.json", "current.architecture.prev.json", "names.json"):
                if os.path.exists(os.path.join(d, f)):
                    shutil.copy(os.path.join(d, f), td)
            rc, out = run([sys.executable, os.path.join(HERE, "gen.py"), root, "--render-only", "--out", td], {**os.environ, "PYTHONHASHSEED": seed})
            sums[seed] = hashlib.md5(open(os.path.join(td, "current.html"), "rb").read()).hexdigest() if rc == 0 else out[-200:]
    disk = hashlib.md5(open(html, "rb").read()).hexdigest()
    gate("byte-identical re-render (hash seeds 0/1/777 and the file on disk)", len(set(sums.values())) == 1 and set(sums.values()) == {disk}, f"disk {disk}, " + ", ".join(sums.values()))
    # 2. check_svg per board, two widths
    rows = {}
    for w in (560, 1400):
        rc, out = run([sys.executable, os.path.join(HERE, "check_svg.py"), html, str(w)])
        for m in re.finditer(r"^(\S+)\s+scale=.*?issues=(\d+)$", out, re.M):
            rows.setdefault(m.group(1), {})[w] = int(m.group(2))
        gate(f"check_svg {w}px: 0 issues on every board ({len(rows)} boards)", rc == 0 and all(v.get(w) == 0 for v in rows.values()), "" if rc == 0 else " | ".join(l.strip() for l in out.splitlines() if l.startswith("    "))[:300] or out[-300:])
    for b, v in rows.items():
        print(f"     {b:24} issues 560px={v.get(560)} 1400px={v.get(1400)}")
    # 3. stable positions
    rc, out = run([sys.executable, os.path.join(HERE, "stable_check.py"), d, root])
    gate("stable_check", rc == 0, out.strip()[-160:])
    # 4. zoom_check: open view and card on every board, nav, zoom, contrast, 0 network
    rc, out = run([PY, "-I", os.path.join(HERE, "zoom_check.py"), html])
    bad = [l for l in out.splitlines() if l.startswith("FAIL")]
    gate("zoom_check (open view + card on every board)", rc == 0 and not bad, "; ".join(bad)[:400] or out.strip().splitlines()[-1])
    print("ALL GATES PASSED" if not fails else "GATES FAILED: " + ", ".join(fails))
    sys.exit(1 if fails else 0)


main()
