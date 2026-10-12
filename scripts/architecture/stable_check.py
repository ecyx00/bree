#!/usr/bin/env python3
"""Stable-position check: renaming every step to a 26-char name must not move any node or change any viewBox.
  stable_check.py <dir with current.architecture.json> <repo root>
The repo root is passed to the render like gen.py does: a view that reads the repo (system, state, schema) would otherwise draw its empty state
here and the check would compare nothing. The token budget is 0, so a cold cache stops the check instead of spending tokens."""
import json, os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render, views


def geometry(html):
    return re.findall(r'viewBox="([^"]+)"', html) + re.findall(r'<g class="node" data-id="[^"]+".*?<(?:rect|polygon) class="(?:mask|hit)"[^>]*>', html)


def main():
    d, root = sys.argv[1], os.path.abspath(sys.argv[2])
    doc = json.load(open(os.path.join(d, "current.architecture.json")))
    npath = os.path.join(d, "names.json")
    names = json.load(open(npath))["names"] if os.path.exists(npath) else {}   # a repo whose naming pass has not run has no sidecar
    anchors = set(names) | {s["anchor"] for f in doc.get("flows", []) for s in f["steps"]}
    long = {a: "Alpha beta gamma delta eps" for a in anchors}
    page = lambda nm: render.render_page(doc, nm, root=root, budget=views.TokenBudget(cap=0), arch_dir=d)
    pa, pb = page(names), page(long)
    a, b = geometry(pa), geometry(pb)
    # node groups differ in aria-label only; compare the geometry attributes
    strip = lambda xs: [re.sub(r'aria-label="[^"]*"', "", x) for x in xs]
    # every board has a viewBox and every node group a geometry record; a smaller count means the regex found nothing (a vacuous pass).
    # This replaces the absolute floor of 20 records, which a small repo with few nodes cannot reach.
    expect = len(re.findall(r'<section class="b"', pa)) + len(re.findall(r'<g class="node" data-id=', pa))
    ok = strip(a) == strip(b) and len(a) == expect and expect > 0
    print(("PASS" if ok else "FAIL") + f" stable positions: {len(a)} geometry records (of {expect} expected) identical under 26-char names")
    sys.exit(0 if ok else 1)


main()
